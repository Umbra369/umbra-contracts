// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IAlgFactory { function poolByPair(address, address) external view returns (address); }
interface IAlgPool { function swap(address, bool, int256, uint160, bytes calldata) external returns (int256, int256); }

/// Read-only quoter for SwitchX **V4** (Algebra Integral) pools, matching the engine's
/// IAlgebraQuoter ABI (quoteExactInputSingle -> (amountOut, fee)). SwitchX V4 renamed the
/// swap callback to `v4SwapCallback` (0x6a5ac18f); we implement it to revert with the
/// realized output (the standard quoter swap-and-revert trick). Non-view: it drives a real
/// pool.swap that reverts internally, so it only returns cleanly via eth_call. Never holds
/// funds. The V4 factory is baked in at construction (index == ALGEBRA_DEXES forkId).
contract SwitchXV4Quoter {
    address public immutable factory;
    constructor(address f) { factory = f; }

    function quoteExactInputSingle(address tin, address tout, uint256 amt, uint160)
        external
        returns (uint256 amountOut, uint16 fee)
    {
        address pool = IAlgFactory(factory).poolByPair(tin, tout);
        if (pool == address(0)) return (0, 0);
        bool z = tin < tout;
        uint160 lim = z ? 4295128740 : 1461446703485210103287273052203988822378723970341;
        try IAlgPool(pool).swap(address(this), z, int256(amt), lim, hex"") {}
        catch (bytes memory r) { if (r.length >= 32) amountOut = abi.decode(r, (uint256)); }
        fee = 0;
    }

    function v4SwapCallback(int256 a0, int256 a1, bytes calldata) external pure {
        int256 o = a0 < a1 ? a0 : a1;
        uint256 amountOut = uint256(-o);
        bytes memory d = abi.encode(amountOut);
        assembly { revert(add(d, 32), mload(d)) }
    }
}
