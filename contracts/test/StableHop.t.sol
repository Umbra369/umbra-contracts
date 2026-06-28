// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ForkBase} from "./UmbraRouter.t.sol";
import {UmbraRouter} from "../src/UmbraRouter.sol";
import {IERC20, IStableSwap} from "../src/interfaces/Interfaces.sol";

/// PulseX StableSwap (Curve-style) hop execution.
contract StableHopTest is ForkBase {
    // coins: 0 = USDT, 1 = USDC, 2 = DAI
    function test_stable_usdt_to_usdc_exact() public {
        uint256 amt = 100_000e6; // 100k USDT (6-dec)
        uint256 expected = IStableSwap(PULSEX_STABLE_3POOL).get_dy(0, 1, amt);
        assertGt(expected, 0, "get_dy nonzero");

        deal(USDT, address(this), amt);
        IERC20(USDT).approve(address(router), amt);
        uint256 before = IERC20(USDC).balanceOf(address(this));

        // get_dy is a view estimate; exchange can differ by a rounding hair, so use a
        // tight slippage floor and assert closeness rather than bit-equality.
        UmbraRouter.ExecuteParams memory p = oneHop(
            3, USDT, USDC, stableWord(PULSEX_STABLE_3POOL, 0, 1), bytes32(0), amt, expected * 9999 / 10000, 0
        );
        uint256 out = router.execute(p);

        assertApproxEqRel(out, expected, 0.0001e18, "stable out ~= get_dy (<=0.01%)");
        assertEq(IERC20(USDC).balanceOf(address(this)) - before, out, "received == out");
        assertEq(IERC20(USDT).balanceOf(address(router)), 0, "no residual in");
        assertEq(IERC20(USDC).balanceOf(address(router)), 0, "no residual out");
        assertGt(IERC20(USDT).allowance(address(router), PULSEX_STABLE_3POOL), 0, "pool approved");
    }

    function test_stable_usdc_to_usdt_reverse() public {
        uint256 amt = 50_000e6; // 50k USDC
        uint256 expected = IStableSwap(PULSEX_STABLE_3POOL).get_dy(1, 0, amt); // USDC(1)->USDT(0)

        deal(USDC, address(this), amt);
        IERC20(USDC).approve(address(router), amt);
        uint256 before = IERC20(USDT).balanceOf(address(this));

        // get_dy is a view estimate; exchange can differ by a rounding hair, so
        // assert closeness rather than bit-equality (real routes carry a slippage floor).
        UmbraRouter.ExecuteParams memory p =
            oneHop(3, USDC, USDT, stableWord(PULSEX_STABLE_3POOL, 1, 0), bytes32(0), amt, 0, 0);
        uint256 out = router.execute(p);

        assertApproxEqRel(out, expected, 0.0001e18, "reverse out ~= get_dy (<=0.01%)");
        assertEq(IERC20(USDT).balanceOf(address(this)) - before, out, "received == out");
        assertEq(IERC20(USDC).balanceOf(address(router)), 0, "no residual in");
    }

    /// A non-allowlisted "stable pool" must be rejected (no approval theft).
    function test_stable_unlisted_pool_reverts() public {
        uint256 amt = 1_000e6;
        deal(USDT, address(this), amt);
        IERC20(USDT).approve(address(router), amt);
        address rogue = address(0xBADBAD);
        UmbraRouter.ExecuteParams memory p =
            oneHop(3, USDT, USDC, stableWord(rogue, 0, 1), bytes32(0), amt, 0, 0);
        vm.expectRevert(UmbraRouter.BadStablePool.selector);
        router.execute(p);
    }
}
