// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {IERC20}          from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {InterestModel}   from "./InterestModel.sol";

abstract contract InterestAccrual {
  using InterestModel for uint256;

  IERC20 public immutable  usdt;
  uint256 public totalBorrows;
  uint256 public totalReserves;
  uint256 public lastAccrual;
  uint256 public reserveFactorBps = 1_000;

  // curve parameters
  uint256 public baseBps;
  uint256 public slope1Bps;
  uint256 public slope2Bps;
  uint256 public kinkBps;

  event InterestAccrued(uint256 interest, uint256 fee, uint256 timestamp);

  constructor(IERC20 _usdt) {
    usdt        = _usdt;
    lastAccrual = block.timestamp;
    // you can set defaults here or via a setter
    baseBps   = 300; 
    slope1Bps = 1500;
    slope2Bps = 3000;
    kinkBps   = 8000;
  }

  function accrueInterest() public {
    uint delta = block.timestamp - lastAccrual;
    if (delta == 0) return;

    uint cash = usdt.balanceOf(address(this));
    uint utr  = InterestModel.utilizationRate(cash, totalBorrows);
    uint apr  = InterestModel.getBorrowRate(utr, baseBps, slope1Bps, slope2Bps, kinkBps);

    uint interest = (totalBorrows * apr * delta) / (InterestModel.BPS * 365 days);

    uint fee = (interest * reserveFactorBps) / InterestModel.BPS;
    
    totalReserves += fee;
    totalBorrows  += (interest - fee);
    lastAccrual    = block.timestamp;
    emit InterestAccrued(interest, fee, block.timestamp);
  }

  function borrowAPR() public view returns (uint256) {
    uint cash = usdt.balanceOf(address(this));
    uint utr  = InterestModel.utilizationRate(cash, totalBorrows);
    return InterestModel.getBorrowRate(utr, baseBps, slope1Bps, slope2Bps, kinkBps);
  }

  function supplyAPR() public view returns (uint256) {
    uint cash = usdt.balanceOf(address(this));
    uint utr  = InterestModel.utilizationRate(cash, totalBorrows);
    uint borrowBps = InterestModel.getBorrowRate(utr, baseBps, slope1Bps, slope2Bps, kinkBps);
    return InterestModel.getSupplyRate(utr, borrowBps, reserveFactorBps);
  }
}
