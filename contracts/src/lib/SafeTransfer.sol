// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal safe ERC20/ETH transfer helpers for tokens that either return
/// true or return no data. Reverts on failed calls or false return values.
library SafeTransfer {
    error TransferFailed();
    error TransferFromFailed();
    error ApproveFailed();
    error EthTransferFailed();

    bytes4 private constant TRANSFER_SELECTOR = 0xa9059cbb; // transfer(address,uint256)
    bytes4 private constant TRANSFER_FROM_SELECTOR = 0x23b872dd; // transferFrom(address,address,uint256)
    bytes4 private constant APPROVE_SELECTOR = 0x095ea7b3; // approve(address,uint256)

    function safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(TRANSFER_SELECTOR, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(TRANSFER_FROM_SELECTOR, from, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFromFailed();
    }

    function safeApprove(address token, address spender, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(APPROVE_SELECTOR, spender, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert ApproveFailed();
    }

    function safeTransferETH(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }
}
