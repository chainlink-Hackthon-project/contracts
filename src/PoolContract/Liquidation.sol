// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {BorrowRepay} from "./BorrowRepay.sol";
import {OraclePricing} from "./OraclePricing.sol";
import {Client}              from "lib/chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";



abstract contract Liquidation is BorrowRepay {
  uint256 public closeFactorBps      = 5_000;
  uint256 public liquidationBonusBps = 10_500;

  event LiquidationExecuted(
    bytes32 indexed lockId,
    address indexed liquidator,
    uint256 repayAmount,
    uint256 seizedWei
  );

  function liquidate(bytes32 lockId, uint256 repayAmount) external {
    accrueInterest();

    LockInfo storage info = locks[lockId];
    require(info.user != address(0), "LQ: unknown lock");    

    uint256 userDebt   = debt[info.user];
    uint256 collateral = collateralUsd(collateralWei[info.user]);
    uint256 health     = (userDebt * 10_000) / collateral;
    require(health > currentLTVBps(), "LQ: healthy");

    uint256 maxR = (userDebt * closeFactorBps) / 10_000;
    require(repayAmount > 0 && repayAmount <= maxR, "LQ: repay too big");

    usdt.transferFrom(msg.sender, address(this), repayAmount);
    debt[info.user]      = userDebt - repayAmount;
    totalBorrows       -= repayAmount;

    // seize with bonus
    uint256 seizeUsd6 = (repayAmount * liquidationBonusBps) / 10_000;
    ( , int256 p8, , , ) = ethUsd.latestRoundData();
    uint256 seizeWei = (seizeUsd6 * 1e20) / uint256(p8);

    require(collateralWei[info.user] >= seizeWei, "LQ: no collateral");
    collateralWei[info.user] -= seizeWei;

    // send seize instruction
    _sendLiquidate(lockId, info.user, msg.sender, seizeWei);
    emit LiquidationExecuted(lockId, msg.sender, repayAmount, seizeWei);
  }

  function _sendLiquidate(
    bytes32 lockId,
    address borrower,
    address liquidator,
    uint256 amountWei
  ) internal {
    bytes memory data = abi.encode(lockId, liquidator, amountWei);
    Client.EVM2AnyMessage memory ccipMsg = Client.EVM2AnyMessage({
      receiver:     abi.encode(ethVaultReceiver),
      data:         data,
      tokenAmounts: new Client.EVMTokenAmount[](0),
      extraArgs:    Client._argsToBytes(
                       Client.GenericExtraArgsV2({ gasLimit:200_000, allowOutOfOrderExecution: true })
                     ),
      feeToken:     address(0)
    });

    uint256 fee = ccipRouter.getFee(ethChainSelector, ccipMsg);
    require(address(this).balance >= fee, "Pool: insufficient AVAX");
    
    bytes32 msgId = ccipRouter.ccipSend{ value:fee }(ethChainSelector, ccipMsg);
    emit MessageSent(msgId, ethChainSelector, ethVaultReceiver, borrower);
  }
}
