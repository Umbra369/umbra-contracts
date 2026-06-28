// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface IWPLS {
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface IUniV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 ts);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IUniV3Pool {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

interface IUniV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

// Algebra V1.x factory (switch.win / SwitchX). One pool per unordered pair (dynamic
// fee, no fee tiers); the getter is order-independent. The pool's swap ABI/selector is
// identical to Uniswap V3 (0x128acb08), so IUniV3Pool is reused for the swap call.
interface IAlgebraFactory {
    function poolByPair(address tokenA, address tokenB) external view returns (address pool);
}

interface IBalancerVault {
    enum SwapKind {
        GIVEN_IN,
        GIVEN_OUT
    }

    struct SingleSwap {
        bytes32 poolId;
        SwapKind kind;
        address assetIn;
        address assetOut;
        uint256 amount;
        bytes userData;
    }

    struct FundManagement {
        address sender;
        bool fromInternalBalance;
        address payable recipient;
        bool toInternalBalance;
    }

    function swap(SingleSwap calldata singleSwap, FundManagement calldata funds, uint256 limit, uint256 deadline)
        external
        payable
        returns (uint256 amountCalculated);
}

// PulseX StableSwap (Curve-style). The pool pulls coin[i] via transferFrom and
// sends coin[j] to msg.sender.
interface IStableSwap {
    function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy) external payable;
    function get_dy(uint256 i, uint256 j, uint256 dx) external view returns (uint256);
}

// Balancer V3 (Tide) Router — single-token exact-in swap. The Router pulls funds via
// its own Permit2 deployment (NOT the canonical 0x...22), so each router stores its Permit2.
interface IBalancerV3Router {
    function swapSingleTokenExactIn(
        address pool,
        address tokenIn,
        address tokenOut,
        uint256 exactAmountIn,
        uint256 minAmountOut,
        uint256 deadline,
        bool wethIsEth,
        bytes calldata userData
    ) external payable returns (uint256);
}

// Permit2 AllowanceTransfer surface used by the Balancer-V3 Router (approve + read).
interface IPermit2Allowance {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
    function allowance(address user, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}

// Permit2 SignatureTransfer (canonical deployment 0x000000000022D473030F116dDEE9F6B43aC78BA3).
interface IPermit2 {
    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }

    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    function permitTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;
}
