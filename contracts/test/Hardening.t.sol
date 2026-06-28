// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ForkBase} from "./UmbraRouter.t.sol";
import {UmbraRouter} from "../src/UmbraRouter.sol";
import {IERC20} from "../src/interfaces/Interfaces.sol";

interface IFac2v {
    function getPair(address a, address b) external view returns (address);
}

/// Tests for the post-audit hardening: residual funds are inert, the Balancer
/// vault is allowlisted, and degenerate same-token routes are rejected.
contract HardeningTest is ForkBase {
    bytes32 constant PHUX_POOL = 0xce637f9594194e2c8dc05ad32287323bb0603cfe00020000000000000000032e;
    address constant PHUX_TOKEN = 0x5EE84583f67D5EcEa5420dBb42b462896E7f8D06;

    function test_same_token_reverts() public {
        uint256 amt = 1_000e18;
        deal(DAI, address(this), amt);
        IERC20(DAI).approve(address(router), amt);
        UmbraRouter.ExecuteParams memory p =
            oneHop(0, DAI, DAI, v2Word(address(0xdEaD), 997100), bytes32(0), amt, 0, 0);
        vm.expectRevert(UmbraRouter.SameToken.selector);
        router.execute(p);
    }

    function test_unallowlisted_vault_reverts() public {
        uint256 amt = 100e18;
        getWpls(amt);
        IERC20(WPLS).approve(address(router), amt);
        // a vault address that is NOT in the allowlist must revert before any approval
        UmbraRouter.ExecuteParams memory p =
            oneHop(2, WPLS, PHUX_TOKEN, balWord(address(0x1234)), PHUX_POOL, amt, 0, 0);
        vm.expectRevert(UmbraRouter.BadVault.selector);
        router.execute(p);
    }

    /// The key post-audit invariant: tokens force-sent into the router are inert —
    /// an attacker cannot capture them by naming them as tokenOut of a tiny route.
    function test_force_sent_residual_not_drainable() public {
        uint256 stuck = 5_000e18;
        deal(DAI, address(router), stuck); // simulate force-sent / stranded DAI

        address pair = IFac2v(PULSEX_V2_FACTORY).getPair(WPLS, DAI);
        uint256 amt = 1_000e18;
        getWpls(amt);
        IERC20(WPLS).approve(address(router), amt);
        uint256 before = IERC20(DAI).balanceOf(address(this));

        UmbraRouter.ExecuteParams memory p =
            oneHop(0, WPLS, DAI, v2Word(pair, 997100), bytes32(0), amt, 0, 0);
        uint256 out = router.execute(p);

        // the caller receives ONLY their route's output, never the stranded residual
        assertEq(IERC20(DAI).balanceOf(address(this)) - before, out, "only route output");
        assertLt(out, stuck, "sanity: route output < residual");
        // the residual stays in the router (only owner sweep can move it)
        assertGe(IERC20(DAI).balanceOf(address(router)), stuck, "residual intact");
    }

    /// And the input side: residual input-token can't be swept into a route either.
    function test_force_sent_input_residual_inert() public {
        uint256 stuck = 10_000e18;
        getWpls(stuck);
        IERC20(WPLS).transfer(address(router), stuck); // stranded WPLS in the router

        address pair = IFac2v(PULSEX_V2_FACTORY).getPair(WPLS, DAI);
        uint256 amt = 1_000e18;
        getWpls(amt);
        IERC20(WPLS).approve(address(router), amt);

        UmbraRouter.ExecuteParams memory p =
            oneHop(0, WPLS, DAI, v2Word(pair, 997100), bytes32(0), amt, 0, 0);
        router.execute(p);

        // the route only spent the pulled `amt`; the stranded WPLS is untouched
        assertGe(IERC20(WPLS).balanceOf(address(router)), stuck, "stranded input untouched");
    }

    // --- post-audit owner hardening (2026-06-21) ---

    /// Ownership is a two-step handoff: nominate, then the nominee accepts. Prevents
    /// bricking admin by transferring to a wrong/zero address.
    function test_two_step_ownership() public {
        address newOwner = address(0xBEEF);
        assertEq(router.owner(), address(this));
        router.transferOwnership(newOwner);
        assertEq(router.owner(), address(this), "owner unchanged until accepted");
        assertEq(router.pendingOwner(), newOwner);

        vm.prank(address(0xDEAD)); // a non-nominee cannot accept
        vm.expectRevert(UmbraRouter.NotPendingOwner.selector);
        router.acceptOwnership();

        vm.prank(newOwner);
        router.acceptOwnership();
        assertEq(router.owner(), newOwner);
        assertEq(router.pendingOwner(), address(0));
    }

    /// The V3 callback fallback fails closed on short calldata (guards the msg.data[4:] slice).
    function test_fallback_short_calldata_reverts() public {
        (bool ok,) = address(router).call(hex"010203"); // 3 bytes -> fallback, len < 4
        assertFalse(ok, "short calldata to fallback must revert");
    }

    /// revokeApproval is owner-only and zeroes a standing approval (incident response).
    function test_revoke_approval_owner_only() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(UmbraRouter.NotOwner.selector);
        router.revokeApproval(DAI, address(0x1234));

        router.revokeApproval(DAI, address(0x1234)); // owner: must not revert
        assertEq(IERC20(DAI).allowance(address(router), address(0x1234)), 0);
    }
}
