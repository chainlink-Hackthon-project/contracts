// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {BorrowRepay}       from "./BorrowRepay.sol";
import {OraclePricing}     from "./OraclePricing.sol";
import {Client}            from "lib/chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";

/// @title  Liquidation Module
/// @notice Allows under‐collateralized positions to be liquidated
/// @dev    Relies on `BorrowRepay` for debt tracking and on `OraclePricing` for USD pricing.
abstract contract Liquidation is BorrowRepay, OraclePricing {
    /// @notice Maximum portion of debt that can be repaid in a single liquidation (in BPS)
    uint256 public closeFactorBps      = 5_000;  // 50%

    /// @notice Bonus applied to the liquidator’s seized collateral (in BPS)
    uint256 public liquidationBonusBps = 10_500; // 105%

    /// @notice Emitted after a successful on-chain liquidation
    /// @param lockId       The cross-chain lock identifier
    /// @param liquidator  Address performing the liquidation
    /// @param repayAmount Amount of USDT repaid by the liquidator
    /// @param seizedWei   Amount of ETH (in wei) seized plus bonus
    event LiquidationExecuted(
        bytes32 indexed lockId,
        address indexed liquidator,
        uint256 repayAmount,
        uint256 seizedWei
    );

    /// @notice Liquidate an under-collateralized loan
    /// @param lockId       Identifier of the borrower’s cross-chain lock
    /// @param repayAmount  Amount of USDT the liquidator will repay (≤ closeFactorBps% of debt)
    function liquidate(bytes32 lockId, uint256 repayAmount) external {
        // 1) accrue the latest interest
        accrueInterest();

        // 2) load the borrower’s position
        LockInfo storage info = locks[lockId];
        require(info.user != address(0), "LQ: unknown lock");

        // 3) compute health = (debt / collateralValue) * 10_000
        uint256 userDebt      = debt[info.user];
        uint256 collateralUsd = collateralUsd(collateralWei[info.user]);
        uint256 healthBps     = (userDebt * 10_000) / collateralUsd;
        require(healthBps > currentLTVBps(), "LQ: healthy");

        // 4) enforce the close‐factor cap
        uint256 maxRepay = (userDebt * closeFactorBps) / 10_000;
        require(repayAmount > 0 && repayAmount <= maxRepay, "LQ: repay too big");

        // 5) pull USDT from liquidator and reduce debt
        usdt.transferFrom(msg.sender, address(this), repayAmount);
        debt[info.user]    = userDebt - repayAmount;
        totalBorrows      -= repayAmount;

        // 6) calculate ETH to seize (with bonus)
        uint256 usdToSeize6 = (repayAmount * liquidationBonusBps) / 10_000;
        (, int256 price8, , , ) = ethUsd.latestRoundData();
        require(price8 > 0, "LQ: bad price");
        uint256 seizeWei = (usdToSeize6 * 1e20) / uint256(price8);

        require(collateralWei[info.user] >= seizeWei, "LQ: no collateral");
        collateralWei[info.user] -= seizeWei;

        // 7) notify Ethereum-side vault to transfer ETH to liquidator
        _sendLiquidationMessage(lockId, info.user, msg.sender, seizeWei);

        emit LiquidationExecuted(lockId, msg.sender, repayAmount, seizeWei);
    }

    /// @dev internal helper to send a CCIP “liquidate” message back to Ethereum
    function _sendLiquidationMessage(
        bytes32 lockId,
        address borrower,
        address liquidator,
        uint256 amountWei
    ) internal {
        bytes memory payload = abi.encode(lockId, liquidator, amountWei);

        Client.EVM2AnyMessage memory ccipMsg = Client.EVM2AnyMessage({
            receiver:     abi.encode(ethVaultReceiver),
            data:         payload,
            tokenAmounts: new Client.EVMTokenAmount,
            extraArgs:    Client._argsToBytes(
                               Client.GenericExtraArgsV2({
                                   gasLimit:                 500_000,
                                   allowOutOfOrderExecution: true
                               })
                           ),
            feeToken:     address(0)
        });

        uint256 fee = ccipRouter.getFee(ethChainSelector, ccipMsg);
        require(address(this).balance >= fee, "LQ: insufficient AVAX");

        bytes32 msgId = ccipRouter.ccipSend{ value: fee }(
            ethChainSelector,
            ccipMsg
        );
        emit MessageSent(msgId, ethChainSelector, ethVaultReceiver, borrower);
    }
}
