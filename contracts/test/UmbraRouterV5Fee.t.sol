// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {UmbraRouterV5} from "../src/UmbraRouterV5.sol";
import {IERC20, IWPLS} from "../src/interfaces/Interfaces.sol";

interface IFactoryV2F {
    function getPair(address a, address b) external view returns (address);
}

interface IRouterV2F {
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory);
}

/// End-to-end surplus-fee tests over a real forked PulseX V2 pool (WPLS -> DAI).
/// The swap output is deterministic for a fixed input, so we read the exact `outDelta`
/// from the PulseX router's `getAmountsOut` and then drive each fee scenario by choosing
/// `surplusFloor`. Each test signs the QuoteAttestation with the configured signer key.
contract UmbraRouterV5FeeTest is Test {
    UmbraRouterV5 internal router;

    address constant WPLS = 0xA1077a294dDE1B09bB078844df40758a5D0f9a27;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F; // pDAI
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant PULSEX_V2_FACTORY = 0x29eA7545DEf87022BAdc76323F373EA1e707C523;
    address constant PULSEX_V2_ROUTER = 0x165C3410fC91EF562C50559f7d2289fEbed552d9;

    address constant TREASURY = address(0x7EE45047); // fee recipient
    address constant USER = address(0xBEEF); // swap recipient

    address internal signerAddr;
    uint256 internal signerPk;

    // incrementing per-quote nonce: every signed attestation is single-use (audit H-1),
    // so each `_params` call mints a fresh nonce to avoid cross-test digest collisions.
    uint256 internal nonceCtr;

    function setUp() public {
        vm.createSelectFork("pulse");
        address[] memory empty;
        router = new UmbraRouterV5(WPLS, PERMIT2, empty, empty, empty, empty);
        (signerAddr, signerPk) = makeAddrAndKey("umbra-quote-signer");
        router.proposeFeeRecipient(TREASURY);
        vm.prank(TREASURY);
        router.acceptFeeRecipient();
    }

    function _nextNonce() internal returns (uint256) {
        return ++nonceCtr;
    }

    receive() external payable {}

    // ---- packed V2 pool word ----
    function v2Word(address pair, uint256 feeNum) internal pure returns (uint256) {
        return uint256(uint160(pair)) | (feeNum << 160);
    }

    // ---- the deterministic WPLS -> DAI output for `amt` via the live PulseX V2 pool ----
    function _expectedOut(uint256 amt) internal view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = WPLS;
        path[1] = DAI;
        return IRouterV2F(PULSEX_V2_ROUTER).getAmountsOut(amt, path)[1];
    }

    function _pair() internal view returns (address) {
        address pair = IFactoryV2F(PULSEX_V2_FACTORY).getPair(WPLS, DAI);
        require(pair != address(0), "no WPLS/DAI pair");
        return pair;
    }

    // ---- build a single-path WPLS -> DAI ExecuteParams with the given fee inputs ----
    // `nonce` is the per-quote anti-replay nonce; pass a fresh one per logical trade.
    function _params(uint256 amt, uint256 minOut, uint256 surplusFloor, uint256 nonce, bytes memory sig)
        internal
        view
        returns (UmbraRouterV5.ExecuteParams memory p)
    {
        UmbraRouterV5.Hop[] memory hops = new UmbraRouterV5.Hop[](1);
        hops[0] = UmbraRouterV5.Hop({
            poolType: 0,
            tokenIn: WPLS,
            tokenOut: DAI,
            pool: v2Word(_pair(), 997100), // PulseX V2 = 29 bps
            poolData: bytes32(0)
        });
        UmbraRouterV5.Path[] memory paths = new UmbraRouterV5.Path[](1);
        paths[0] = UmbraRouterV5.Path({inputBps: 10_000, hops: hops});
        p = UmbraRouterV5.ExecuteParams({
            tokenIn: WPLS,
            tokenOut: DAI,
            amountIn: amt,
            minAmountOut: minOut,
            surplusFloor: surplusFloor,
            quoteNonce: nonce,
            recipient: USER,
            deadline: block.timestamp + 600,
            flags: 0,
            paths: paths,
            permit2: "",
            umbraSig: sig,
            plsRate: 1e18,
            routingAdvantage: 0
        });
    }

    // ---- sign the QuoteAttestation matching the params (10-field v4 form: plsRate + routingAdvantage bound) ----
    function _sign(uint256 pk, UmbraRouterV5.ExecuteParams memory p) internal view returns (bytes memory) {
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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _fund(uint256 amt) internal {
        vm.deal(address(this), amt);
        IWPLS(WPLS).deposit{value: amt}();
        IERC20(WPLS).approve(address(router), amt);
    }

    // ============================================================ tests

    /// surplusFloor == outDelta -> surplus 0 -> fee 0 -> user gets the full output, treasury 0.
    function test_no_fee_when_no_surplus() public {
        router.setFeeConfig(5000, 25, signerAddr);

        uint256 amt = 1_000_000e18; // 1M WPLS
        uint256 expected = _expectedOut(amt);
        _fund(amt);

        // surplusFloor at (or above) the exact output -> no surplus
        UmbraRouterV5.ExecuteParams memory p = _params(amt, 0, expected, _nextNonce(), "");
        p.umbraSig = _sign(signerPk, p);

        uint256 userBefore = IERC20(DAI).balanceOf(USER);
        uint256 treasBefore = IERC20(DAI).balanceOf(TREASURY);
        uint256 net = router.execute(p);

        assertEq(net, expected, "net == full output when no surplus");
        assertEq(IERC20(DAI).balanceOf(USER) - userBefore, expected, "user receives full output");
        assertEq(IERC20(DAI).balanceOf(TREASURY) - treasBefore, 0, "treasury gets nothing");
        assertEq(IERC20(DAI).balanceOf(address(router)), 0, "no residual");
    }

    /// surplusFloor far below outDelta -> 50% of surplus would exceed the 25bps cap ->
    /// fee == cap == feeCapBps * outDelta / 1e4, user gets outDelta - cap.
    function test_cap_binds_on_large_surplus() public {
        uint16 capBps = 25;
        router.setFeeConfig(5000, capBps, signerAddr);

        uint256 amt = 1_000_000e18;
        uint256 expected = _expectedOut(amt);
        _fund(amt);

        // floor at 1 wei -> surplus ~= full output -> 50% surplus >> 25bps cap
        UmbraRouterV5.ExecuteParams memory p = _params(amt, 0, 1, _nextNonce(), "");
        p.umbraSig = _sign(signerPk, p);

        uint256 cap = (expected * capBps) / 10_000;
        // sanity: 50% of surplus really does exceed the cap here
        uint256 surplus = expected - 1;
        assertGt((surplus * 5000) / 10_000, cap, "50% surplus must exceed cap for this test");

        uint256 userBefore = IERC20(DAI).balanceOf(USER);
        uint256 treasBefore = IERC20(DAI).balanceOf(TREASURY);
        uint256 net = router.execute(p);

        assertEq(net, expected - cap, "net == outDelta - cap");
        assertEq(IERC20(DAI).balanceOf(USER) - userBefore, expected - cap, "user receives net");
        assertEq(IERC20(DAI).balanceOf(TREASURY) - treasBefore, cap, "treasury receives exactly the cap");
        assertEq(IERC20(DAI).balanceOf(address(router)), 0, "no residual");
    }

    /// 50%-of-surplus path (cap does NOT bind): tiny surplus -> fee == surplus*feeBps/1e4.
    function test_fee_is_half_surplus_when_under_cap() public {
        router.setFeeConfig(5000, 25, signerAddr);

        uint256 amt = 1_000_000e18;
        uint256 expected = _expectedOut(amt);
        _fund(amt);

        // small surplus: 0.1% of output -> 50% of it == 0.05% < 0.25% cap
        uint256 surplus = (expected * 10) / 10_000; // 10 bps
        uint256 floor = expected - surplus;
        UmbraRouterV5.ExecuteParams memory p = _params(amt, 0, floor, _nextNonce(), "");
        p.umbraSig = _sign(signerPk, p);

        uint256 expectedFee = (surplus * 5000) / 10_000; // half the surplus
        uint256 cap = (expected * 25) / 10_000;
        assertLt(expectedFee, cap, "fee must be under cap for this test");

        uint256 net = router.execute(p);
        assertEq(net, expected - expectedFee, "net == outDelta - 50% surplus");
        assertEq(IERC20(DAI).balanceOf(TREASURY), expectedFee, "treasury gets half the surplus");
    }

    /// minAmountOut set above (outDelta - fee) -> revert InsufficientOutput (floor on NET).
    function test_net_below_minAmountOut_reverts() public {
        router.setFeeConfig(5000, 25, signerAddr);

        uint256 amt = 1_000_000e18;
        uint256 expected = _expectedOut(amt);
        _fund(amt);

        uint256 cap = (expected * 25) / 10_000;
        // demand a net 1 wei above what the user can actually receive after the (capped) fee
        UmbraRouterV5.ExecuteParams memory p = _params(amt, expected - cap + 1, 1, _nextNonce(), "");
        p.umbraSig = _sign(signerPk, p);

        vm.expectRevert(UmbraRouterV5.InsufficientOutput.selector);
        router.execute(p);
    }

    /// A signature from the wrong key -> revert BadSig.
    function test_bad_signature_reverts() public {
        router.setFeeConfig(5000, 25, signerAddr);

        uint256 amt = 1_000_000e18;
        _fund(amt);

        (, uint256 wrongPk) = makeAddrAndKey("not-the-signer");
        UmbraRouterV5.ExecuteParams memory p = _params(amt, 0, 1, _nextNonce(), "");
        p.umbraSig = _sign(wrongPk, p); // signed by the wrong key

        vm.expectRevert(UmbraRouterV5.BadSig.selector);
        router.execute(p);
    }

    /// A malformed (wrong-length) signature -> revert BadSig (covers _splitSig guard).
    function test_malformed_signature_reverts() public {
        router.setFeeConfig(5000, 25, signerAddr);

        uint256 amt = 1_000_000e18;
        _fund(amt);

        UmbraRouterV5.ExecuteParams memory p = _params(amt, 0, 1, _nextNonce(), hex"deadbeef"); // 4 bytes, not 65
        vm.expectRevert(UmbraRouterV5.BadSig.selector);
        router.execute(p);
    }

    /// feeBps == 0 -> verification is skipped entirely: an empty sig is fine, fee is 0,
    /// the user receives the full output (ship-dark parity with v2).
    function test_fee_disabled_skips_verification() public {
        // ship dark: feeBps 0, no signer/recipient set
        router.setFeeConfig(0, 25, address(0));

        uint256 amt = 1_000_000e18;
        uint256 expected = _expectedOut(amt);
        _fund(amt);

        // empty sig, arbitrary surplusFloor + nonce -> all ignored because fee path is inert
        UmbraRouterV5.ExecuteParams memory p = _params(amt, 0, 12345, 0, "");

        uint256 userBefore = IERC20(DAI).balanceOf(USER);
        uint256 net = router.execute(p);

        assertEq(net, expected, "user gets full output when fee disabled");
        assertEq(IERC20(DAI).balanceOf(USER) - userBefore, expected, "received full output");
        assertEq(IERC20(DAI).balanceOf(address(router)), 0, "no residual");
    }

    /// H-1 (anti-replay): a valid signed quote that succeeds ONCE must revert BadSig when
    /// the EXACT same params+sig are resubmitted — the digest is marked single-use.
    function test_signed_quote_is_single_use_replay_reverts() public {
        router.setFeeConfig(5000, 25, signerAddr);

        uint256 amt = 1_000_000e18;

        // build + sign once; reuse the identical params (same nonce -> same digest)
        UmbraRouterV5.ExecuteParams memory p = _params(amt, 0, 1, _nextNonce(), "");
        p.umbraSig = _sign(signerPk, p);

        // first submission succeeds
        _fund(amt);
        router.execute(p);

        // exact replay of the same params+sig reverts BadSig (digest already consumed)
        _fund(amt);
        vm.expectRevert(UmbraRouterV5.BadSig.selector);
        router.execute(p);

        // the digest is publicly marked used
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
        assertTrue(router.usedQuote(digest), "consumed digest is recorded as used");
    }

    /// The tally accrues realized PLS volume + routing advantage + swap count from the
    /// signed (tamper-proof) attestation fields. plsRate is PLS-wei per output-wei * 1e18.
    function test_tally_increments_by_signed_fields() public {
        router.setFeeConfig(5000, 33, signerAddr);

        uint256 amt = 1_000_000e18;
        uint256 expected = _expectedOut(amt); // DAI out (18-dec)
        _fund(amt);

        uint256 plsRate = 3e15; // arbitrary signed rate (PLS-wei per DAI-wei * 1e18)
        uint256 advantage = 7_000e18;
        UmbraRouterV5.ExecuteParams memory p = _params(amt, 0, 0, _nextNonce(), "");
        p.plsRate = plsRate;
        p.routingAdvantage = advantage;
        p.umbraSig = _sign(signerPk, p);

        assertEq(router.swapCount(), 0, "starts at zero");
        uint256 net = router.execute(p);

        // outDelta is the gross output (pre-fee); net is post-fee. The tally uses outDelta.
        uint256 cap = (expected * 33) / 10_000;
        uint256 outDelta = net + cap; // surplusFloor=0 => fee == cap
        assertEq(router.totalPlsRouted(), (outDelta * plsRate) / 1e18, "plsRouted == outDelta*rate/1e18");
        assertEq(router.totalRoutingAdvantage(), advantage, "advantage accrues exactly");
        assertEq(router.swapCount(), 1, "one swap counted");
    }

    /// A tampered plsRate (changed after signing) breaks the digest -> BadSig.
    function test_tampered_plsRate_reverts() public {
        router.setFeeConfig(5000, 33, signerAddr);
        uint256 amt = 1_000_000e18;
        _fund(amt);

        UmbraRouterV5.ExecuteParams memory p = _params(amt, 0, 0, _nextNonce(), "");
        p.plsRate = 1e18;
        p.routingAdvantage = 1e18;
        p.umbraSig = _sign(signerPk, p);
        p.plsRate = 2e18; // tamper AFTER signing

        vm.expectRevert(UmbraRouterV5.BadSig.selector);
        router.execute(p);
    }

    /// A tampered routingAdvantage (changed after signing) breaks the digest -> BadSig.
    function test_tampered_routingAdvantage_reverts() public {
        router.setFeeConfig(5000, 33, signerAddr);
        uint256 amt = 1_000_000e18;
        _fund(amt);

        UmbraRouterV5.ExecuteParams memory p = _params(amt, 0, 0, _nextNonce(), "");
        p.plsRate = 1e18;
        p.routingAdvantage = 1e18;
        p.umbraSig = _sign(signerPk, p);
        p.routingAdvantage = 9e18; // tamper AFTER signing

        vm.expectRevert(UmbraRouterV5.BadSig.selector);
        router.execute(p);
    }

    /// Flat-fee invariant: surplusFloor == 0 => surplus == outDelta => 50% of surplus
    /// (500_000 bps math) exceeds the 33-bps cap, so fee == cap == 0.33%*outDelta on EVERY
    /// swap. The user receives outDelta - 0.33%*outDelta.
    function test_flat_fee_when_surplus_floor_zero() public {
        uint16 capBps = 33; // 0.33%
        router.setFeeConfig(5000, capBps, signerAddr);

        uint256 amt = 1_000_000e18;
        uint256 expected = _expectedOut(amt);
        _fund(amt);

        UmbraRouterV5.ExecuteParams memory p = _params(amt, 0, 0, _nextNonce(), ""); // surplusFloor = 0
        p.umbraSig = _sign(signerPk, p);

        uint256 cap = (expected * capBps) / 10_000;
        // sanity: 50% of the (full) surplus exceeds the cap, so the cap binds (flat fee)
        assertGt((expected * 5000) / 10_000, cap, "cap binds -> flat fee");

        uint256 userBefore = IERC20(DAI).balanceOf(USER);
        uint256 treasBefore = IERC20(DAI).balanceOf(TREASURY);
        uint256 net = router.execute(p);

        assertEq(net, expected - cap, "net == outDelta - 0.33%");
        assertEq(IERC20(DAI).balanceOf(USER) - userBefore, expected - cap, "user gets net");
        assertEq(IERC20(DAI).balanceOf(TREASURY) - treasBefore, cap, "treasury gets exactly 0.33%");
        assertEq(IERC20(DAI).balanceOf(address(router)), 0, "no residual");
    }

    /// H-1 (no false positive): two DIFFERENT trades with different quoteNonce, each freshly
    /// signed, both succeed — the single-use guard is keyed on the per-quote digest, not the
    /// (tokenIn, tokenOut, amountIn) tuple, so identical-shaped trades are not blocked.
    function test_distinct_nonces_both_succeed() public {
        router.setFeeConfig(5000, 25, signerAddr);

        uint256 amt = 1_000_000e18;

        // trade A: fresh nonce, fresh signature
        UmbraRouterV5.ExecuteParams memory pa = _params(amt, 0, 1, _nextNonce(), "");
        pa.umbraSig = _sign(signerPk, pa);
        _fund(amt);
        uint256 netA = router.execute(pa);
        assertGt(netA, 0, "trade A delivers output");

        // trade B: same shape but a DIFFERENT nonce -> different digest -> not a replay
        UmbraRouterV5.ExecuteParams memory pb = _params(amt, 0, 1, _nextNonce(), "");
        pb.umbraSig = _sign(signerPk, pb);
        assertTrue(pa.quoteNonce != pb.quoteNonce, "nonces are distinct");
        _fund(amt);
        uint256 netB = router.execute(pb);
        assertGt(netB, 0, "trade B delivers output too");

        assertEq(IERC20(DAI).balanceOf(address(router)), 0, "no residual after both trades");
    }
}
