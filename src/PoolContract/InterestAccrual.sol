// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {IERC20}        from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {InterestModel} from "./InterestModel.sol";

/// @title Interest Accrual Module
/// @notice Tracks borrows/reserves and accrues interest on the pool over time.
/// @dev Uses a kinked utilization-based model from InterestModel.
abstract contract InterestAccrual {
  using InterestModel for uint256;

  /// @notice Underlying USDT token this pool operates on
  IERC20 public immutable usdt;

  /// @notice Total principal + accrued interest owed by borrowers
  uint256 public totalBorrows;

  /// @notice Protocol’s accumulated fee reserves
  uint256 public totalReserves;

  /// @notice Last timestamp when `accrueInterest` was successfully called
  uint256 public lastAccrual;

  /// @notice Percentage of interest (in BPS) that the protocol holds back as reserves
  uint256 public reserveFactorBps = 1_000; // 10%

  /// @notice Base APR in BPS (e.g. 300 = 3.00%)
  uint256 public baseBps;

  /// @notice Slope before the kink, in BPS
  uint256 public slope1Bps;

  /// @notice Slope after the kink, in BPS
  uint256 public slope2Bps;

  /// @notice Utilization‐rate kink threshold, in BPS
  uint256 public kinkBps;

  /// @notice Emitted whenever interest is accrued
  event InterestAccrued(
    uint256 interest, 
    uint256 fee, 
    uint256 timestamp
  );

  uint256 private constant SECONDS_PER_YEAR = 365 days;

  /// @param _usdt  Address of the USDT token used by the pool
  constructor(IERC20 _usdt) {
    require(address(_usdt) != address(0), "IA: zero USDT");
    usdt        = _usdt;
    lastAccrual = block.timestamp;

    // initialize the kinked‐rate curve defaults
    baseBps   = 300;   // 3%
    slope1Bps = 1500;  // 15%
    slope2Bps = 3000;  // 30%
    kinkBps   = 8000;  // 80%
  }

  /// @notice Accrues interest since the last call, allocating fees to reserves
  /// @dev If called multiple times in the same block, does nothing.
  function accrueInterest() public {
    uint256 nowTs = block.timestamp;
    uint256 delta = nowTs - lastAccrual;
    if (delta == 0) {
      return;
    }

    // 1) compute utilization (borrows / (cash + borrows))
    uint256 cash = usdt.balanceOf(address(this));
    uint256 utr  = InterestModel.utilizationRate(cash, totalBorrows);

    // 2) compute borrow APR bps
    uint256 aprBps = InterestModel.getBorrowRate(
      utr, baseBps, slope1Bps, slope2Bps, kinkBps
    );

    // 3) interest = totalBorrows * aprBps/10k * (delta / year)
    uint256 interest = (totalBorrows * aprBps * delta)
                     / (InterestModel.BPS * SECONDS_PER_YEAR);

    // 4) fee portion goes to reserves
    uint256 fee      = (interest * reserveFactorBps) / InterestModel.BPS;
    uint256 toBorrow = interest - fee;

    // 5) update state
    totalReserves += fee;
    totalBorrows  += toBorrow;
    lastAccrual    = nowTs;

    emit InterestAccrued(interest, fee, nowTs);
  }

  /// @notice Returns the current borrow APR (in BPS) for new loans
  function borrowAPR() public view returns (uint256) {
    uint256 cash = usdt.balanceOf(address(this));
    uint256 utr  = InterestModel.utilizationRate(cash, totalBorrows);
    return InterestModel.getBorrowRate(
      utr, baseBps, slope1Bps, slope2Bps, kinkBps
    );
  }

  /// @notice Returns the current supply APR (in BPS) earned by depositors
  function supplyAPR() public view returns (uint256) {
    uint256 cash      = usdt.balanceOf(address(this));
    uint256 utr       = InterestModel.utilizationRate(cash, totalBorrows);
    uint256 borrowBps = InterestModel.getBorrowRate(
      utr, baseBps, slope1Bps, slope2Bps, kinkBps
    );
    return InterestModel.getSupplyRate(
      utr, borrowBps, reserveFactorBps
    );
  }
}
