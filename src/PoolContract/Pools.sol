// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {CrossChainLock}    from "./CrossChainLock.sol";
import {OraclePricing}     from "./OraclePricing.sol";
import {Liquidity}         from "./Liquidity.sol";
import {Liquidation}       from "./Liquidation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";


contract Pool is Liquidation {
  constructor(
    address _usdt,
    address _ethUsdFeed,
    address _volFeed,
    address _router,
    uint64  _ethChainSelector,
    address _ethVaultReceiver
  )
    CrossChainLock(_router, _ethChainSelector, _ethVaultReceiver)
    OraclePricing(_ethUsdFeed, _volFeed)
    Liquidity(IERC20(_usdt))
  {}
}
