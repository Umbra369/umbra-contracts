// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {UmbraRouterV6} from "../src/UmbraRouterV6.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Deterministic (no-fork) proofs of the v6 LAST_HOP_DIRECT single-tax delivery
// + the input-side fee that replaces output custody. Mocks mirror
// UmbraRouterV5Direct.t.sol (burn-tax FoT token, K-enforcing V2 pair).
// ─────────────────────────────────────────────────────────────────────────────

contract MockFoT {
    uint16 public immutable taxBps;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint16 _taxBps) {
        taxBps = _taxBps;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        return _xfer(msg.sender, to, amt);
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        return _xfer(from, to, amt);
    }

    function _xfer(address from, address to, uint256 amt) internal returns (bool) {
        require(balanceOf[from] >= amt, "balance");
        balanceOf[from] -= amt;
        uint256 recv = amt * (10_000 - taxBps) / 10_000;
        balanceOf[to] += recv;
        totalSupply -= (amt - recv); // burn the tax
        return true;
    }
}

interface IBal {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

contract MockV2Pair {
    address public immutable token0;
    address public immutable token1;
    uint112 private r0;
    uint112 private r1;
    uint256 private constant FEE_NUM = 997000;
    uint256 private constant FEE_DEN = 1_000_000;

    constructor(address _t0, address _t1) {
        token0 = _t0;
        token1 = _t1;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (r0, r1, 0);
    }

    function sync() public {
        r0 = uint112(IBal(token0).balanceOf(address(this)));
        r1 = uint112(IBal(token1).balanceOf(address(this)));
    }

    function _amountOut(uint256 inAmt, uint256 rIn, uint256 rOut) internal pure returns (uint256) {
        uint256 inWithFee = inAmt * FEE_NUM;
        return (inWithFee * rOut) / (rIn * FEE_DEN + inWithFee);
    }

    function swap(uint256 a0Out, uint256 a1Out, address to, bytes calldata) external {
        require(a0Out == 0 || a1Out == 0, "one side");
        uint256 b0 = IBal(token0).balanceOf(address(this));
        uint256 b1 = IBal(token1).balanceOf(address(this));
        uint256 in0 = b0 > r0 ? b0 - r0 : 0;
        uint256 in1 = b1 > r1 ? b1 - r1 : 0;
        if (a1Out > 0) {
            require(in0 > 0 && in1 == 0, "dir");
            require(a1Out <= _amountOut(in0, r0, r1), "K");
            IBal(token1).transfer(to, a1Out);
        } else {
            require(in1 > 0 && in0 == 0, "dir");
            require(a0Out <= _amountOut(in1, r1, r0), "K");
            IBal(token0).transfer(to, a0Out);
        }
        sync();
    }
}

contract UmbraRouterV6DirectTest is Test {
    UmbraRouterV6 internal router;

    address constant WPLS = 0xA1077a294dDE1B09bB078844df40758a5D0f9a27;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant USER = address(0xBEEF);
    address constant TREASURY = address(0xFEE5);

    uint8 constant FLAG_PERMIT2 = 1;
    uint8 constant FLAG_NATIVE_IN = 2;
    uint8 constant FLAG_NATIVE_OUT = 4;
    uint8 constant FLAG_FHD = 8;
    uint8 constant FLAG_LHD = 16;
    uint8 constant PT_V2 = 0;
    uint8 constant PT_V3 = 1;

    uint256 constant SIGNER_PK = 0xA11CE;
    address internal signerAddr;

    function setUp() public {
        address[] memory empty;
        router = new UmbraRouterV6(WPLS, PERMIT2, empty, empty, empty, empty);
        signerAddr = vm.addr(SIGNER_PK);
    }

    // ---- helpers ----
    function _v2Word(address pair) internal pure returns (uint256) {
        return uint256(uint160(pair)) | (uint256(997000) << 160);
    }

    function _amountOut(uint256 inAmt, uint256 rIn, uint256 rOut) internal pure returns (uint256) {
        uint256 inWithFee = inAmt * 997000;
        return (inWithFee * rOut) / (rIn * 1_000_000 + inWithFee);
    }

    function _taxed(uint256 amt, uint16 bps) internal pure returns (uint256) {
        return amt * (10_000 - bps) / 10_000;
    }

    /// Pool of (inTok, outTok) with the given reserves, synced.
    function _pool(MockFoT tin, MockFoT tout, uint256 rIn, uint256 rOut) internal returns (MockV2Pair pair) {
        pair = new MockV2Pair(address(tin), address(tout));
        tin.mint(address(pair), rIn);
        tout.mint(address(pair), rOut);
        pair.sync();
    }

    function _singleHop(address tin, address tout, address pair, uint8 poolType, uint256 amt, uint8 flags)
        internal
        view
        returns (UmbraRouterV6.ExecuteParams memory p)
    {
        UmbraRouterV6.Hop[] memory hops = new UmbraRouterV6.Hop[](1);
        hops[0] = UmbraRouterV6.Hop({
            poolType: poolType,
            tokenIn: tin,
            tokenOut: tout,
            pool: _v2Word(pair),
            poolData: bytes32(0)
        });
        UmbraRouterV6.Path[] memory paths = new UmbraRouterV6.Path[](1);
        paths[0] = UmbraRouterV6.Path({inputBps: 10_000, hops: hops});
        p = UmbraRouterV6.ExecuteParams({
            tokenIn: tin,
            tokenOut: tout,
            amountIn: amt,
            minAmountOut: 0,
            surplusFloor: 0,
            quoteNonce: 0,
            recipient: USER,
            deadline: block.timestamp + 600,
            flags: flags,
            paths: paths,
            permit2: "",
            umbraSig: "",
            plsRate: 0,
            routingAdvantage: 0
        });
    }

    function _sign(UmbraRouterV6.ExecuteParams memory p) internal view returns (bytes memory) {
        bytes32 typeHash = keccak256(
            "QuoteAttestation(address tokenIn,address tokenOut,uint256 amountIn,uint256 surplusFloor,uint256 nonce,uint256 deadline,address recipient,bytes32 routeHash,uint256 plsRate,uint256 routingAdvantage)"
        );
        bytes32 structHash = keccak256(
            abi.encode(
                typeHash,
                p.tokenIn,
                p.tokenOut,
                p.amountIn,
                p.surplusFloor,
                p.quoteNonce,
                p.deadline,
                p.recipient,
                keccak256(abi.encode(p.paths)),
                p.plsRate,
                p.routingAdvantage
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", router.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, digest);
        return abi.encodePacked(r, s, v);
    }

    function _enableFee() internal {
        router.proposeFeeRecipient(TREASURY);
        vm.prank(TREASURY);
        router.acceptFeeRecipient();
        router.setFeeConfig(5000, 25, signerAddr);
    }

    // ════════════════════════════════════════════════════════════════════════
    // Headline: buying a FoT token. Custody (flags=0) taxes the delivery TWICE
    // (pool→router, router→recipient); LAST_HOP_DIRECT taxes it ONCE.
    // ════════════════════════════════════════════════════════════════════════
    function test_lhd_taxed_output_single_tax() public {
        uint16 tax = 500; // 5% output token
        MockFoT clean = new MockFoT(0);
        MockFoT fot = new MockFoT(tax);
        uint256 amt = 10_000e18;

        // custody route (flags = 0): recipient receives amountOut * 0.95^2
        MockV2Pair pairA = _pool(clean, fot, 1_000_000e18, 2_000_000e18);
        clean.mint(address(this), amt);
        clean.approve(address(router), amt);
        uint256 expOutA = _amountOut(amt, 1_000_000e18, 2_000_000e18);
        router.execute(_singleHop(address(clean), address(fot), address(pairA), PT_V2, amt, 0));
        uint256 gotCustody = fot.balanceOf(USER);
        assertEq(gotCustody, _taxed(_taxed(expOutA, tax), tax), "custody = double-taxed");

        // LHD route (fresh identical pool + recipient): recipient receives amountOut * 0.95
        address user2 = address(0xCAFE);
        MockV2Pair pairB = _pool(clean, fot, 1_000_000e18, 2_000_000e18);
        clean.mint(address(this), amt);
        clean.approve(address(router), amt);
        UmbraRouterV6.ExecuteParams memory p =
            _singleHop(address(clean), address(fot), address(pairB), PT_V2, amt, FLAG_LHD);
        p.recipient = user2;
        uint256 expOutB = _amountOut(amt, 1_000_000e18, 2_000_000e18);
        uint256 delivered = router.execute(p);
        assertEq(fot.balanceOf(user2), _taxed(expOutB, tax), "LHD = single-taxed");
        assertEq(delivered, fot.balanceOf(user2), "return == measured delivery");
        assertGt(fot.balanceOf(user2), gotCustody, "LHD strictly beats custody");
        assertEq(fot.balanceOf(address(router)), 0, "no output custody residue");
    }

    /// Clean output token: LHD delivery equals custody delivery exactly (no tax to save).
    function test_lhd_clean_token_parity() public {
        MockFoT a = new MockFoT(0);
        MockFoT b = new MockFoT(0);
        uint256 amt = 5_000e18;

        MockV2Pair pairA = _pool(a, b, 1_000_000e18, 3_000_000e18);
        a.mint(address(this), amt);
        a.approve(address(router), amt);
        router.execute(_singleHop(address(a), address(b), address(pairA), PT_V2, amt, 0));
        uint256 custody = b.balanceOf(USER);

        address user2 = address(0xCAFE);
        MockV2Pair pairB = _pool(a, b, 1_000_000e18, 3_000_000e18);
        a.mint(address(this), amt);
        a.approve(address(router), amt);
        UmbraRouterV6.ExecuteParams memory p =
            _singleHop(address(a), address(b), address(pairB), PT_V2, amt, FLAG_LHD);
        p.recipient = user2;
        router.execute(p);
        assertEq(b.balanceOf(user2), custody, "clean-token LHD == custody output");
    }

    /// minAmountOut is enforced on the recipient's post-tax received delta.
    function test_lhd_minout_on_delivered() public {
        uint16 tax = 500;
        MockFoT clean = new MockFoT(0);
        MockFoT fot = new MockFoT(tax);
        uint256 amt = 10_000e18;
        MockV2Pair pair = _pool(clean, fot, 1_000_000e18, 2_000_000e18);
        clean.mint(address(this), amt);
        clean.approve(address(router), amt);
        uint256 delivered = _taxed(_amountOut(amt, 1_000_000e18, 2_000_000e18), tax);

        UmbraRouterV6.ExecuteParams memory p =
            _singleHop(address(clean), address(fot), address(pair), PT_V2, amt, FLAG_LHD);
        p.minAmountOut = delivered + 1; // one wei above what arrives
        vm.expectRevert(UmbraRouterV6.InsufficientOutput.selector);
        router.execute(p);
    }

    // ---- fail-closed validation ----
    function test_lhd_reverts_on_native_out() public {
        MockFoT a = new MockFoT(0);
        MockFoT b = new MockFoT(0);
        MockV2Pair pair = _pool(a, b, 1e24, 1e24);
        a.mint(address(this), 1e18);
        a.approve(address(router), 1e18);
        UmbraRouterV6.ExecuteParams memory p =
            _singleHop(address(a), address(b), address(pair), PT_V2, 1e18, FLAG_LHD | FLAG_NATIVE_OUT);
        vm.expectRevert(UmbraRouterV6.BadDirect.selector);
        router.execute(p);
    }

    function test_lhd_reverts_on_non_v2_final_hop() public {
        MockFoT a = new MockFoT(0);
        MockFoT b = new MockFoT(0);
        MockV2Pair pair = _pool(a, b, 1e24, 1e24);
        a.mint(address(this), 1e18);
        a.approve(address(router), 1e18);
        UmbraRouterV6.ExecuteParams memory p =
            _singleHop(address(a), address(b), address(pair), PT_V3, 1e18, FLAG_LHD);
        vm.expectRevert(UmbraRouterV6.BadDirect.selector);
        router.execute(p);
    }

    function test_lhd_reverts_on_router_recipient() public {
        MockFoT a = new MockFoT(0);
        MockFoT b = new MockFoT(0);
        MockV2Pair pair = _pool(a, b, 1e24, 1e24);
        a.mint(address(this), 1e18);
        a.approve(address(router), 1e18);
        UmbraRouterV6.ExecuteParams memory p =
            _singleHop(address(a), address(b), address(pair), PT_V2, 1e18, FLAG_LHD);
        p.recipient = address(router);
        vm.expectRevert(UmbraRouterV6.BadDirect.selector);
        router.execute(p);
    }

    function test_lhd_reverts_on_final_token_mismatch() public {
        MockFoT a = new MockFoT(0);
        MockFoT b = new MockFoT(0);
        MockFoT c = new MockFoT(0);
        MockV2Pair pair = _pool(a, b, 1e24, 1e24);
        a.mint(address(this), 1e18);
        a.approve(address(router), 1e18);
        // route claims tokenOut = c but the final hop lands on b
        UmbraRouterV6.ExecuteParams memory p =
            _singleHop(address(a), address(b), address(pair), PT_V2, 1e18, FLAG_LHD);
        p.tokenOut = address(c);
        vm.expectRevert(UmbraRouterV6.BadDirect.selector);
        router.execute(p);
    }

    // ════════════════════════════════════════════════════════════════════════
    // FIRST + LAST direct, single hop: FoT→FoT with ZERO custody — each side
    // taxed exactly once (the physical minimum).
    // ════════════════════════════════════════════════════════════════════════
    function test_first_plus_last_single_hop_zero_custody() public {
        uint16 taxIn = 500;
        uint16 taxOut = 300;
        MockFoT fin = new MockFoT(taxIn);
        MockFoT fout = new MockFoT(taxOut);
        uint256 amt = 10_000e18;
        MockV2Pair pair = _pool(fin, fout, 1_000_000e18, 2_000_000e18);
        fin.mint(address(this), amt);
        fin.approve(address(router), amt);

        uint256 inAtPair = _taxed(amt, taxIn); // ONE input tax
        uint256 expOut = _amountOut(inAtPair, 1_000_000e18, 2_000_000e18);
        uint256 delivered = router.execute(
            _singleHop(address(fin), address(fout), address(pair), PT_V2, amt, FLAG_FHD | FLAG_LHD)
        );
        assertEq(fout.balanceOf(USER), _taxed(expOut, taxOut), "one tax each side");
        assertEq(delivered, fout.balanceOf(USER));
        assertEq(fin.balanceOf(address(router)), 0, "zero input custody");
        assertEq(fout.balanceOf(address(router)), 0, "zero output custody");
    }

    /// Split (2 legs) both ending V2 on tokenOut: delivered is the sum at the recipient.
    function test_lhd_split_two_legs() public {
        uint16 tax = 500;
        MockFoT clean = new MockFoT(0);
        MockFoT fot = new MockFoT(tax);
        uint256 amt = 10_000e18;
        MockV2Pair pairA = _pool(clean, fot, 1_000_000e18, 2_000_000e18);
        MockV2Pair pairB = _pool(clean, fot, 500_000e18, 1_000_000e18);
        clean.mint(address(this), amt);
        clean.approve(address(router), amt);

        UmbraRouterV6.Hop[] memory hopsA = new UmbraRouterV6.Hop[](1);
        hopsA[0] = UmbraRouterV6.Hop(PT_V2, address(clean), address(fot), _v2Word(address(pairA)), bytes32(0));
        UmbraRouterV6.Hop[] memory hopsB = new UmbraRouterV6.Hop[](1);
        hopsB[0] = UmbraRouterV6.Hop(PT_V2, address(clean), address(fot), _v2Word(address(pairB)), bytes32(0));
        UmbraRouterV6.Path[] memory paths = new UmbraRouterV6.Path[](2);
        paths[0] = UmbraRouterV6.Path({inputBps: 6_000, hops: hopsA});
        paths[1] = UmbraRouterV6.Path({inputBps: 4_000, hops: hopsB});

        UmbraRouterV6.ExecuteParams memory p = UmbraRouterV6.ExecuteParams({
            tokenIn: address(clean),
            tokenOut: address(fot),
            amountIn: amt,
            minAmountOut: 0,
            surplusFloor: 0,
            quoteNonce: 0,
            recipient: USER,
            deadline: block.timestamp + 600,
            flags: FLAG_LHD,
            paths: paths,
            permit2: "",
            umbraSig: "",
            plsRate: 0,
            routingAdvantage: 0
        });
        uint256 inA = amt * 6_000 / 10_000;
        uint256 inB = amt - inA;
        uint256 exp = _taxed(_amountOut(inA, 1_000_000e18, 2_000_000e18), tax)
            + _taxed(_amountOut(inB, 500_000e18, 1_000_000e18), tax);
        uint256 delivered = router.execute(p);
        assertEq(fot.balanceOf(USER), exp, "sum of single-taxed legs");
        assertEq(delivered, exp);
    }

    // ════════════════════════════════════════════════════════════════════════
    // Fees live: the flat fee moves to the INPUT on LHD routes.
    // ════════════════════════════════════════════════════════════════════════

    /// ERC20-in custody-input LHD: fee = pulled * cap/10000 in tokenIn to Treasury;
    /// the remainder is swapped and single-tax-delivered. Tally uses `delivered`.
    function test_lhd_fee_in_input_erc20() public {
        _enableFee();
        uint16 tax = 500;
        MockFoT clean = new MockFoT(0);
        MockFoT fot = new MockFoT(tax);
        uint256 amt = 10_000e18;
        MockV2Pair pair = _pool(clean, fot, 1_000_000e18, 2_000_000e18);
        clean.mint(address(this), amt);
        clean.approve(address(router), amt);

        UmbraRouterV6.ExecuteParams memory p =
            _singleHop(address(clean), address(fot), address(pair), PT_V2, amt, FLAG_LHD);
        p.plsRate = 1e18;
        p.quoteNonce = 42;
        p.umbraSig = _sign(p);

        uint256 feeIn = amt * 25 / 10_000;
        uint256 exp = _taxed(_amountOut(amt - feeIn, 1_000_000e18, 2_000_000e18), tax);
        uint256 delivered = router.execute(p);
        assertEq(clean.balanceOf(TREASURY), feeIn, "fee taken in input token");
        assertEq(fot.balanceOf(USER), exp, "principal single-tax delivered");
        assertEq(delivered, exp);
        assertEq(router.totalPlsRouted(), exp, "tally values the realized delivery");
        assertEq(router.swapCount(), 1);
    }

    /// FIRST+LAST direct with fees: two-pull (fee transferFrom + principal to pair).
    function test_fhd_lhd_fee_two_pull() public {
        _enableFee();
        uint16 taxIn = 500;
        MockFoT fin = new MockFoT(taxIn);
        MockFoT clean = new MockFoT(0);
        uint256 amt = 10_000e18;
        MockV2Pair pair = _pool(fin, clean, 1_000_000e18, 2_000_000e18);
        fin.mint(address(this), amt);
        fin.approve(address(router), amt);

        UmbraRouterV6.ExecuteParams memory p =
            _singleHop(address(fin), address(clean), address(pair), PT_V2, amt, FLAG_FHD | FLAG_LHD);
        p.quoteNonce = 43;
        p.umbraSig = _sign(p);

        uint256 feeIn = amt * 25 / 10_000;
        uint256 inAtPair = _taxed(amt - feeIn, taxIn); // principal, ONE tax
        uint256 exp = _amountOut(inAtPair, 1_000_000e18, 2_000_000e18); // clean out, direct
        uint256 delivered = router.execute(p);
        assertEq(fin.balanceOf(TREASURY), _taxed(feeIn, taxIn), "fee slice (taxed in transit)");
        assertEq(clean.balanceOf(USER), exp);
        assertEq(delivered, exp);
        assertEq(fin.balanceOf(address(router)), 0, "zero custody");
    }

    /// FHD+LHD+fee with Permit2 must fail closed (one permit cannot fund two pulls).
    function test_fhd_lhd_fee_permit2_reverts() public {
        _enableFee();
        MockFoT fin = new MockFoT(500);
        MockFoT clean = new MockFoT(0);
        MockV2Pair pair = _pool(fin, clean, 1e24, 1e24);
        fin.mint(address(this), 1e18);
        fin.approve(address(router), 1e18);
        UmbraRouterV6.ExecuteParams memory p =
            _singleHop(address(fin), address(clean), address(pair), PT_V2, 1e18, FLAG_FHD | FLAG_LHD | FLAG_PERMIT2);
        p.quoteNonce = 44;
        p.umbraSig = _sign(p);
        vm.expectRevert(UmbraRouterV6.BadDirect.selector);
        router.execute(p);
    }

    /// Fees live + LHD without a valid signature must revert (fee not bypassable).
    function test_lhd_fee_requires_sig() public {
        _enableFee();
        MockFoT clean = new MockFoT(0);
        MockFoT fot = new MockFoT(500);
        MockV2Pair pair = _pool(clean, fot, 1e24, 1e24);
        clean.mint(address(this), 1e18);
        clean.approve(address(router), 1e18);
        UmbraRouterV6.ExecuteParams memory p =
            _singleHop(address(clean), address(fot), address(pair), PT_V2, 1e18, FLAG_LHD);
        // no signature
        vm.expectRevert(UmbraRouterV6.BadSig.selector);
        router.execute(p);
    }

    /// Dark mode (feeBps = 0): LHD takes no fee and needs no signature.
    function test_lhd_dark_no_fee() public {
        MockFoT clean = new MockFoT(0);
        MockFoT fot = new MockFoT(500);
        uint256 amt = 1_000e18;
        MockV2Pair pair = _pool(clean, fot, 1e24, 2e24);
        clean.mint(address(this), amt);
        clean.approve(address(router), amt);
        uint256 exp = _taxed(_amountOut(amt, 1e24, 2e24), 500);
        uint256 delivered =
            router.execute(_singleHop(address(clean), address(fot), address(pair), PT_V2, amt, FLAG_LHD));
        assertEq(delivered, exp, "full principal routed, no fee");
    }

    /// flags = 0 keeps the exact v5 custody semantics (regression pin).
    function test_flags0_custody_unchanged() public {
        MockFoT a = new MockFoT(0);
        MockFoT b = new MockFoT(0);
        uint256 amt = 1_000e18;
        MockV2Pair pair = _pool(a, b, 1e24, 1e24);
        a.mint(address(this), amt);
        a.approve(address(router), amt);
        uint256 exp = _amountOut(amt, 1e24, 1e24);
        uint256 got = router.execute(_singleHop(address(a), address(b), address(pair), PT_V2, amt, 0));
        assertEq(got, exp);
        assertEq(b.balanceOf(USER), exp);
    }
}
