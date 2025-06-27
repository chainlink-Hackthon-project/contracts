// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {Liquidity} from "./Liquidity.sol";
import {CrossChainLock} from "./CrossChainLock.sol";
import {OraclePricing} from "./OraclePricing.sol";

abstract contract BorrowRepay is Liquidity, CrossChainLock, OraclePricing {
  mapping(address => uint256) public debt;
  mapping(address => uint256) public collateralWei;

  event Borrowed(address indexed user, uint256 amount, uint256 rateBps, uint256 timestamp);
  event Repaid(address indexed user,   uint256 amount);

  function borrowWithLock(bytes32 lockId, uint256 amount) external {
    require(lockVerified[lockId], "BR: lock not verified");
    require(!isTxDone[lockId], "BR: already used");
    isTxDone[lockId] = true;

    LockInfo memory info = locks[lockId];
    require(info.user == msg.sender, "BR: wrong owner");

    accrueInterest(); // from InterestAccrual
    // max borrow = collateralUsd * currentLTVBps / 10_000
    uint256 maxB = (collateralUsd(info.amountWei) *  currentLTVBps()) / 10_000;
    require(amount > 0 && debt[msg.sender] + amount <= maxB, "BR: exceeds LTV");
    require(usdt.balanceOf(address(this)) >= amount,     "BR: no liquidity");

    uint256 rateNow = borrowAPR();
    debt[msg.sender] += amount;
    totalBorrows     += amount;
    collateralWei[msg.sender] = info.amountWei;

    usdt.transfer(msg.sender, amount);
    emit Borrowed(msg.sender, amount, rateNow, block.timestamp);
  }

  function repay(uint256 amount) external {
    accrueInterest();
    require(amount > 0 && debt[msg.sender] >= amount, "BR: overpay");

    usdt.transferFrom(msg.sender, address(this), amount);

    debt[msg.sender]   -= amount;
    totalBorrows       -= amount;
    emit Repaid(msg.sender, amount);

    if (debt[msg.sender] == 0) {
      bytes32 lockId = userLocks[msg.sender];

      delete collateralWei[msg.sender];
      delete userLocks[msg.sender];
      lockVerified[lockId] = false;
      _sendUnlock(lockId, msg.sender);
    }
  }
}
