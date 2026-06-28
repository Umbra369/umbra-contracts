// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {UmbraRouter} from "../src/UmbraRouter.sol";
import {IERC20, IWPLS, IUniV3Factory} from "../src/interfaces/Interfaces.sol";

interface IFactoryV2 {
    function getPair(address a, address b) external view returns (address);
}

interface IRouterV2 {
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory);
}

/// Base: forks the live PulseChain node and deploys UmbraRouter with the real factories.
contract ForkBase is Test {
    UmbraRouter internal router;

    address constant WPLS = 0xA1077a294dDE1B09bB078844df40758a5D0f9a27;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F; // pDAI
    address constant PLSX = 0x95B303987A60C71504D99Aa1b13B4DA07b0790ab;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant PHUX_VAULT = 0x7F51AC3df6A034273FB09BB29e383FCF655e473c;
    address constant PULSEX_STABLE_3POOL = 0xE3acFA6C40d53C3faf2aa62D0a715C737071511c; // USDT/USDC/DAI
    address constant USDT = 0x0Cb6F5a34ad42ec934882A05265A7d5F59b51A2f;
    address constant USDC = 0x15D38573d2feeb82e7ad5187aB8c1D52810B1f07;

    address constant PULSEX_V2_FACTORY = 0x29eA7545DEf87022BAdc76323F373EA1e707C523;
    address constant PULSEX_V2_ROUTER = 0x165C3410fC91EF562C50559f7d2289fEbed552d9;
    address constant NINEMM_V2_FACTORY = 0x3a0Fa7884dD93f3cd234bBE2A0958Ef04b05E13b;
    address constant NINEMM_V2_ROUTER = 0xcC73b59F8D7b7c532703bDfea2808a28a488cF47;

    // forkId order must match the deployed v3Factories array
    address constant F_9MM_V3 = 0xe50DbDC88E87a2C92984d794bcF3D1d76f619C68;
    address constant F_9INCH_V3 = 0xCfd33C867C9F031AadfF7939Cb8086Ee5ae88c41;
    address constant F_UNI_V3 = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant F_PDEX_V3 = 0x271Fd3BDBD6e56c16c8b32b9a72D635191c9ECcf;
    address constant F_LIBERTY_V3 = 0x796fcbDC956b85797EFe21145Aa97599B7FB36a6;

    function setUp() public virtual {
        vm.createSelectFork("pulse");
        address[] memory facs = new address[](5);
        facs[0] = F_9MM_V3;
        facs[1] = F_9INCH_V3;
        facs[2] = F_UNI_V3;
        facs[3] = F_PDEX_V3;
        facs[4] = F_LIBERTY_V3;
        address[] memory vaults = new address[](1);
        vaults[0] = PHUX_VAULT;
        address[] memory stablePools = new address[](1);
        stablePools[0] = PULSEX_STABLE_3POOL;
        router = new UmbraRouter(WPLS, PERMIT2, facs, vaults, stablePools);
    }

    receive() external payable {}

    // ---- packed pool word helpers ----
    function v2Word(address pair, uint256 feeNum) internal pure returns (uint256) {
        return uint256(uint160(pair)) | (feeNum << 160);
    }

    function v3Word(address pool, uint24 fee, uint8 forkId) internal pure returns (uint256) {
        return uint256(uint160(pool)) | (uint256(fee) << 160) | (uint256(forkId) << 184);
    }

    function balWord(address vault) internal pure returns (uint256) {
        return uint256(uint160(vault));
    }

    function stableWord(address pool, uint8 i, uint8 j) internal pure returns (uint256) {
        return uint256(uint160(pool)) | (uint256(i) << 160) | (uint256(j) << 168);
    }

    // ---- single-hop ExecuteParams builder ----
    function oneHop(uint8 pt, address tin, address tout, uint256 poolWord, bytes32 poolData, uint256 amountIn, uint256 minOut, uint8 flags)
        internal
        view
        returns (UmbraRouter.ExecuteParams memory p)
    {
        UmbraRouter.Hop[] memory hops = new UmbraRouter.Hop[](1);
        hops[0] = UmbraRouter.Hop({poolType: pt, tokenIn: tin, tokenOut: tout, pool: poolWord, poolData: poolData});
        UmbraRouter.Path[] memory paths = new UmbraRouter.Path[](1);
        paths[0] = UmbraRouter.Path({inputBps: 10_000, hops: hops});
        p = UmbraRouter.ExecuteParams({
            tokenIn: (flags & 2 != 0) ? address(0) : tin,
            tokenOut: (flags & 4 != 0) ? address(0) : tout,
            amountIn: amountIn,
            minAmountOut: minOut,
            recipient: address(this),
            deadline: block.timestamp + 600,
            flags: flags,
            paths: paths,
            permit2: ""
        });
    }

    function getWpls(uint256 amount) internal {
        vm.deal(address(this), amount);
        IWPLS(WPLS).deposit{value: amount}();
    }
}

