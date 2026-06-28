// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {UmbraRouterV3} from "../src/UmbraRouterV3.sol";
import {IERC20, IWPLS} from "../src/interfaces/Interfaces.sol";

interface ITideRouterQuery {
    function querySwapSingleTokenExactIn(
        address pool,
        address tokenIn,
        address tokenOut,
        uint256 exactAmountIn,
        address sender,
        bytes calldata userData
    ) external returns (uint256);
}

/// Fork tests for the Balancer-V3 (Tide) execution arm. Swaps real WPLS -> CST through
/// the live Tide Router and asserts the router's measured output equals the on-chain
/// `querySwapSingleTokenExactIn`. CST is 6-dec; WPLS is 18-dec.
///
/// Query mechanism quirk: Tide's VaultExtension checks tx.origin == address(0) as its
/// "is this an eth_call simulation?" gate. cast call / eth_call naturally satisfy this.
/// In forge fork tests, we use vm.prank(sender, address(0)) to set tx.origin = 0.
contract TideHopTest is Test {
    UmbraRouterV3 internal router;

    address constant WPLS = 0xA1077a294dDE1B09bB078844df40758a5D0f9a27;
    address constant CST = 0x600136dA8cc6D1Ea07449514604dc4ab7098dB82;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3; // canonical (input pulls)
    address constant TIDE_ROUTER = 0xd7b324ef7A246c7c77FBee99AED08E0bEdca692d;
    address constant TIDE_PERMIT2 = 0xa0E293567a37F3de1c1C6Fc98d3C58b7652b309E;
    address constant TIDE_POOL = 0x08b4582AfA7876D46304165142910F799EF4EFBf; // CST/WPLS 2-token weighted

    function setUp() public {
        vm.createSelectFork("pulse");
        address[] memory empty;
        router = new UmbraRouterV3(WPLS, PERMIT2, empty, empty, empty);
        router.setV3Router(TIDE_ROUTER, TIDE_PERMIT2, true);
    }

    receive() external payable {}

    function _getWpls(uint256 amt) internal {
        vm.deal(address(this), amt);
        IWPLS(WPLS).deposit{value: amt}();
        IERC20(WPLS).approve(address(router), amt);
    }

    /// Query the Tide Router's expected output. Tide's VaultExtension gates query
    /// execution on tx.origin == address(0) (its eth_call detection pattern). Use
    /// vm.prank(caller, address(0)) to set tx.origin = 0 within the forge test.
    function _queryTide(uint256 amountIn) internal returns (uint256) {
        vm.prank(address(this), address(0));
        return ITideRouterQuery(TIDE_ROUTER).querySwapSingleTokenExactIn(
            TIDE_POOL, WPLS, CST, amountIn, address(1), ""
        );
    }

    // poolType=4: pool addr in the word, router addr left-padded in poolData.
    function _tideParams(uint256 amt) internal view returns (UmbraRouterV3.ExecuteParams memory p) {
        UmbraRouterV3.Hop[] memory hops = new UmbraRouterV3.Hop[](1);
        hops[0] = UmbraRouterV3.Hop({
            poolType: 4,
            tokenIn: WPLS,
            tokenOut: CST,
            pool: uint256(uint160(TIDE_POOL)),
            poolData: bytes32(uint256(uint160(TIDE_ROUTER)))
        });
        UmbraRouterV3.Path[] memory paths = new UmbraRouterV3.Path[](1);
        paths[0] = UmbraRouterV3.Path({inputBps: 10_000, hops: hops});
        p = UmbraRouterV3.ExecuteParams({
            tokenIn: WPLS,
            tokenOut: CST,
            amountIn: amt,
            minAmountOut: 0,
            surplusFloor: 0,
            quoteNonce: 1,
            recipient: address(this),
            deadline: block.timestamp + 600,
            flags: 0,
            paths: paths,
            permit2: "",
            umbraSig: "",
            plsRate: 1e18,
            routingAdvantage: 0
        });
    }

    function test_tide_wpls_to_cst_matches_query() public {
        uint256 amt = 1000e18; // 1000 WPLS
        // ship-dark: feeBps == 0, so no signature needed.
        // Query with tx.origin=0 (Tide's eth_call simulation gate).
        uint256 quoted = _queryTide(amt);
        _getWpls(amt);
        uint256 before = IERC20(CST).balanceOf(address(this));
        uint256 out = router.execute(_tideParams(amt));
        assertEq(IERC20(CST).balanceOf(address(this)) - before, out, "received == out");
        // Allow +-1 wei: Tide's quoteAndRevert pattern runs the swap internally then reverts,
        // which can leave the pool's internal accumulators at a slightly different point for
        // the real swap. The +-1 CST-wei (0.000001 CST) gap is expected and acceptable.
        assertApproxEqAbs(out, quoted, 1, "execute output approx on-chain query (+-1 wei)");
        assertEq(IERC20(CST).balanceOf(address(router)), 0, "no residual out");
        assertEq(IERC20(WPLS).balanceOf(address(router)), 0, "no residual in");
    }

    function test_tide_non_allowlisted_router_reverts() public {
        uint256 amt = 1000e18;
        _getWpls(amt);
        UmbraRouterV3.ExecuteParams memory p = _tideParams(amt);
        // point poolData at an unregistered router
        p.paths[0].hops[0].poolData = bytes32(uint256(uint160(address(0x1234))));
        vm.expectRevert(UmbraRouterV3.BadV3Router.selector);
        router.execute(p);
    }
}
