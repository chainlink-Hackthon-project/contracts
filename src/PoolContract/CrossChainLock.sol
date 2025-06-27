// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {Ownable}             from "@openzeppelin/contracts/access/Ownable.sol";
import {CCIPReceiver}        from "lib/chainlink/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {Client}              from "lib/chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient}       from "lib/chainlink/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";

abstract contract CrossChainLock is CCIPReceiver, Ownable {
  using Client for Client.Any2EVMMessage;

  IRouterClient public immutable ccipRouter;
  uint64        public immutable ethChainSelector;
  address       public immutable ethVaultReceiver;

    modifier onlyCcipRouter() {
        require(msg.sender == address(ccipRouter), "Pool: caller not CCIP router");
        _;
    }

  struct LockInfo { address user; uint256 amountWei; }
  mapping(bytes32 => LockInfo) public locks;
  mapping(address  => bytes32) public userLocks;
  mapping(bytes32 => mapping(address => mapping(uint256 => uint8))) public lockConfirmations;
  mapping(bytes32 => bool) public lockVerified;
  mapping(bytes32 => bool) public isTxDone;

  event MessageReceived(
    bytes32 indexed messageId,
    uint64  indexed sourceChain,
    address          sender,
    bytes            data
  );
  event MessageSent(
    bytes32 indexed messageId,
    uint64  indexed destChain,
    address          receiver,
    address          user
  );

  constructor(
    address _router,
    uint64  _ethChainSelector,
    address _ethVaultReceiver
  )
    CCIPReceiver(_router)
    Ownable(msg.sender)
  {
    ccipRouter         = IRouterClient(_router);
    ethChainSelector   = _ethChainSelector;
    ethVaultReceiver   = _ethVaultReceiver;
  }

  function _ccipReceive(Client.Any2EVMMessage memory msg_)
    internal
    override
    onlyCcipRouter
  {
    // (1) emit raw message
    emit MessageReceived(
      msg_.messageId,
      msg_.sourceChainSelector,
      abi.decode(msg_.sender, (address)),
      msg_.data
    );

    // (2) decode lock
    (address user, bytes32 lockId, uint256 amountWei) =
      abi.decode(msg_.data, (address, bytes32, uint256));

    // (3) guard
    if (lockVerified[lockId]) return;

    // (4) record
    locks[lockId]       = LockInfo(user, amountWei);
    userLocks[user]     = lockId;

    // (5) two-step CCIP + backend
    uint8 cnt = lockConfirmations[lockId][user][amountWei];
    if (cnt == 0) {
      lockConfirmations[lockId][user][amountWei] = 1;
    } else {
      lockConfirmations[lockId][user][amountWei] = 2;
      lockVerified[lockId] = true;
    }
  }

  function backendConfirmation(
    address user,
    bytes32 lockId,
    uint256 amountWei
  ) external onlyOwner
  {
    // bump the same two-step counter
    LockInfo memory info = locks[lockId];
    require(info.user == user && info.amountWei == amountWei, "BC: bad");
    if (!lockVerified[lockId]) {
      uint8 cnt = lockConfirmations[lockId][user][amountWei];
      if (cnt == 0) lockConfirmations[lockId][user][amountWei] = 1;
      else { lockConfirmations[lockId][user][amountWei] = 2; lockVerified[lockId] = true; }
    }
  }

  /// send unlock instruction back to Ethereum vault
  function _sendUnlock(bytes32 lockId, address user) internal returns (bytes32) {
    bytes memory data = abi.encode(user, lockId);

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
    require(address(this).balance >= fee, "SU: insufficient AVAX");

    bytes32 msgId = ccipRouter.ccipSend{ value: fee }(ethChainSelector, ccipMsg);
    emit MessageSent(msgId, ethChainSelector, ethVaultReceiver, user);
    return msgId;
  }
}
