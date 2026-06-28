// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {UmbraRouterV5} from "../src/UmbraRouterV5.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Deterministic (no-fork) mocks proving the v5 FoT single-tax fast-path.
// ─────────────────────────────────────────────────────────────────────────────

/// Minimal ERC20 with an optional fee-on-transfer (the tax is burned). `mint` is
/// untaxed (used to seed pool reserves); `transfer`/`transferFrom` apply the tax.
/// `taxBps == 0` makes it a plain token (used for output/intermediate legs).
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

/// Faithful constant-product pair. Measures input as (balance − reserve), enforces the
/// exact same fee/AMM formula the router uses (so an over-asking router would revert on
/// the K guard), and delivers the requested output. Reserves are synced after seeding.
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

contract UmbraRouterV5DirectTest is Test {
    UmbraRouterV5 internal router;

    address constant WPLS = 0xA1077a294dDE1B09bB078844df40758a5D0f9a27;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant USER = address(0xBEEF);

    uint8 constant FLAG_FIRST_HOP_DIRECT = 8;
    uint8 constant FLAG_INPUT_IS_NATIVE = 2;
    uint8 constant PT_V2 = 0;
    uint8 constant PT_V3 = 1;

    function setUp() public {
        address[] memory empty;
        router = new UmbraRouterV5(WPLS, PERMIT2, empty, empty, empty, empty);
        // router deploys dark (feeBps == 0) → no attestation needed.
    }

    // ---- helpers (mirror the contract's integer math) ----
    function _v2Word(address pair, uint256 feeNum) internal pure returns (uint256) {
        return uint256(uint160(pair)) | (feeNum << 160);
    }

    function _amountOut(uint256 inAmt, uint256 rIn, uint256 rOut) internal pure returns (uint256) {
        uint256 inWithFee = inAmt * 997000;
        return (inWithFee * rOut) / (rIn * 1_000_000 + inWithFee);
    }

    function _taxed(uint256 amt, uint16 bps) internal pure returns (uint256) {
        return amt * (10_000 - bps) / 10_000;
    }

    function _fixture(uint16 taxBps, uint256 rFot, uint256 rOut)
        internal
        returns (MockFoT fot, MockFoT outTok, MockV2Pair pair)
    {
        fot = new MockFoT(taxBps);
        outTok = new MockFoT(0);
        pair = new MockV2Pair(address(fot), address(outTok));
        fot.mint(address(pair), rFot);
        outTok.mint(address(pair), rOut);
        pair.sync();
    }

    function _singleHop(address tin, address tout, address pair, uint8 poolType, uint256 amt, uint8 flags)
        internal
        view
        returns (UmbraRouterV5.ExecuteParams memory p)
    {
        UmbraRouterV5.Hop[] memory hops = new UmbraRouterV5.Hop[](1);
        hops[0] = UmbraRouterV5.Hop({
            poolType: poolType,
            tokenIn: tin,
            tokenOut: tout,
            pool: _v2Word(pair, 997000),
            poolData: bytes32(0)
        });
        UmbraRouterV5.Path[] memory paths = new UmbraRouterV5.Path[](1);
        paths[0] = UmbraRouterV5.Path({inputBps: 10_000, hops: hops});
        p = UmbraRouterV5.ExecuteParams({
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

    // ════════════════════════════════════════════════════════════════════════
    // Headline: the direct path taxes a FoT sell ONCE; the standard path twice.
    // Same reserves, same input → the direct path delivers strictly more, and
    // each equals the exact AMM output for its (single- vs double-) taxed input.
    // ════════════════════════════════════════════════════════════════════════
    function test_direct_path_halves_fot_tax() public {
        uint16 tax = 500; // 5%
        uint256 rFot = 1_000_000e18;
        uint256 rOut = 2_000_000e18;
        uint256 amt = 10_000e18;

        // standard (flags = 0): pulled to router, then router → pair = two taxes
        (MockFoT fotS, MockFoT outS, MockV2Pair pairS) = _fixture(tax, rFot, rOut);
        fotS.mint(address(this), amt);
        fotS.approve(address(router), amt);
        uint256 deliveredStd =
            router.execute(_singleHop(address(fotS), address(outS), address(pairS), PT_V2, amt, 0));

        // direct (FIRST_HOP_DIRECT): user → pair = one tax
        (MockFoT fotD, MockFoT outD, MockV2Pair pairD) = _fixture(tax, rFot, rOut);
        fotD.mint(address(this), amt);
        fotD.approve(address(router), amt);
        uint256 deliveredDirect = router.execute(
            _singleHop(address(fotD), address(outD), address(pairD), PT_V2, amt, FLAG_FIRST_HOP_DIRECT)
        );

        uint256 oneTax = _taxed(amt, tax); // amt·0.95
        uint256 twoTax = _taxed(oneTax, tax); // amt·0.95²
        assertEq(deliveredStd, _amountOut(twoTax, rFot, rOut), "standard double-taxes");
        assertEq(deliveredDirect, _amountOut(oneTax, rFot, rOut), "direct single-taxes");
        assertGt(deliveredDirect, deliveredStd, "direct delivers strictly more");

        // recipient received exactly the delivered amount; router holds nothing
        assertEq(outS.balanceOf(USER), deliveredStd, "std recipient credited");
        assertEq(outD.balanceOf(USER), deliveredDirect, "direct recipient credited");
        assertEq(fotD.balanceOf(address(router)), 0, "no input residual (direct)");
        assertEq(outD.balanceOf(address(router)), 0, "no output residual (direct)");
        assertEq(fotS.balanceOf(address(router)), 0, "no input residual (std)");
    }

    // ════════════════════════════════════════════════════════════════════════
    // Multi-hop single path with the direct flag: only the FIRST (FoT) hop is
    // funded user→pair; the second hop runs router-funded as usual.
    // ════════════════════════════════════════════════════════════════════════
    function test_direct_multihop_only_first_hop_taxed() public {
        uint16 tax = 500;
        uint256 rFot = 1_000_000e18;
        uint256 rMid = 1_000_000e18;
        uint256 rOut = 2_000_000e18;
        uint256 amt = 10_000e18;

        MockFoT fot = new MockFoT(tax);
        MockFoT mid = new MockFoT(0);
        MockFoT outTok = new MockFoT(0);
        MockV2Pair pairA = new MockV2Pair(address(fot), address(mid));
        MockV2Pair pairB = new MockV2Pair(address(mid), address(outTok));
        fot.mint(address(pairA), rFot);
        mid.mint(address(pairA), rMid);
        pairA.sync();
        mid.mint(address(pairB), rMid);
        outTok.mint(address(pairB), rOut);
        pairB.sync();

        fot.mint(address(this), amt);
        fot.approve(address(router), amt);

        UmbraRouterV5.Hop[] memory hops = new UmbraRouterV5.Hop[](2);
        hops[0] = UmbraRouterV5.Hop(PT_V2, address(fot), address(mid), _v2Word(address(pairA), 997000), bytes32(0));
        hops[1] = UmbraRouterV5.Hop(PT_V2, address(mid), address(outTok), _v2Word(address(pairB), 997000), bytes32(0));
        UmbraRouterV5.Path[] memory paths = new UmbraRouterV5.Path[](1);
        paths[0] = UmbraRouterV5.Path(10_000, hops);
        UmbraRouterV5.ExecuteParams memory p = UmbraRouterV5.ExecuteParams({
            tokenIn: address(fot),
            tokenOut: address(outTok),
            amountIn: amt,
            minAmountOut: 0,
            surplusFloor: 0,
            quoteNonce: 0,
            recipient: USER,
            deadline: block.timestamp + 600,
            flags: FLAG_FIRST_HOP_DIRECT,
            paths: paths,
            permit2: "",
            umbraSig: "",
            plsRate: 0,
            routingAdvantage: 0
        });

        uint256 delivered = router.execute(p);

        uint256 midOut = _amountOut(_taxed(amt, tax), rFot, rMid); // first hop: one tax
        uint256 expOut = _amountOut(midOut, rMid, rOut); // second hop: no tax (mid is plain)
        assertEq(delivered, expOut, "first hop taxed once, second untaxed");
        assertEq(fot.balanceOf(address(router)), 0, "no FoT residual");
        assertEq(mid.balanceOf(address(router)), 0, "no mid residual");
        assertEq(outTok.balanceOf(address(router)), 0, "no out residual");
    }

    // ════════════════════════════════════════════════════════════════════════
    // Defensive preconditions: a mis-set FIRST_HOP_DIRECT flag must revert, never
    // mis-execute. (The engine only sets it for single-path V2-first ERC20 routes.)
    // ════════════════════════════════════════════════════════════════════════
    function test_direct_reverts_on_multipath() public {
        (MockFoT fot, MockFoT outTok, MockV2Pair pair) = _fixture(500, 1_000_000e18, 2_000_000e18);
        fot.mint(address(this), 1e18);
        fot.approve(address(router), 1e18);

        UmbraRouterV5.Hop[] memory hops = new UmbraRouterV5.Hop[](1);
        hops[0] = UmbraRouterV5.Hop(PT_V2, address(fot), address(outTok), _v2Word(address(pair), 997000), bytes32(0));
        UmbraRouterV5.Path[] memory paths = new UmbraRouterV5.Path[](2);
        paths[0] = UmbraRouterV5.Path(5_000, hops);
        paths[1] = UmbraRouterV5.Path(5_000, hops);
        UmbraRouterV5.ExecuteParams memory p = UmbraRouterV5.ExecuteParams({
            tokenIn: address(fot),
            tokenOut: address(outTok),
            amountIn: 1e18,
            minAmountOut: 0,
            surplusFloor: 0,
            quoteNonce: 0,
            recipient: USER,
            deadline: block.timestamp + 600,
            flags: FLAG_FIRST_HOP_DIRECT,
            paths: paths,
            permit2: "",
            umbraSig: "",
            plsRate: 0,
            routingAdvantage: 0
        });
        vm.expectRevert(UmbraRouterV5.BadDirect.selector);
        router.execute(p);
    }

    function test_direct_reverts_on_native_in() public {
        (MockFoT fot, MockFoT outTok, MockV2Pair pair) = _fixture(500, 1_000_000e18, 2_000_000e18);
        // INPUT_IS_NATIVE + FIRST_HOP_DIRECT is contradictory → BadDirect
        UmbraRouterV5.ExecuteParams memory p = _singleHop(
            address(fot), address(outTok), address(pair), PT_V2, 1e18, FLAG_FIRST_HOP_DIRECT | FLAG_INPUT_IS_NATIVE
        );
        vm.expectRevert(UmbraRouterV5.BadDirect.selector);
        router.execute(p);
    }

    function test_direct_reverts_on_non_v2_first_hop() public {
        (MockFoT fot, MockFoT outTok, MockV2Pair pair) = _fixture(500, 1_000_000e18, 2_000_000e18);
        fot.mint(address(this), 1e18);
        fot.approve(address(router), 1e18);
        // first hop typed PT_V3 with the direct flag → BadDirect (direct only funds V2)
        UmbraRouterV5.ExecuteParams memory p =
            _singleHop(address(fot), address(outTok), address(pair), PT_V3, 1e18, FLAG_FIRST_HOP_DIRECT);
        vm.expectRevert(UmbraRouterV5.BadDirect.selector);
        router.execute(p);
    }

    // ════════════════════════════════════════════════════════════════════════
    // Regression: the standard (non-direct) path still executes a plain single
    // hop after the execute() refactor.
    // ════════════════════════════════════════════════════════════════════════
    function test_standard_path_plain_single_hop() public {
        uint256 rIn = 1_000_000e18;
        uint256 rOut = 2_000_000e18;
        uint256 amt = 10_000e18;
        (MockFoT tin, MockFoT tout, MockV2Pair pair) = _fixture(0, rIn, rOut); // taxBps 0 = plain
        tin.mint(address(this), amt);
        tin.approve(address(router), amt);
        uint256 delivered = router.execute(_singleHop(address(tin), address(tout), address(pair), PT_V2, amt, 0));
        assertEq(delivered, _amountOut(amt, rIn, rOut), "plain single hop unchanged");
        assertEq(tout.balanceOf(USER), delivered, "recipient credited");
    }
}
