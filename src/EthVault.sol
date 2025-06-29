// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {Ownable}  from "@openzeppelin/contracts/access/Ownable.sol";
import {CCIPReceiver} from "lib/chainlink/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {Client} from "lib/chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "lib/chainlink/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";

contract EthVault is CCIPReceiver, Ownable {
    using Client for Client.EVM2AnyMessage;

    IRouterClient   public immutable ccipRouter;
    uint64          public immutable avaxSelector;
    address         public           poolReceiver;
    uint256 private  _nonce;

    struct LockInfo {
        address user;
        uint256 amountWei;
    }
    mapping(bytes32 => LockInfo) public locks;

    event Locked    (bytes32 indexed lockId, address indexed user, uint256 amountWei, bytes32 indexed messageId);
    event Unlocked  (bytes32 indexed lockId, address indexed user, uint256 amountWei);
    event Liquidated(bytes32 indexed lockId, address indexed liquidator, uint256 amountWei);

    modifier onlyCcipRouter() {
        require(msg.sender == address(ccipRouter), "Vault: caller not CCIP router");
        _;
    }

    constructor(address _router, uint64 _avaxSelector)
        CCIPReceiver(_router)
        Ownable(msg.sender)
    {
        require(_router != address(0), "vault: zero router");
        ccipRouter   = IRouterClient(_router);
        avaxSelector = _avaxSelector;
    }

    /// @notice Lock collateral = (msg.value - fee) and send a CCIP message.
    function deposit() external payable returns (bytes32 lockId) {
        require(msg.value > 0, "vault: no ETH sent");
        require(poolReceiver != address(0), "vault: pool not set");

        // 1) generate a unique lockId
        lockId = keccak256(abi.encode(msg.sender, msg.value, block.timestamp, _nonce++));

        // 2) prelim‐build message (using full msg.value) to estimate fee
        Client.EVM2AnyMessage memory feeMsg = Client.EVM2AnyMessage({
            receiver:     abi.encode(poolReceiver),
            data:         abi.encode(msg.sender, lockId, msg.value),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs:    Client._argsToBytes(
                               Client.GenericExtraArgsV2({
                                   gasLimit:                 200_000,
                                   allowOutOfOrderExecution: true
                               })
                           ),
            feeToken:     address(0)
        });
        uint256 fee = ccipRouter.getFee(avaxSelector, feeMsg);

        require(msg.value > fee, "vault: insufficient ETH for fee");

        // 3) actual collateral after fee
        uint256 collateral = msg.value - fee;
        locks[lockId] = LockInfo({ user: msg.sender, amountWei: collateral });

        // 4) build the real CCIP message with collateral amount
        Client.EVM2AnyMessage memory ccipMsg = Client.EVM2AnyMessage({
            receiver:     feeMsg.receiver,
            data:         abi.encode(msg.sender, lockId, collateral),
            tokenAmounts: feeMsg.tokenAmounts,
            extraArgs:    feeMsg.extraArgs,
            feeToken:     feeMsg.feeToken
        });

        // 5) send fee and emit
        bytes32 msgId = ccipRouter.ccipSend{ value: fee }(avaxSelector, ccipMsg);
        emit Locked(lockId, msg.sender, collateral, msgId);
    }

    function _ccipReceive(Client.Any2EVMMessage memory msg_)
        internal override onlyCcipRouter
    {
        bytes memory data = msg_.data;

        if (data.length == 64) {
            (address user, bytes32 lockId) = abi.decode(data, (address, bytes32));
            LockInfo memory lk = locks[lockId];
            require(lk.user == user && lk.amountWei > 0, "vault: bad unlock");

            uint256 amt = lk.amountWei;
            delete locks[lockId];

            (bool ok, ) = user.call{ value: amt }("");
            require(ok, "vault: unlock failed");
            emit Unlocked(lockId, user, amt);

        } else if (data.length == 96) {
            (bytes32 lockId, address liq, uint256 amt) = abi.decode(data, (bytes32, address, uint256));
            LockInfo storage lk = locks[lockId];
            require(lk.user != address(0) && lk.amountWei >= amt, "vault: bad liquidate");

            lk.amountWei -= amt;
            (bool ok, ) = liq.call{ value: amt }("");
            require(ok, "vault: liquidate failed");
            emit Liquidated(lockId, liq, amt);

        } else {
            revert("vault: unknown payload");
        }
    }

    /// @notice external hook to expose CCIPReceiver
    function ccipReceivePublic(Client.Any2EVMMessage calldata msg_) external onlyCcipRouter {
        _ccipReceive(msg_);
    }

    /// @notice set the remote pool address
    function setPoolReceiver(address _poolReceiver) external onlyOwner {
        require(_poolReceiver != address(0), "vault: zero pool");
        poolReceiver = _poolReceiver;
    }

    receive() external payable {}
    fallback() external payable {}
}
