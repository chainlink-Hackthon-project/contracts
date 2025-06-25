// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {Ownable}  from "@openzeppelin/contracts/access/Ownable.sol";
import {CCIPReceiver} from "lib/chainlink/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {Client} from "lib/chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "lib/chainlink/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";

/// @notice Ethereum‐side vault for cross-chain ETH collateral
contract EthVault is CCIPReceiver, Ownable {
    using Client for Client.EVM2AnyMessage;

    /// @notice Chainlink CCIP router on Ethereum
    IRouterClient public immutable ccipRouter;
    /// @notice Chain selector for Avalanche
    uint64         public immutable avaxSelector;
    /// @notice Avalanche Pool address
    address        public immutable poolReceiver;

    uint256 private _nonce;

    modifier onlyCcipRouter() {
        require(msg.sender == address(ccipRouter), "Pool: caller not CCIP router");
        _;
    }

    struct LockInfo {
        address user;
        uint256 amountWei;
    }
    /// @notice Tracks each open lock
    mapping(bytes32 => LockInfo) public locks;

    event Locked    (bytes32 indexed lockId, address indexed user,        uint256 amountWei, bytes32 indexed messageId);
    event Unlocked  (bytes32 indexed lockId, address indexed user,        uint256 amountWei);
    event Liquidated(bytes32 indexed lockId, address indexed liquidator, uint256 amountWei);

    constructor(
        address _router,
        uint64  _avaxSelector,
        address _poolReceiver
    )
        CCIPReceiver(_router)
        Ownable(msg.sender)
    {
        require(_router       != address(0), "vault: zero router");
        require(_poolReceiver != address(0), "vault: zero pool");
        ccipRouter    = IRouterClient(_router);
        avaxSelector  = _avaxSelector;
        poolReceiver  = _poolReceiver;
    }

    /**
     * @notice Lock ETH in this vault and send a CCIP message to Avalanche Pool.
     * @param amountWei  How much ETH (in wei) to lock as collateral
     * @dev caller must send exactly `amountWei + fee` in msg.value
     */
    function deposit(uint256 amountWei)
        external
        payable
        returns (bytes32 lockId)
    {
        require(amountWei > 0, "vault: zero amount");

        // 1) generate a unique lockId
        lockId = keccak256(
            abi.encode(msg.sender, amountWei, block.timestamp, _nonce++)
        );
        locks[lockId] = LockInfo(msg.sender, amountWei);

        // 2) build the CCIP message to Avalanche
        Client.EVM2AnyMessage memory ccipMsg = Client.EVM2AnyMessage({
            receiver:     abi.encode(poolReceiver),
            data:         abi.encode(msg.sender, lockId, amountWei),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs:    Client._argsToBytes(
                               Client.GenericExtraArgsV2({
                                   gasLimit:                 200_000,
                                   allowOutOfOrderExecution: true
                               })
                           ),
            feeToken:     address(0)
        });

        uint256 fee = ccipRouter.getFee(avaxSelector, ccipMsg);

        // must send  collateral + fee
        require(msg.value >= amountWei + fee, "vault: insufficient ETH");

        //refund the dust
        uint256 refund = msg.value - (amountWei+fee);
        if(refund>0){
            payable(msg.sender).transfer(refund);
        }

        // 3) send CCIP and emit
        bytes32 msgId = ccipRouter.ccipSend{ value: fee }(avaxSelector, ccipMsg);
        emit Locked(lockId, msg.sender, amountWei, msgId);
    }

    /// @dev CCIPReceiver hook (only called by the Chainlink router)
    function _ccipReceive(Client.Any2EVMMessage memory msg_)
        internal
        override
        onlyCcipRouter
    {
        bytes memory data = msg_.data;

        if (data.length == 64) {
            // -- UNLOCK: (address user, bytes32 lockId)
            (address user, bytes32 lockId) = abi.decode(data, (address, bytes32));
            LockInfo memory lk = locks[lockId];
            require(lk.user == user && lk.amountWei> 0, "vault: bad unlock");

            uint256 amt = lk.amountWei;
            delete locks[lockId];

            // send ETH back to borrower
            (bool ok, ) = user.call{ value: amt }("");
            require(ok, "vault: unlock failed");

            emit Unlocked(lockId, user, amt);

        } else if (data.length == 96) {
            // -- LIQUIDATE: (bytes32 lockId, address liquidator, uint256 amountWei)
            (bytes32 lockId, address liq, uint256 amt) =
                abi.decode(data, (bytes32, address, uint256));

            LockInfo storage lk = locks[lockId];
            require(lk.user!=address(0) && lk.amountWei >= amt, "vault: bad liquidate");

            lk.amountWei -= amt;

            // send seized ETH to liquidator
            (bool ok, ) = liq.call{ value: amt }("");
            require(ok, "vault: liquidate failed");

            emit Liquidated(lockId, liq, amt);

        } else {
            revert("vault: unknown payload");
        }
    }

    function ccipReceivePublic(Client.Any2EVMMessage calldata msg_) external onlyCcipRouter{
        _ccipReceive(msg_);
    }

    /// @dev Allow this contract to accept refunds or leftover ETH
    receive() external payable {}
    fallback() external payable {}
}