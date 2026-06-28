// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {UmbraRouterV5} from "../src/UmbraRouterV5.sol";
import {IERC20, IWPLS, IAlgebraFactory} from "../src/interfaces/Interfaces.sol";

interface IAlgebraQuoter {
    // Non-view in Algebra (simulates + reverts internally), but returns cleanly via eth_call.
    function quoteExactInputSingle(address tokenIn, address tokenOut, uint256 amountIn, uint160 limitSqrtPrice)
        external
        returns (uint256 amountOut, uint16 fee);
}

/// Fork test: execute a real swap through switch.win (SwitchX, Algebra V1.x) and
/// cross-check the delivered output against SwitchX's own Quoter at the same block.
/// Proves the PT_ALGEBRA hop end-to-end: `poolByPair` authentication, the swap ABI
/// shared with Uniswap V3 (selector 0x128acb08), and the `algebraSwapCallback`
/// (selector 0x2c8958f6) landing in `fallback()` → `_v3Pay` under the pool guard.
///
/// Addresses verified on-chain (chain 369): factory, quoter, and the WPLS/PLSX pool
/// (~90k WPLS deep, in-range) per the SwitchX integration report.
contract UmbraRouterV5AlgebraTest is Test {
    UmbraRouterV5 internal router;

    address constant WPLS = 0xA1077a294dDE1B09bB078844df40758a5D0f9a27;
    address constant PLSX = 0x95B303987A60C71504D99Aa1b13B4DA07b0790ab;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant SWITCH_FACTORY = 0x24398b6ea5434339934D999E431807B1C157b4Fd;
    address constant SWITCH_QUOTER = 0x96008faF3D5c5361900aF0290156f4eDaC443336;
    address constant USER = address(0xBEEF);

    uint8 constant PT_ALGEBRA = 5;

    function setUp() public {
        vm.createSelectFork("pulse");
        address[] memory empty;
        address[] memory algebra = new address[](1);
        algebra[0] = SWITCH_FACTORY;
        router = new UmbraRouterV5(WPLS, PERMIT2, empty, empty, empty, algebra);
    }

    receive() external payable {}

    function _algebraWord(address pool, uint8 forkId) internal pure returns (uint256) {
        return uint256(uint160(pool)) | (uint256(forkId) << 184);
    }

    function _params(address pool, uint256 amt) internal view returns (UmbraRouterV5.ExecuteParams memory p) {
        UmbraRouterV5.Hop[] memory hops = new UmbraRouterV5.Hop[](1);
        hops[0] = UmbraRouterV5.Hop({
            poolType: PT_ALGEBRA,
            tokenIn: WPLS,
            tokenOut: PLSX,
            pool: _algebraWord(pool, 0),
            poolData: bytes32(0)
        });
        UmbraRouterV5.Path[] memory paths = new UmbraRouterV5.Path[](1);
        paths[0] = UmbraRouterV5.Path({inputBps: 10_000, hops: hops});
        p = UmbraRouterV5.ExecuteParams({
            tokenIn: WPLS,
            tokenOut: PLSX,
            amountIn: amt,
            minAmountOut: 0,
            surplusFloor: 0,
            quoteNonce: 0,
            recipient: USER,
            deadline: block.timestamp + 600,
            flags: 0,
            paths: paths,
            permit2: "",
            umbraSig: "",
            plsRate: 0,
            routingAdvantage: 0
        });
    }

    function test_algebra_wpls_to_plsx_matches_quoter() public {
        uint256 amt = 1000e18;
        address pool = IAlgebraFactory(SWITCH_FACTORY).poolByPair(WPLS, PLSX);
        require(pool != address(0), "no switch WPLS/PLSX pool");

        // SwitchX's own quoter, at this same block (limit 0 = unconstrained). The
        // quoter simulates + reverts internally, leaving pool state unchanged.
        (uint256 quoted,) = IAlgebraQuoter(SWITCH_QUOTER).quoteExactInputSingle(WPLS, PLSX, amt, 0);
        assertGt(quoted, 0, "quoter returned output");

        vm.deal(address(this), amt);
        IWPLS(WPLS).deposit{value: amt}();
        IERC20(WPLS).approve(address(router), amt);

        uint256 before = IERC20(PLSX).balanceOf(USER);
        uint256 delivered = router.execute(_params(pool, amt));
        uint256 got = IERC20(PLSX).balanceOf(USER) - before;

        assertEq(delivered, got, "return value equals recipient delta");
        assertGt(delivered, 0, "produced PLSX output");
        assertApproxEqRel(delivered, quoted, 0.01e18, "router output within 1% of SwitchX quoter");

        assertEq(IERC20(WPLS).balanceOf(address(router)), 0, "no WPLS residual");
        assertEq(IERC20(PLSX).balanceOf(address(router)), 0, "no PLSX residual");
    }

    /// A pool address that doesn't match `poolByPair(tokenIn, tokenOut)` is rejected,
    /// so a malicious/forged pool word cannot be routed through (the whole tx reverts,
    /// returning the pulled input).
    function test_algebra_bad_pool_reverts() public {
        uint256 amt = 1e18;
        vm.deal(address(this), amt);
        IWPLS(WPLS).deposit{value: amt}();
        IERC20(WPLS).approve(address(router), amt);
        UmbraRouterV5.ExecuteParams memory p = _params(address(0xDEAD), amt);
        vm.expectRevert(UmbraRouterV5.BadAlgebraPool.selector);
        router.execute(p);
    }
}
