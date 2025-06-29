// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {Ownable}       from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {CCIPReceiver}  from "lib/chainlink/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {Client}        from "lib/chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "lib/chainlink/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";

/// @title Cross-Chain Lock Confirmation
/// @notice Handles incoming CCIP messages for ETH→USDT locks and two-step confirmation
/// @dev Sends unlock/liquidate messages back via CCIPReceiver hooks
abstract contract CrossChainLock is CCIPReceiver, Ownable {
  using Client for Client.Any2EVMMessage;

  /// @notice CCIP router on this chain
  IRouterClient public immutable ccipRouter;
  /// @notice Chain selector of the remote Ethereum vault
  uint64        public immutable ethChainSelector;
  /// @notice Address of the Vault contract on Ethereum
  address       public immutable ethVaultReceiver;

  /// @notice Mapping lockId → (locker, amountWei)
  struct LockInfo { address user; uint256 amountWei; }
  mapping(bytes32 => LockInfo)                           public locks;
  /// @notice Last lockId per user (for unlocks)
  mapping(address  => bytes32)                           public userLocks;
  /// @notice How many confirmations each lock has seen (0 → 1 from CCIP, 1 → 2 from backend)
  mapping(bytes32 => mapping(address => mapping(uint256 => uint8)))
                                                         public lockConfirmations;
  /// @notice True once a lock has reached 2/2 confirmations
  mapping(bytes32 => bool)                               public lockVerified;
  /// @notice Prevent reuse of a lockId for multiple borrows
  mapping(bytes32 => bool)                               public isTxDone;

  /// @notice Emitted when a CCIP “lock” message arrives
  event MessageReceived(
    bytes32 indexed messageId,
    uint64  indexed sourceChain,
    address          sender,
    bytes            data
  );

  /// @notice Emitted whenever we send a CCIP message back (unlock/liquidate)
  event MessageSent(
    bytes32 indexed messageId,
    uint64  indexed destChain,
    address          receiver,
    address          user
  );

  /// @param _router            The CCIP router on this chain
  /// @param _ethChainSelector  Destination chain selector (Ethereum)
  /// @param _ethVaultReceiver  The Ethereum Vault’s address (ABI-encoded)
  constructor(
    address _router,
    uint64  _ethChainSelector,
    address _ethVaultReceiver
  )
    CCIPReceiver(_router)
    Ownable(msg.sender)
  {
    require(_router             != address(0), "CCL: zero router");
    require(_ethVaultReceiver   != address(0), "CCL: zero vault");
    ccipRouter         = IRouterClient(_router);
    ethChainSelector   = _ethChainSelector;
    ethVaultReceiver   = _ethVaultReceiver;
  }

  /// @dev Only the Chainlink router may invoke
  modifier onlyCcipRouter_() {
    require(msg.sender == address(ccipRouter), "CCL: caller not CCIP router");
    _;
  }

  /// @inheritdoc CCIPReceiver
  function _ccipReceive(Client.Any2EVMMessage memory incoming)
    internal
    override
    onlyCcipRouter_  
  {
    // 1) Emit the raw CCIP message for indexing
    address sender = abi.decode(incoming.sender, (address));
    emit MessageReceived(
      incoming.messageId,
      incoming.sourceChainSelector,
      sender,
      incoming.data
    );

    // 2) Parse the lock payload: (user, lockId, amountWei)
    (address user, bytes32 lockId, uint256 amountWei) =
      abi.decode(incoming.data, (address, bytes32, uint256));

    // 3) If already fully verified, skip further processing
    if (lockVerified[lockId]) {
      return;
    }

    // 4) Record the lock info
    locks[lockId]    = LockInfo(user, amountWei);
    userLocks[user]  = lockId;

    // 5) Bump the CCIP confirmation counter
    uint8 cnt = lockConfirmations[lockId][user][amountWei];
    if (cnt == 0) {
      // first confirmation (from CCIP)
      lockConfirmations[lockId][user][amountWei] = 1;
    } else {
      // second confirmation automatically if CCIP arrives twice
      lockConfirmations[lockId][user][amountWei] = 2;
      lockVerified[lockId] = true;
    }
  }

  /// @notice Backend must call this to finalize a lock’s confirmation
  /// @dev Only the contract `owner` (your off-chain backend key) may call
  /// @param user       The lock’s original user
  /// @param lockId     The cross-chain lock identifier
  /// @param amountWei  The amount of ETH locked (wei)
  function backendConfirmation(
    address user,
    bytes32 lockId,
    uint256 amountWei
  )
    external
    onlyOwner
  {
    // 1) Must match the on-chain record
    LockInfo memory info = locks[lockId];
    require(info.user       == user,       "CCL: user mismatch");
    require(info.amountWei  == amountWei,  "CCL: amount mismatch");

    // 2) If already verified, nothing to do
    if (lockVerified[lockId]) {
      return;
    }

    // 3) Bump the same counter: 0 → 1 or 1 → 2
    uint8 cnt = lockConfirmations[lockId][user][amountWei];
    if (cnt == 0) {
      lockConfirmations[lockId][user][amountWei] = 1;
    } else {
      lockConfirmations[lockId][user][amountWei] = 2;
      lockVerified[lockId] = true;
    }
  }

  /// @dev Send an “unlock” instruction back to the Ethereum vault
  /// @param lockId  The lock identifier to release
  /// @param user    The borrower’s address
  /// @return messageId  The CCIP message ID for tracking
  function _sendUnlock(bytes32 lockId, address user)
    internal
    returns (bytes32 messageId)
  {
    // 1) Build payload = (user, lockId)
    bytes memory data = abi.encode(user, lockId);

    // 2) Build CCIP message object
    Client.EVM2AnyMessage memory outMsg = Client.EVM2AnyMessage({
      receiver:     abi.encode(ethVaultReceiver),
      data:         data,
      tokenAmounts: new Client.EVMTokenAmount[](0),
      extraArgs:    Client._argsToBytes(
                       Client.GenericExtraArgsV2({
                         gasLimit:                 500_000,
                         allowOutOfOrderExecution: true
                       })
                     ),
      feeToken:     address(0)
    });

    // 3) Ensure the contract can pay the fee
    uint256 fee = ccipRouter.getFee(ethChainSelector, outMsg);
    require(address(this).balance >= fee, "CCL: insufficient balance");

    // 4) Dispatch and emit
    messageId = ccipRouter.ccipSend{ value: fee }(
      ethChainSelector,
      outMsg
    );
    emit MessageSent(messageId, ethChainSelector, ethVaultReceiver, user);
  }
}
