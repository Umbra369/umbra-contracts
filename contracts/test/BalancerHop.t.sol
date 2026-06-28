// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ForkBase} from "./UmbraRouter.t.sol";
import {UmbraRouter} from "../src/UmbraRouter.sol";
import {IERC20} from "../src/interfaces/Interfaces.sol";

contract BalancerHopTest is ForkBase {
    bytes32 constant PHUX_POOL = 0xce637f9594194e2c8dc05ad32287323bb0603cfe00020000000000000000032e;
    address constant PHUX_TOKEN = 0x5EE84583f67D5EcEa5420dBb42b462896E7f8D06;

    function test_phux_wpls_to_token_executes() public {
        uint256 amt = 1_000e18; // small WPLS amount (pool is WPLS-heavy)
        getWpls(amt);
        IERC20(WPLS).approve(address(router), amt);
        uint256 before = IERC20(PHUX_TOKEN).balanceOf(address(this));

        UmbraRouter.ExecuteParams memory p =
            oneHop(2, WPLS, PHUX_TOKEN, balWord(PHUX_VAULT), PHUX_POOL, amt, 0, 0);
        uint256 out = router.execute(p);

        assertGt(out, 0, "balancer produced output");
        assertEq(IERC20(PHUX_TOKEN).balanceOf(address(this)) - before, out, "received == out");
        assertEq(IERC20(PHUX_TOKEN).balanceOf(address(router)), 0, "no residual out");
        assertEq(IERC20(WPLS).balanceOf(address(router)), 0, "no residual in");
        // the router lazily approved the Vault (cached for subsequent swaps)
        assertGt(IERC20(WPLS).allowance(address(router), PHUX_VAULT), 0, "vault approved");
    }

    function test_phux_approval_cached_second_swap() public {
        uint256 amt = 500e18;
        // first swap approves
        getWpls(amt);
        IERC20(WPLS).approve(address(router), amt);
        router.execute(oneHop(2, WPLS, PHUX_TOKEN, balWord(PHUX_VAULT), PHUX_POOL, amt, 0, 0));
        uint256 allowanceAfter1 = IERC20(WPLS).allowance(address(router), PHUX_VAULT);

        // second swap should not need to re-approve (allowance already max-ish)
        getWpls(amt);
        IERC20(WPLS).approve(address(router), amt);
        uint256 out2 = router.execute(oneHop(2, WPLS, PHUX_TOKEN, balWord(PHUX_VAULT), PHUX_POOL, amt, 0, 0));
        assertGt(out2, 0, "second swap ok");
        // allowance only decreased by the consumed amounts, still very large (was max)
        assertGt(allowanceAfter1, amt, "first approval was large");
    }
}
