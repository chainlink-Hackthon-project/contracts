// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {Liquidity}       from "./Liquidity.sol";
import {CrossChainLock}  from "./CrossChainLock.sol";
import {OraclePricing}   from "./OraclePricing.sol";

/// @title Borrow & Repay
/// @notice Lets users borrow USDT against an on-chain lock and repay to unlock.
/// @dev Relies on:
///   - CrossChainLock for lock bookkeeping & CCIP messages
///   - OraclePricing for price/LTV
///   - Liquidity   for interest accrual and token transfers
abstract contract BorrowRepay is Liquidity, CrossChainLock, OraclePricing {
    /// @notice Outstanding principal + interest per borrower
    mapping(address => uint256) public debt;
    /// @notice Amount of ETH (in wei) that each borrower locked
    mapping(address => uint256) public collateralWei;

    /// @notice Emitted when a user successfully borrows
    /// @param user      The borrower’s address
    /// @param amount    Amount of USDT drawn
    /// @param rateBps   Borrow APR (basis points) at time of draw
    /// @param timestamp Block timestamp of borrow
    event Borrowed(
        address indexed user,
        uint256 amount,
        uint256 rateBps,
        uint256 timestamp
    );

    /// @notice Emitted when a user repays
    /// @param user   The borrower’s address
    /// @param amount Amount of USDT repaid
    event Repaid(address indexed user, uint256 amount);

    /// @notice Draws USDT against a fully verified lock
    /// @param lockId  The cross-chain lock identifier
    /// @param amount  Amount of USDT to borrow (must not exceed LTV)
    function borrowWithLock(bytes32 lockId, uint256 amount) external {
        // 1) Verify that the lock has been confirmed by CCIP + backend
        require(lockVerified[lockId], "BR: lock not confirmed");
        // Prevent reuse of the same lock
        require(!isTxDone[lockId], "BR: lock already used");
        isTxDone[lockId] = true;

        // 2) Only the original locker may draw against this lock
        LockInfo memory lk = locks[lockId];
        require(lk.user == msg.sender, "BR: not lock owner");

        // 3) Accrue protocol-wide interest before any state changes
        accrueInterest();

        // 4) Compute the borrower’s max draw: USD(collateral) * LTV%
        uint256 collateralUSD6 = collateralUsd(lk.amountWei);
        uint256 allowed       = (collateralUSD6 * currentLTVBps()) / 10_000;
        require(amount > 0 && debt[msg.sender] + amount <= allowed,
                "BR: exceeds LTV");

        // 5) Ensure the pool has enough USDT on hand
        require(usdt.balanceOf(address(this)) >= amount,
                "BR: insufficient liquidity");

        // 6) Update user + protocol state before external call
        uint256 currentApr = borrowAPR();
        debt[msg.sender]             += amount;
        totalBorrows                 += amount;
        collateralWei[msg.sender]     = lk.amountWei;

        // 7) Transfer the USDT out
        usdt.transfer(msg.sender, amount);

        emit Borrowed(msg.sender, amount, currentApr, block.timestamp);
    }

    /// @notice Repays USDT debt; if fully repaid, triggers an unlock
    /// @param amount  Amount of USDT to repay
    function repay(uint256 amount) external {
        // 1) Accrue interest protocol-wide
        accrueInterest();

        // 2) Basic sanity checks
        require(amount > 0,        "BR: zero repay");
        require(debt[msg.sender] >= amount, "BR: nothing to repay");

        // 3) Pull repayment from borrower
        usdt.transferFrom(msg.sender, address(this), amount);

        // 4) Update state
        debt[msg.sender]   -= amount;
        totalBorrows       -= amount;
        emit Repaid(msg.sender, amount);

        // 5) If they’ve cleared their debt, clean up and unlock
        if (debt[msg.sender] == 0) {
            bytes32 lockId = userLocks[msg.sender];

            // Wipe borrower’s collateral record & CCIP flags
            delete collateralWei[msg.sender];
            delete userLocks[msg.sender];
            lockVerified[lockId] = false;

            // Instruct Ethereum vault to release the ETH
            _sendUnlock(lockId, msg.sender);
        }
    }
}