contract V2HopTest is ForkBase {
    function _expectedV2(address rtr, address tin, address tout, uint256 amt) internal view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = tin;
        path[1] = tout;
        return IRouterV2(rtr).getAmountsOut(amt, path)[1];
    }

    function test_pulsex_v2_wpls_to_dai_exact() public {
        address pair = IFactoryV2(PULSEX_V2_FACTORY).getPair(WPLS, DAI);
        require(pair != address(0), "no pair");
        uint256 amt = 1_000_000e18; // 1M WPLS
        uint256 expected = _expectedV2(PULSEX_V2_ROUTER, WPLS, DAI, amt);

        getWpls(amt);
        IERC20(WPLS).approve(address(router), amt);
        uint256 before = IERC20(DAI).balanceOf(address(this));

        // PulseX V2 = 29 bps => kept fraction 9971/10000 => 6-digit numerator 997100
        UmbraRouter.ExecuteParams memory p =
            oneHop(0, WPLS, DAI, v2Word(pair, 997100), bytes32(0), amt, expected, 0);
        uint256 out = router.execute(p);

        assertEq(out, expected, "out must equal router getAmountsOut exactly");
        assertEq(IERC20(DAI).balanceOf(address(this)) - before, expected, "received");
        assertEq(IERC20(WPLS).balanceOf(address(router)), 0, "no residual WPLS");
        assertEq(IERC20(DAI).balanceOf(address(router)), 0, "no residual DAI");
    }

    function test_pulsex_v2_dai_to_wpls_reverse() public {
        address pair = IFactoryV2(PULSEX_V2_FACTORY).getPair(WPLS, DAI);
        uint256 amt = 50_000e18; // 50k DAI
        uint256 expected = _expectedV2(PULSEX_V2_ROUTER, DAI, WPLS, amt);

        deal(DAI, address(this), amt);
        IERC20(DAI).approve(address(router), amt);
        uint256 before = IERC20(WPLS).balanceOf(address(this));

        UmbraRouter.ExecuteParams memory p =
            oneHop(0, DAI, WPLS, v2Word(pair, 997100), bytes32(0), amt, expected, 0);
        uint256 out = router.execute(p);
        assertEq(out, expected, "reverse exact");
        assertEq(IERC20(WPLS).balanceOf(address(this)) - before, expected, "received");
    }

    function test_9mm_v2_fee_25bps_exact() public {
        address pair = IFactoryV2(NINEMM_V2_FACTORY).getPair(WPLS, DAI);
        if (pair == address(0)) return; // pair may not exist on the fork; skip cleanly
        uint256 amt = 100_000e18;
        uint256 expected = _expectedV2(NINEMM_V2_ROUTER, WPLS, DAI, amt);

        getWpls(amt);
        IERC20(WPLS).approve(address(router), amt);
        // 9mm V2 = 25 bps => 9975/10000 => 997500
        UmbraRouter.ExecuteParams memory p =
            oneHop(0, WPLS, DAI, v2Word(pair, 997500), bytes32(0), amt, expected, 0);
        uint256 out = router.execute(p);
        assertEq(out, expected, "9mm 25bps exact");
    }

    function test_minOut_revert() public {
        address pair = IFactoryV2(PULSEX_V2_FACTORY).getPair(WPLS, DAI);
        uint256 amt = 1_000e18;
        uint256 expected = _expectedV2(PULSEX_V2_ROUTER, WPLS, DAI, amt);
        getWpls(amt);
        IERC20(WPLS).approve(address(router), amt);
        // demand 2x the real output -> must revert
        UmbraRouter.ExecuteParams memory p =
            oneHop(0, WPLS, DAI, v2Word(pair, 997100), bytes32(0), amt, expected * 2, 0);
        vm.expectRevert(UmbraRouter.InsufficientOutput.selector);
        router.execute(p);
    }
}
