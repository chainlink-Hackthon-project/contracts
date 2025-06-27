// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @title InterestModel
/// @notice A utilization‐based interest‐rate model with a kink and reserve factor.
/// @dev All rates and factors are expressed in basis points (BPS), where 10 000 BPS = 100%.
library InterestModel {
    /// @dev BPS precision (100% = 10 000 BPS)
    uint256 public constant BPS = 10_000;

    /// @notice Calculates the pool’s utilization rate as (borrows / (cash + borrows)).
    /// @param cash    The amount of asset token sitting idle in the pool.
    /// @param borrows The total amount the pool has lent out (principal + accrued interest).
    /// @return utrBps The utilization rate, scaled to BPS (0 – 10 000).
    function utilizationRate(uint256 cash, uint256 borrows)
        internal
        pure
        returns (uint256 utrBps)
    {
        // If nobody’s borrowed or there’s no cash, utilization is zero.
        if (borrows == 0) return 0;
        if (cash ==0 && borrows > 0) return BPS;
        // utrBps = borrows * BPS / (cash + borrows)
        utrBps = (borrows * BPS) / (cash + borrows);
    }

    /// @notice Computes the borrow APR (in BPS) given a utilization rate and curve parameters.
    /// @param utrBps     Current utilization rate in BPS.
    /// @param baseBps    The base APR in BPS (e.g. 300 = 3.00%).
    /// @param slope1Bps  The slope (APR increase per 1 % U) before the kink, in BPS.
    /// @param slope2Bps  The slope after the kink, in BPS (for “rush‐hour” pricing).
    /// @param kinkBps    The utilization threshold (in BPS) at which the slope jumps.
    /// @return brBps     The borrow APR, in BPS.
    function getBorrowRate(
        uint256 utrBps,
        uint256 baseBps,
        uint256 slope1Bps,
        uint256 slope2Bps,
        uint256 kinkBps
    ) internal pure returns (uint256 brBps) {
        if (utrBps <= kinkBps) {
            // Below or at the kink: linear increase
            // br = base + (U * slope1) / BPS
            brBps = baseBps + (utrBps * slope1Bps) / BPS;
        } else {
            // Above the kink: base + full first‐segment + excess at slope2
            uint256 normalRate = baseBps + (kinkBps * slope1Bps) / BPS;
            uint256 excessUtil  = utrBps - kinkBps;
            uint256 excessRate  = (excessUtil * slope2Bps) / BPS;
            brBps = normalRate + excessRate;
        }
    }

    /// @notice Computes the supply APR (in BPS) that depositors earn.
    /// @param utrBps           Current utilization rate in BPS.
    /// @param borrowRateBps    The borrow APR in BPS (from `getBorrowRate`).
    /// @param reserveFactorBps The protocol’s reserve factor in BPS (e.g. 1000 = 10%).
    /// @return srBps           The supply APR, in BPS.
    function getSupplyRate(
        uint256 utrBps,
        uint256 borrowRateBps,
        uint256 reserveFactorBps
    ) internal pure returns (uint256 srBps) {
        // effectiveBorrowRate = borrowRate * (1 - reserveFactor)
        uint256 effectiveBorrow = (borrowRateBps * (BPS - reserveFactorBps)) / BPS;
        // supplyRate = U * effectiveBorrow / BPS
        srBps = (utrBps * effectiveBorrow) / BPS;
    }
}
