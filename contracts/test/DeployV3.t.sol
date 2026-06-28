// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {DeployV3} from "../script/DeployV3.s.sol";
import {UmbraRouterV3} from "../src/UmbraRouterV3.sol";

/// Verifies the v4 deploy script produces a correctly-configured router:
///   - ships dark (feeBps == 0)
///   - feeCapBps == 33 (0.33% ceiling)
///   - SIGNER set (for when fee turns on)
///   - pendingFeeRecipient == TREASURY (distinct from owner; Treasury must accept post-deploy)
///   - feeRecipient still zero (not yet accepted)
///   - Tide router registered with its Permit2
///   - 5 V3 factories registered
///   - no broadcast (pure simulation)
contract DeployV3Test is Test {
    // TREASURY must differ from the default test deployer (address(this) / DEFAULT_SENDER).
    // We use a well-known distinct address so the treasury != deployer guard passes.
    address constant TREASURY     = 0xB529614bde866CAe3907915dA4c13CC3eAD61758;
    address constant SIGNER       = 0xFEC6e126546A9DE4060cf0319713C1b5a81F0C9f;
    address constant TIDE_ROUTER  = 0xd7b324ef7A246c7c77FBee99AED08E0bEdca692d;
    address constant TIDE_PERMIT2 = 0xa0E293567a37F3de1c1C6Fc98d3C58b7652b309E;

    UmbraRouterV3 internal router;
    address internal deployer;

    function setUp() public {
        // Reset UMBRA_TREASURY to a known-good value before each test so guard-revert tests
        // that modify the env do not contaminate subsequent tests.
        vm.setEnv("UMBRA_TREASURY", vm.toString(TREASURY));

        // Call deploy(TREASURY) directly for speed; run() is exercised by the guard tests.
        DeployV3 script = new DeployV3();
        router = script.deploy(TREASURY);
        deployer = router.owner();
    }

    // ---- dark-launch assertions ----

    function test_deploy_feeBps_is_zero_dark() public view {
        assertEq(router.feeBps(), 0, "ships dark: feeBps must be 0");
    }

    function test_deploy_feeCapBps_is_33() public view {
        assertEq(router.feeCapBps(), 33, "feeCapBps must be 33 (0.33%)");
    }

    function test_deploy_signer_is_set() public view {
        assertEq(router.signer(), SIGNER, "signer must equal SIGNER constant");
    }

    // ---- 2-step Treasury feeRecipient ----

    /// feeRecipient is still zero — Treasury has not accepted yet.
    function test_deploy_feeRecipient_zero_until_accepted() public view {
        assertEq(router.feeRecipient(), address(0), "feeRecipient must be 0 before Treasury accepts");
    }

    /// pendingFeeRecipient is TREASURY — waiting for its acceptance call.
    function test_deploy_pendingFeeRecipient_is_treasury() public view {
        assertEq(router.pendingFeeRecipient(), TREASURY, "pendingFeeRecipient must be TREASURY");
    }

    /// Treasury (distinct from owner) can accept and complete the handoff.
    function test_deploy_treasury_accepts_feeRecipient() public {
        vm.prank(TREASURY);
        router.acceptFeeRecipient();

        assertEq(router.feeRecipient(), TREASURY, "feeRecipient must be TREASURY after accept");
        assertEq(router.pendingFeeRecipient(), address(0), "pendingFeeRecipient cleared after accept");
    }

    // ---- Tide (Balancer-V3) router allowlist ----

    function test_deploy_tide_router_registered_with_permit2() public view {
        assertEq(
            router.allowedV3Router(TIDE_ROUTER),
            TIDE_PERMIT2,
            "TIDE_ROUTER must map to TIDE_PERMIT2 in allowedV3Router"
        );
    }

    // ---- V3 factories ----

    function test_deploy_five_v3_factories() public view {
        assertEq(router.v3FactoriesLength(), 5, "must register exactly 5 V3 factories");
    }

    // ---- post-cutover sanity: enabling fee is possible once Treasury has accepted ----

    /// After Treasury accepts, owner can enable the fee (feeBps > 0).
    /// This asserts the full post-dark-launch path works from the deployed state.
    function test_deploy_can_enable_fee_after_treasury_accepts() public {
        vm.prank(TREASURY);
        router.acceptFeeRecipient();

        // owner enables fee: setFeeConfig(5000, 33, SIGNER)
        // feeBps=5000 is the 50% surplus-SHARE, capped at feeCapBps=0.33% of output — NOT a 50% fee.
        vm.prank(deployer);
        router.setFeeConfig(5000, 33, SIGNER);

        assertEq(router.feeBps(), 5000, "feeBps enabled");
        assertEq(router.feeCapBps(), 33, "feeCapBps unchanged");
        assertEq(router.signer(), SIGNER, "signer unchanged");
        assertEq(router.feeRecipient(), TREASURY, "feeRecipient is Treasury");
    }

    // ---- treasury guard: revert tests ----

    /// Guard REVERTS when treasury is address(0) — equivalent to UMBRA_TREASURY unset.
    /// Calls deploy(address(0)) directly to avoid env state pollution across tests.
    function test_deploy_reverts_when_treasury_unset() public {
        DeployV3 script = new DeployV3();
        vm.expectRevert("set UMBRA_TREASURY");
        script.deploy(address(0));
    }

    /// Guard REVERTS when UMBRA_TREASURY equals the deployer/owner (treasury == msg.sender in run()).
    function test_deploy_reverts_when_treasury_equals_deployer() public {
        // address(this) is the test contract — which is also msg.sender when we call script.run().
        // setUp resets the env before this test, so this setEnv is the only value run() sees.
        vm.setEnv("UMBRA_TREASURY", vm.toString(address(this)));
        DeployV3 script = new DeployV3();
        vm.expectRevert("treasury must differ from deployer/owner");
        script.run();
    }
}
