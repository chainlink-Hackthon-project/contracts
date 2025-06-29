// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @title InterestModel
/// @notice A utilization‐based interest‐rate model with a kink and reserve factor.
/// @dev All rates and factors are expressed in basis points (BPS), where 10 000 BPS = 100%.
library InterestModel {
    /// @dev Precision for basis points (100% = 10 000 BPS)
    uint256 public constant BPS = 10_000;

    /// @notice Calculates the pool’s utilization rate as borrows / (cash + borrows).
    /// @param cash    Idle liquidity in the pool (token units).
    /// @param borrows Total outstanding borrow balance (principal + accrued interest).
    /// @return utrBps Utilization rate scaled to BPS (0 – 10 000).
    /// @dev Returns 0 if borrows == 0; returns 100% (BPS) if cash == 0 and borrows > 0.
    function utilizationRate(uint256 cash, uint256 borrows)
        internal
        pure
        returns (uint256 utrBps)
    {
        if (borrows == 0) {
            return 0;
        }
        if (cash == 0) {
            // All funds are borrowed → 100% utilization
            return BPS;
        }
        // Standard case: borrows * BPS / (cash + borrows)
        return (borrows * BPS) / (cash + borrows);
    }

    /// @notice Computes the borrow APR (in BPS) given a utilization rate and segmented slope curve.
    /// @param utrBps     Current utilization rate in BPS.
    /// @param baseBps    Base APR in BPS (e.g. 300 = 3.00%).
    /// @param slope1Bps  APR slope (per 1 % U) before the kink, in BPS.
    /// @param slope2Bps  APR slope after the kink, in BPS.
    /// @param kinkBps    Utilization threshold (in BPS) at which the APR slope changes.
    /// @return brBps     Borrow APR in BPS.
    function getBorrowRate(
        uint256 utrBps,
        uint256 baseBps,
        uint256 slope1Bps,
        uint256 slope2Bps,
        uint256 kinkBps
    ) internal pure returns (uint256 brBps) {
        if (utrBps <= kinkBps) {
            // Below or at kink: linear from base
            // br = base + (U * slope1) / BPS
            brBps = baseBps + (utrBps * slope1Bps) / BPS;
        } else {
            // Above kink: full first‐segment + excess * slope2
            uint256 firstSegment = (kinkBps * slope1Bps) / BPS;
            uint256 normalRate   = baseBps + firstSegment;
            uint256 excessUtil   = utrBps - kinkBps;
            uint256 excessRate   = (excessUtil * slope2Bps) / BPS;
            brBps = normalRate + excessRate;
        }
    }

    /// @notice Computes the supply APR (in BPS) that depositors earn.
    /// @param utrBps           Current utilization rate in BPS.
    /// @param borrowRateBps    The borrow APR in BPS (from `getBorrowRate`).
    /// @param reserveFactorBps Protocol reserve factor in BPS (portion of interest kept).
    /// @return srBps           Supply APR in BPS.
    function getSupplyRate(
        uint256 utrBps,
        uint256 borrowRateBps,
        uint256 reserveFactorBps
    ) internal pure returns (uint256 srBps) {
        // Effective borrow rate after reserving protocol fees:
        // effective = borrowRate * (1 - reserveFactor)
        uint256 effectiveBorrow = (borrowRateBps * (BPS - reserveFactorBps)) / BPS;

        // Supply APR = utilization * effective borrow rate / BPS
        srBps = (utrBps * effectiveBorrow) / BPS;
    }
}
