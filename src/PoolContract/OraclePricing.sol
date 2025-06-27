// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {AggregatorV3Interface} from "lib/chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

abstract contract OraclePricing {
  AggregatorV3Interface public immutable ethUsd;
  AggregatorV3Interface public immutable ethVol;

  constructor(address _usdFeed, address _volFeed) {
    ethUsd = AggregatorV3Interface(_usdFeed);
    ethVol = AggregatorV3Interface(_volFeed);
  }

  /// @dev 6-dec USDT-style USD value of a user’s wei collateral
  function collateralUsd(uint256 weiAmt) public view returns (uint256) {
    require(weiAmt > 0, "OP: zero collateral");
    ( , int256 p, , uint time, ) = ethUsd.latestRoundData();
    require(p > 0 && block.timestamp - time < 1 hours, "OP: price stale");
    // (wei * price8) / 1e18 → 8 decimals → /1e2 → 6 decimals
    return (weiAmt * uint256(p) / 1e18) / 1e2;
  }

  /// dynamic LTV in BPS, based on vol thresholds
  function currentLTVBps() public view returns (uint256) {
    ( , int256 v, , uint time, ) = ethVol.latestRoundData();
    require(v > 0 && block.timestamp - time < 1 hours, "OP: vol stale");
    uint256 vol = uint256(v);
    uint8 d = ethVol.decimals();
    uint256 t1 = ( 5 * 10**d ) / 100;
    uint256 t2 = (10 * 10**d ) / 100;
    if (vol <= t1) return 8_000;
    else if (vol <= t2) return 6_000;
    else return 5_000;
  }
}
