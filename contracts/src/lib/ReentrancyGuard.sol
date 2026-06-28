// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal nonReentrant guard.
abstract contract ReentrancyGuard {
    error ReentrantCall();

    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    uint256 private _status = NOT_ENTERED;

    modifier nonReentrant() {
        if (_status == ENTERED) revert ReentrantCall();
        _status = ENTERED;
        _;
        _status = NOT_ENTERED;
    }
}
