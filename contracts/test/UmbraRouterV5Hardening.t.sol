// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {UmbraRouterV5} from "../src/UmbraRouterV5.sol";
import {IERC20, IWPLS} from "../src/interfaces/Interfaces.sol";

interface IFactoryV2H {
    function getPair(address a, address b) external view returns (address);
}

/// Hardening tests for UmbraRouterV5 v4 deltas.
/// RED (failing) before the three hardening deltas are applied:
///  1. BadV2Pool — direction from real token0/token1, revert on mismatch
///  2. 8-field typehash — recipient + routeHash bound into attestation
///  3. delivered-on-received — return value equals recipient's actual balance delta
contract UmbraRouterV5HardeningTest is Test {
    UmbraRouterV5 internal router;

    address constant WPLS     = 0xA1077a294dDE1B09bB078844df40758a5D0f9a27;
    address constant DAI      = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant PERMIT2  = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant PULSEX_V2_FACTORY = 0x29eA7545DEf87022BAdc76323F373EA1e707C523;
    address constant TREASURY = address(0x7EE45047);
    address constant USER     = address(0xBEEF);

    address internal signerAddr;
    uint256 internal signerPk;

    function setUp() public {
        vm.createSelectFork("pulse");
        address[] memory empty;
        router = new UmbraRouterV5(WPLS, PERMIT2, empty, empty, empty, empty);
        (signerAddr, signerPk) = makeAddrAndKey("umbra-signer-v4");
        router.proposeFeeRecipient(TREASURY);
        vm.prank(TREASURY);
        router.acceptFeeRecipient();
        router.setFeeConfig(5000, 25, signerAddr);
    }

    receive() external payable {}

    function v2Word(address pair, uint256 feeNum) internal pure returns (uint256) {
        return uint256(uint160(pair)) | (feeNum << 160);
    }

    function _fund(uint256 amt) internal {
        vm.deal(address(this), amt);
        IWPLS(WPLS).deposit{value: amt}();
        IERC20(WPLS).approve(address(router), amt);
    }

    function _pair() internal view returns (address) {
        return IFactoryV2H(PULSEX_V2_FACTORY).getPair(WPLS, DAI);
    }

    function _buildParams(uint256 amt, uint256 floor, uint256 nonce, bytes memory sig)
        internal view returns (UmbraRouterV5.ExecuteParams memory p)
    {
        UmbraRouterV5.Hop[] memory hops = new UmbraRouterV5.Hop[](1);
        hops[0] = UmbraRouterV5.Hop({
            poolType: 0, tokenIn: WPLS, tokenOut: DAI,
            pool: v2Word(_pair(), 997100), poolData: bytes32(0)
        });
        UmbraRouterV5.Path[] memory paths = new UmbraRouterV5.Path[](1);
        paths[0] = UmbraRouterV5.Path({inputBps: 10_000, hops: hops});
        p = UmbraRouterV5.ExecuteParams({
            tokenIn: WPLS, tokenOut: DAI, amountIn: amt,
            minAmountOut: 0, surplusFloor: floor, quoteNonce: nonce,
            recipient: USER, deadline: block.timestamp + 600,
            flags: 0, paths: paths, permit2: "", umbraSig: sig,
            plsRate: 1e18, routingAdvantage: 0
        });
    }

    /// Sign with the v4 10-field typehash (plsRate + routingAdvantage bound).
    function _sign8(uint256 pk, UmbraRouterV5.ExecuteParams memory p) internal view returns (bytes memory) {
        bytes32 typeHash = keccak256(
            "QuoteAttestation(address tokenIn,address tokenOut,uint256 amountIn,uint256 surplusFloor,uint256 nonce,uint256 deadline,address recipient,bytes32 routeHash,uint256 plsRate,uint256 routingAdvantage)"
        );
        bytes32 rh = keccak256(abi.encode(p.paths));
        bytes32 structHash = keccak256(
            abi.encode(typeHash, p.tokenIn, p.tokenOut, p.amountIn, p.surplusFloor, p.quoteNonce, p.deadline, p.recipient, rh, p.plsRate, p.routingAdvantage)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", router.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    // ────────────────────────────────────────────────────────────────────────
    // RED 1: BadV2Pool — mismatch between hop tokenIn/tokenOut and the pair's
    // actual token0/token1 must revert.
    //
    // Current code uses address-sort (`hop.tokenIn < hop.tokenOut`) and never
    // calls token0()/token1(), so it never reverts here.
    //
    // COMPILE RED: UmbraRouterV5.BadV2Pool does not exist yet → compile error.
    // ────────────────────────────────────────────────────────────────────────
    function test_bad_v2_pool_reverts_on_mismatch() public {
        address fakePair = address(0xFACE0001);
        // mock token0/token1 to values that are neither WPLS nor DAI
        vm.mockCall(fakePair, abi.encodeWithSignature("token0()"), abi.encode(address(0x1111)));
        vm.mockCall(fakePair, abi.encodeWithSignature("token1()"), abi.encode(address(0x2222)));
        // mock WPLS.transfer so funds don't fail before the direction check
        vm.mockCall(
            WPLS,
            abi.encodeWithSelector(bytes4(0xa9059cbb), fakePair, uint256(1e18)),
            abi.encode(true)
        );

        uint256 amt = 1e18;
        _fund(amt);

        UmbraRouterV5.Hop[] memory hops = new UmbraRouterV5.Hop[](1);
        hops[0] = UmbraRouterV5.Hop({
            poolType: 0, tokenIn: WPLS, tokenOut: DAI,
            pool: v2Word(fakePair, 997000), poolData: bytes32(0)
        });
        UmbraRouterV5.Path[] memory paths = new UmbraRouterV5.Path[](1);
        paths[0] = UmbraRouterV5.Path({inputBps: 10_000, hops: hops});
        UmbraRouterV5.ExecuteParams memory p = UmbraRouterV5.ExecuteParams({
            tokenIn: WPLS, tokenOut: DAI, amountIn: amt,
            minAmountOut: 0, surplusFloor: 0, quoteNonce: 1,
            recipient: address(this), deadline: block.timestamp + 600,
            flags: 0, paths: paths, permit2: "", umbraSig: "",
            plsRate: 1e18, routingAdvantage: 0
        });

        // RED: BadV2Pool error does not exist yet — causes compile error.
        // After adding the error + fix, this reverts correctly.
        vm.expectRevert(UmbraRouterV5.BadV2Pool.selector);
        router.execute(p);
    }

    // ────────────────────────────────────────────────────────────────────────
    // RED 2: 8-field typehash — a sig over the 8-field form must be ACCEPTED.
    //
    // Currently the contract uses the 6-field typehash, so an 8-field sig
    // produces a different digest and fails BadSig.
    //
    // RED: router.execute() reverts with BadSig; we expect success → test fails.
    // GREEN after typehash upgrade: executes and returns delivered > 0.
    // ────────────────────────────────────────────────────────────────────────
    function test_8field_sig_accepted_after_typehash_upgrade() public {
        uint256 amt = 1_000_000e18;
        _fund(amt);
        UmbraRouterV5.ExecuteParams memory p = _buildParams(amt, 0, 42, "");
        p.umbraSig = _sign8(signerPk, p);

        // RED: currently fails with BadSig (contract uses 6-field typehash).
        // GREEN after typehash upgrade: succeeds and delivers DAI to USER.
        uint256 delivered = router.execute(p);
        assertGt(delivered, 0, "8-field sig must produce non-zero output after upgrade");
    }

    // ────────────────────────────────────────────────────────────────────────
    // RED 3: delivered-on-received — return value must equal recipient's
    // actual balance delta (FoT-output safe).
    //
    // For non-FoT DAI, net == delivered, so this test is GREEN for both old
    // and new code. Its purpose is to pin the invariant; the FoT enforcement
    // path (revert when delivered < minAmountOut) is the real fix.
    //
    // We run with fee disabled to keep the math clean. This test will remain
    // GREEN through the refactor as a regression guard.
    // ────────────────────────────────────────────────────────────────────────
    function test_return_value_equals_recipient_delta_non_fot() public {
        // turn off the surplus fee so we don't need a sig
        router.setFeeConfig(0, 25, address(0));

        uint256 amt = 1_000_000e18;
        _fund(amt);
        UmbraRouterV5.ExecuteParams memory p = _buildParams(amt, 0, 0, "");
        p.umbraSig = "";

        uint256 before = IERC20(DAI).balanceOf(USER);
        uint256 returned = router.execute(p);
        uint256 delta = IERC20(DAI).balanceOf(USER) - before;

        assertEq(returned, delta, "return value must equal recipient's received delta");
    }
}
