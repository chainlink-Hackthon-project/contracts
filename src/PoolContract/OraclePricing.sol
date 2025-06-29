// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {AggregatorV3Interface}
  from "lib/chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @title  Oracle‐based Pricing Module
/// @notice Fetches ETH/USD price and ETH volatility from Chainlink and computes:
///         1) collateralUsd: user’s ETH (wei) → USDT‐style USD (6 decimals)  
///         2) currentLTVBps: allowed LTV (in BPS) based on volatility thresholds
abstract contract OraclePricing {
    /// -----------------------------------------------------------------------
    /// State
    /// -----------------------------------------------------------------------
    /// @notice Chainlink ETH/USD price feed (8 decimals)
    AggregatorV3Interface public immutable ethUsd;
    /// @notice Chainlink ETH volatility feed (decimals vary)
    AggregatorV3Interface public immutable ethVol;

    /// -----------------------------------------------------------------------
    /// Constructor
    /// -----------------------------------------------------------------------
    /// @param _usdFeed  Address of Chainlink ETH/USD aggregator
    /// @param _volFeed  Address of Chainlink ETH volatility aggregator
    constructor(address _usdFeed, address _volFeed) {
        require(_usdFeed != address(0), "OP: zero price feed");
        require(_volFeed != address(0), "OP: zero vol feed");
        ethUsd = AggregatorV3Interface(_usdFeed);
        ethVol = AggregatorV3Interface(_volFeed);
    }

    /// -----------------------------------------------------------------------
    /// Collateral Valuation
    /// -----------------------------------------------------------------------
    /// @notice Converts a wei amount of ETH collateral → USD with 6 decimals
    /// @param weiAmt  Amount of ETH in wei
    /// @return usd6   USD value scaled to 6 decimals (like USDT)
    /// @dev  Uses Chainlink ETH/USD (8 decimals):  
    ///      usd8 = (weiAmt * price8) / 1e18  
    ///      usd6 = usd8 / 1e2
    function collateralUsd(uint256 weiAmt) public view returns (uint256 usd6) {
        require(weiAmt > 0, "OP: zero collateral");

        // 1) fetch latest price
        ( , int256 price8, , uint256 updatedAt, ) = ethUsd.latestRoundData();
        require(price8 > 0,        "OP: bad price");
        require(block.timestamp - updatedAt < 1 hours, "OP: stale price");

        // 2) compute USD value:
        //    (weiAmt * price8) has 18 + 8 decimals → divide by 1e18 → 8 decimals
        uint256 usd8 = (weiAmt * uint256(price8)) / 1e18;
        //    scale 8 → 6 decimals
        return usd8 / 1e2;
    }

    /// -----------------------------------------------------------------------
    /// Dynamic LTV Based on Volatility
    /// -----------------------------------------------------------------------
    /// @notice Returns current LTV ceiling (in BPS) depending on ETH volatility:
    ///         ≤5% → 80%; ≤10% → 60%; else → 50%
    /// @return ltvBps  LTV limit, in basis points (e.g. 8_000 = 80%)
    function currentLTVBps() public view returns (uint256 ltvBps) {
        // 1) fetch vol reading
        ( , int256 volRaw, , uint256 updatedAt, ) = ethVol.latestRoundData();
        require(volRaw > 0,        "OP: bad vol");
        require(block.timestamp - updatedAt < 1 hours, "OP: stale vol");

        // 2) normalize and compare thresholds
        uint256 vol     = uint256(volRaw);
        uint8   decimals = ethVol.decimals();
        // 5%  = 5 * 10^decimals / 100
        uint256 thresh1 = (5  * 10**decimals) / 100;
        // 10% = 10 * 10^decimals / 100
        uint256 thresh2 = (10 * 10**decimals) / 100;

        if (vol <= thresh1)      return 8_000;  // ≤5% vol → 80% LTV
        else if (vol <= thresh2) return 6_000;  // 5–10% vol → 60% LTV
        else                     return 5_000;  // >10% vol → 50% LTV
    }
}
