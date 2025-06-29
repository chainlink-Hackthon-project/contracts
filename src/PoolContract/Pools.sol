// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {IERC20}              from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CrossChainLock}      from "./CrossChainLock.sol";
import {OraclePricing}       from "./OraclePricing.sol";
import {Liquidity}           from "./Liquidity.sol";
import {Liquidation}         from "./Liquidation.sol";

/// @title  Cross-Chain Lending Pool
/// @notice Combines:
///         1) Cross-chain ETH collateral lock/verify (_CrossChainLock_)  
///         2) ETH collateral pricing & dynamic LTV (_OraclePricing_)  
///         3) USDT deposits/LP-shares & interest accrual (_Liquidity_)  
///         4) Borrow/repay + auto-unlock via CCIP (_BorrowRepay_)  
///         5) On-chain liquidation & CCIP seize messages (_Liquidation_)
///
/// @dev `Liquidation` already pulls in `BorrowRepay`, which in turn inherits
///      `Liquidity`, `CrossChainLock` and `OraclePricing`.  This root constructor
///      just needs to initialize each base.
contract Pool is Liquidation {
    /// -----------------------------------------------------------------------
    /// Constructor
    /// -----------------------------------------------------------------------
    /// @param _usdt               USDT token address on Avalanche (ERC-20)
    /// @param _ethUsdFeed         Chainlink ETH/USD price feed
    /// @param _volFeed            Chainlink ETH volatility feed
    /// @param _router             CCIP router on Avalanche (for cross-chain)
    /// @param _ethChainSelector   CCIP chain ID selector for Ethereum
    /// @param _ethVaultReceiver   Address of the EthVault on Ethereum
    constructor(
        address _usdt,
        address _ethUsdFeed,
        address _volFeed,
        address _router,
        uint64  _ethChainSelector,
        address _ethVaultReceiver
    )
        // initialize the cross-chain‐lock module
        CrossChainLock(
            _router,
            _ethChainSelector,
            _ethVaultReceiver
        )
        // initialize pricing (feeds)
        OraclePricing(
            _ethUsdFeed,
            _volFeed
        )
        // initialize liquidity / interest-accrual (USDT ERC-20)
        Liquidity(
            IERC20(_usdt)
        )
    {
        // nothing else to do here – all state is set up by parent constructors
    }
}
