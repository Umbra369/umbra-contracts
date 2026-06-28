// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Injected via eth_call `code` state override at a scratch address. Executes a
// V2 multi-hop route and returns the realized output. Fee-on-transfer taxes
// apply exactly once per movement because every amount is *measured*, never
// assumed: each hop sends the held balance to the pool and reads how much the
// pool actually received (post-tax), then swaps the output back to this contract
// and reads how much actually arrived. The caller overrides this contract's
// `tokenIn` balance to `amountIn` before calling.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IPair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

contract Simulator {
    struct Step {
        address pool;
        address tokenIn;
        address tokenOut;
        uint16 feeBps; // pool fee in bps of 10000 (PulseX 29, 9mm 25, others 30)
    }

    function _out(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, uint16 feeBps)
        private
        pure
        returns (uint256)
    {
        uint256 inWithFee = amountIn * (10000 - feeBps);
        return (inWithFee * reserveOut) / (reserveIn * 10000 + inWithFee);
    }

    /// Returns the realized output token amount for the full route.
    function simulate(Step[] calldata steps, uint256 amountIn) external returns (uint256) {
        uint256 n = steps.length;
        require(n > 0, "empty");
        uint256 held = amountIn; // amount of steps[i].tokenIn this contract holds
        for (uint256 i = 0; i < n; i++) {
            address pool = steps[i].pool;
            address tin = steps[i].tokenIn;
            address tout = steps[i].tokenOut;
            (uint112 r0, uint112 r1,) = IPair(pool).getReserves();
            bool inIs0 = (tin == IPair(pool).token0());
            uint256 reserveIn = inIs0 ? uint256(r0) : uint256(r1);
            uint256 reserveOut = inIs0 ? uint256(r1) : uint256(r0);
            // Send what we hold and measure how much the pool actually received
            // (delta of our own transfer -> never underflows; post-tax for FoT).
            uint256 poolBefore = IERC20(tin).balanceOf(pool);
            IERC20(tin).transfer(pool, held);
            uint256 arrived = IERC20(tin).balanceOf(pool) - poolBefore;
            uint256 out = _out(arrived, reserveIn, reserveOut, steps[i].feeBps);
            // Pull the output back to this contract and measure what arrived.
            uint256 selfBefore = IERC20(tout).balanceOf(address(this));
            if (inIs0) {
                IPair(pool).swap(0, out, address(this), "");
            } else {
                IPair(pool).swap(out, 0, address(this), "");
            }
            held = IERC20(tout).balanceOf(address(this)) - selfBefore;
        }
        return held;
    }
}
