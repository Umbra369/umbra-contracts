// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ForkBase} from "./UmbraRouter.t.sol";
import {UmbraRouter} from "../src/UmbraRouter.sol";
import {IERC20, IUniV3Factory} from "../src/interfaces/Interfaces.sol";

interface IFac2 {
    function getPair(address a, address b) external view returns (address);
}

contract ExecuteTest is ForkBase {
    uint8 constant FORK_9MM = 0;

    function _v2pair(address a, address b) internal view returns (address) {
        return IFac2(PULSEX_V2_FACTORY).getPair(a, b);
    }

    function _v3pool(address a, address b, uint24 fee) internal view returns (address) {
        return IUniV3Factory(F_9MM_V3).getPool(a, b, fee);
    }

    // ---- multi-hop, distinct endpoints: DAI -> WPLS (PulseX V2) -> PLSX (9mm V3) ----
    function test_multihop_v2_then_v3() public {
        address pairDW = _v2pair(DAI, WPLS);
        address poolWP = _v3pool(WPLS, PLSX, 2500);
        require(pairDW != address(0) && poolWP != address(0), "missing pools");
        uint256 amt = 50_000e18; // 50k DAI
        deal(DAI, address(this), amt);
        IERC20(DAI).approve(address(router), amt);

        UmbraRouter.Hop[] memory hops = new UmbraRouter.Hop[](2);
        hops[0] = UmbraRouter.Hop(0, DAI, WPLS, v2Word(pairDW, 997100), bytes32(0));
        hops[1] = UmbraRouter.Hop(1, WPLS, PLSX, v3Word(poolWP, 2500, FORK_9MM), bytes32(0));
        UmbraRouter.Path[] memory paths = new UmbraRouter.Path[](1);
        paths[0] = UmbraRouter.Path(10_000, hops);
        UmbraRouter.ExecuteParams memory p =
            UmbraRouter.ExecuteParams(DAI, PLSX, amt, 0, address(this), block.timestamp + 600, 0, paths, "");

        uint256 before = IERC20(PLSX).balanceOf(address(this));
        uint256 out = router.execute(p);
        assertGt(out, 0, "multi-hop produced output");
        assertEq(IERC20(PLSX).balanceOf(address(this)) - before, out, "received");
        assertEq(IERC20(WPLS).balanceOf(address(router)), 0, "no intermediate residual");
        assertEq(IERC20(PLSX).balanceOf(address(router)), 0, "no residual");
        assertEq(IERC20(DAI).balanceOf(address(router)), 0, "no input residual");
    }

    // ---- split: WPLS -> PLSX, 50% PulseX V2 + 50% 9mm V3, accumulated + swept once ----
    function test_split_v2_and_v3() public {
        address pool = _v3pool(WPLS, PLSX, 2500);
        address pair = _v2pair(WPLS, PLSX);
        require(pool != address(0) && pair != address(0), "missing pools");
        uint256 amt = 300_000e18;
        getWpls(amt);
        IERC20(WPLS).approve(address(router), amt);

        UmbraRouter.Path[] memory paths = new UmbraRouter.Path[](2);
        UmbraRouter.Hop[] memory h0 = new UmbraRouter.Hop[](1);
        h0[0] = UmbraRouter.Hop(0, WPLS, PLSX, v2Word(pair, 997100), bytes32(0));
        paths[0] = UmbraRouter.Path(5_000, h0);
        UmbraRouter.Hop[] memory h1 = new UmbraRouter.Hop[](1);
        h1[0] = UmbraRouter.Hop(1, WPLS, PLSX, v3Word(pool, 2500, FORK_9MM), bytes32(0));
        paths[1] = UmbraRouter.Path(5_000, h1);
        UmbraRouter.ExecuteParams memory p =
            UmbraRouter.ExecuteParams(WPLS, PLSX, amt, 0, address(this), block.timestamp + 600, 0, paths, "");

        uint256 before = IERC20(PLSX).balanceOf(address(this));
        uint256 out = router.execute(p);
        assertGt(out, 0, "split produced output");
        assertEq(IERC20(PLSX).balanceOf(address(this)) - before, out, "received == summed split");
        assertEq(IERC20(WPLS).balanceOf(address(router)), 0, "no input residual");
        assertEq(IERC20(PLSX).balanceOf(address(router)), 0, "no output residual");
    }

    function test_split_bad_bps_reverts() public {
        address pair = _v2pair(WPLS, PLSX);
        uint256 amt = 1_000e18;
        getWpls(amt);
        IERC20(WPLS).approve(address(router), amt);
        UmbraRouter.Path[] memory paths = new UmbraRouter.Path[](2);
        UmbraRouter.Hop[] memory h0 = new UmbraRouter.Hop[](1);
        h0[0] = UmbraRouter.Hop(0, WPLS, PLSX, v2Word(pair, 997100), bytes32(0));
        paths[0] = UmbraRouter.Path(6_000, h0); // 6000 + 6000 != 10000
        UmbraRouter.Hop[] memory h1 = new UmbraRouter.Hop[](1);
        h1[0] = UmbraRouter.Hop(0, WPLS, PLSX, v2Word(pair, 997100), bytes32(0));
        paths[1] = UmbraRouter.Path(6_000, h1);
        UmbraRouter.ExecuteParams memory p =
            UmbraRouter.ExecuteParams(WPLS, PLSX, amt, 0, address(this), block.timestamp + 600, 0, paths, "");
        vm.expectRevert(UmbraRouter.BadBps.selector);
        router.execute(p);
    }

    // ---- native PLS in: PLS -> PLSX (router wraps) ----
    function test_native_in() public {
        address pair = _v2pair(WPLS, PLSX);
        uint256 amt = 100_000e18;
        vm.deal(address(this), amt);
        uint256 before = IERC20(PLSX).balanceOf(address(this));
        // flags = INPUT_IS_NATIVE (2); hop operates on WPLS
        UmbraRouter.ExecuteParams memory p =
            oneHop(0, WPLS, PLSX, v2Word(pair, 997100), bytes32(0), amt, 0, 2);
        uint256 out = router.execute{value: amt}(p);
        assertGt(out, 0, "native-in produced output");
        assertEq(IERC20(PLSX).balanceOf(address(this)) - before, out, "received");
        assertEq(IERC20(WPLS).balanceOf(address(router)), 0, "no wrapped residual");
    }

    // ---- native PLS out: DAI -> WPLS (router unwraps to PLS) ----
    function test_native_out() public {
        address pair = _v2pair(DAI, WPLS);
        uint256 amt = 50_000e18;
        deal(DAI, address(this), amt);
        IERC20(DAI).approve(address(router), amt);
        uint256 before = address(this).balance;
        // flags = OUTPUT_IS_NATIVE (4); hop outputs WPLS, router unwraps to PLS
        UmbraRouter.ExecuteParams memory p =
            oneHop(0, DAI, WPLS, v2Word(pair, 997100), bytes32(0), amt, 0, 4);
        uint256 out = router.execute(p);
        assertGt(out, 0, "native-out produced output");
        assertEq(address(this).balance - before, out, "received native PLS");
        assertEq(IERC20(WPLS).balanceOf(address(router)), 0, "no residual WPLS");
    }

    function test_deadline_revert() public {
        address pair = _v2pair(WPLS, PLSX);
        uint256 amt = 1_000e18;
        getWpls(amt);
        IERC20(WPLS).approve(address(router), amt);
        UmbraRouter.ExecuteParams memory p =
            oneHop(0, WPLS, PLSX, v2Word(pair, 997100), bytes32(0), amt, 0, 0);
        p.deadline = block.timestamp - 1; // expired
        vm.expectRevert(UmbraRouter.Expired.selector);
        router.execute(p);
    }
}
