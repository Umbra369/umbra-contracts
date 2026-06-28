// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ForkBase} from "./UmbraRouter.t.sol";
import {UmbraRouter} from "../src/UmbraRouter.sol";
import {IERC20, IUniV3Factory} from "../src/interfaces/Interfaces.sol";

interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams calldata params)
        external
        returns (uint256 amountOut, uint160, uint32, uint256);
}

contract V3HopTest is ForkBase {
    address constant Q_9MM = 0x500260dD7C27eCE20b89ea0808d05a13CF867279;
    address constant Q_LIBERTY = 0xdB368A7f9eDF3EF73e7ceDA97bC67ECF84E39D95;
    address constant PNAS = 0xB709276c0e8d3A5372A13d4fEA886496F396feA1;
    address constant PCOCK = 0xc10A4Ed9b4042222d69ff0B374eddd47ed90fC1F;
    uint8 constant FORK_9MM = 0;
    uint8 constant FORK_PDEX = 3;
    uint8 constant FORK_LIBERTY = 4;

    function _quote(address quoter, address tin, address tout, uint24 fee, uint256 amt) internal returns (uint256) {
        (uint256 out,,,) = IQuoterV2(quoter).quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams(tin, tout, amt, fee, 0)
        );
        return out;
    }

    function test_9mm_v3_wpls_plsx_executes() public {
        // 9mm WPLS/PLSX 2500 is a deep, in-range pool (WPLS/DAI 2500 is empty)
        uint24 fee = 2500;
        address pool = IUniV3Factory(F_9MM_V3).getPool(WPLS, PLSX, fee);
        require(pool != address(0), "no 9mm v3 pool");
        uint256 amt = 500_000e18;

        getWpls(amt);
        IERC20(WPLS).approve(address(router), amt);
        uint256 before = IERC20(PLSX).balanceOf(address(this));
        UmbraRouter.ExecuteParams memory p =
            oneHop(1, WPLS, PLSX, v3Word(pool, fee, FORK_9MM), bytes32(0), amt, 0, 0);
        uint256 out = router.execute(p);

        // mechanism: the V3 swap completed, the callback authenticated + paid, output arrived.
        assertGt(out, 0, "9mm v3 produced output");
        assertEq(IERC20(PLSX).balanceOf(address(this)) - before, out, "received == out");
        assertEq(IERC20(PLSX).balanceOf(address(router)), 0, "no residual out");
        assertEq(IERC20(WPLS).balanceOf(address(router)), 0, "no residual in");
        assertEq(router.v3FactoriesLength(), 5);
    }

    /// LibertySwap V3 uses a custom `libertyV3SwapCallback` selector — this proves the
    /// universal fallback() callback handler routes it correctly (clean tokens).
    function test_liberty_v3_fallback_selector() public {
        _v3CleanSwap(F_LIBERTY_V3, FORK_LIBERTY, 2500);
    }

    /// pDex V3 uses yet another selector — same fallback path.
    function test_pdex_v3_fallback_selector() public {
        _v3CleanSwap(F_PDEX_V3, FORK_PDEX, 2500);
    }

    function _v3CleanSwap(address factory, uint8 forkId, uint24 fee) internal {
        address pool = IUniV3Factory(factory).getPool(WPLS, PLSX, fee);
        require(pool != address(0), "no pool");
        uint256 amt = 200_000e18;
        getWpls(amt);
        IERC20(WPLS).approve(address(router), amt);
        uint256 before = IERC20(PLSX).balanceOf(address(this));
        UmbraRouter.ExecuteParams memory p =
            oneHop(1, WPLS, PLSX, v3Word(pool, fee, forkId), bytes32(0), amt, 0, 0);
        uint256 out = router.execute(p);
        // a positive output proves this fork's callback selector was handled by fallback()
        assertGt(out, 0, "produced output via fallback callback");
        assertEq(IERC20(PLSX).balanceOf(address(this)) - before, out, "received == out");
        assertEq(IERC20(PLSX).balanceOf(address(router)), 0, "no residual out");
        assertEq(IERC20(WPLS).balanceOf(address(router)), 0, "no residual in");
    }

    // ---- adversarial ----

    function test_unsolicited_uniswap_callback_reverts() public {
        vm.expectRevert(UmbraRouter.UnauthCallback.selector);
        router.uniswapV3SwapCallback(1, -1, abi.encode(WPLS));
    }

    function test_unsolicited_pancake_callback_reverts() public {
        vm.expectRevert(UmbraRouter.UnauthCallback.selector);
        router.pancakeV3SwapCallback(1, -1, abi.encode(WPLS));
    }

    function test_fake_v3_pool_reverts() public {
        uint256 amt = 1e18;
        getWpls(amt);
        IERC20(WPLS).approve(address(router), amt);
        // a pool address the factory does NOT vouch for must revert before any pay
        UmbraRouter.ExecuteParams memory p =
            oneHop(1, WPLS, DAI, v3Word(address(0xdEaD), 2500, FORK_9MM), bytes32(0), amt, 0, 0);
        vm.expectRevert(UmbraRouter.BadV3Pool.selector);
        router.execute(p);
    }
}
