// SPDX-License-Identifier: MIT

pragma solidity >=0.7.0 <0.9.0;

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";

contract AvalancheContract is CCIPReceiver{

    // Event emitted when a message is received from another chain.
    event MessageReceived(
        bytes32 indexed messageId, // The unique ID of the message.
        uint64 indexed sourceChainSelector, // The chain selector of the source chain.
        address sender, // The address of the sender from the source chain.
        string text // The text that was received.
    );

    event UsdtGivenInPool( address lenderAddress , uint256 usdtGiven);

    /// @notice Constructor initializes the contract with the router address.
    /// @param router The address of the router contract on avalanche fuji 
    constructor() CCIPReceiver(0xF694E193200268f9a4868e4Aa017A0118C9a8177) {}

    bytes32 private s_lastReceivedMessageId; // Store the last received messageId.
    string private s_lastReceivedText; // Store the last received text.

    // is txn for this lockid  done ?
    mapping(bytes32 => bool) public is_tx_done;

    // is this lockid => account == amount == confirmations( 2 ) ? , then only mint function will be called
    // 1 confrimation done by the chainlink and other by backend
    mapping(bytes32 => mapping(address => mapping(uint256 => uint8))) internal lockId_account_confirmations;


    // how much each lender has given usdt
    mapping(address => uint256) public userGivenUSDT;

    //  this will tell how much usdt do we have
    uint256 usdtCollection ;



//  here lenders will give usdt to earn some interest
// frontend will call this function after user has give approval of usdt

// LENDER KO KITNA % MILEGA , WOH BHI DEKHNA HAI 
    function usdtPool() internal payable{

        // no null address
        // check for approval , ki approval to hai na ?

        // after that we will call the usdt contract and call trasferfrom fucntion and contract me paise dalwa lenge
        //  then update userGiveUSDT MAP
        // UPDATE USDTcOOLECTION TOTAL

        
        // backend will catch this event and store the user given balancge , we can show it in the frontend
        // emit UsdtGivenInPool(msg.sender , amount )



        

    }



    // this will be called by either backend_confirmation or chailink reciever function only
    function giveUSDT(
        address user_add,
        bytes32 lockId,
        uint amount
    ) internal {
        require(!is_tx_done[lockId], "transaction already completed");
        require(
            lockId_account_confirmations[lockId][user_add][amount] == 2,
            "not enough confirmations"
        );

        is_tx_done[lockId] = true;

        // 1) CALCULATE KITNA USDT DENA (DYNAMIC dynamic Loan-to-Value (LTV) )
        uint8 LTV = calculateLTV();


        // 2) calculate rate of interest
        uint8 rate_of_interest = calculateRateOfInterest();

        //3 then give usdt to the user address through pool 

        //4 store user address , usdt given , ltv given , rate of interest 

    }

    // this will called by the eth contract ccip send function
    function _ccipReceive(
        Client.Any2EVMMessage memory any2EvmMessage
    ) internal override {
        s_lastReceivedMessageId = any2EvmMessage.messageId; // fetch the messageId

        (uint256 amount, address userAddress, bytes32 lockId) = abi.decode(
            any2EvmMessage.data,
            (uint256, address, bytes32)
        );

        emit MessageReceived(
            any2EvmMessage.messageId,
            any2EvmMessage.sourceChainSelector, // fetch the source chain identifier (aka selector)
            abi.decode(any2EvmMessage.sender, (address)), // abi-decoding of the sender address,
            abi.decode(any2EvmMessage.data, (string))
        );

        if (lockId_account_confirmations[lockId][userAddress][amount] == 0) {
            lockId_account_confirmations[lockId][userAddress][amount] = 1;
        } else if (
            lockId_account_confirmations[lockId][userAddress][amount] == 1
        ) {
            lockId_account_confirmations[lockId][userAddress][amount] = 2;
            giveUSDT(userAddress, lockId, amount);
        }
    }

    //  this will be called by the backend 
    function backendConfirmation(
        address account_add,
        bytes32 lockid,
        uint256 amount
    ) public {
        if (lockId_account_confirmations[lockid][account_add][amount] == 0) {
            lockId_account_confirmations[lockid][account_add][amount] = 1;
        } else if (
            lockId_account_confirmations[lockid][account_add][amount] == 1
        ) {
            lockId_account_confirmations[lockid][account_add][amount] = 2;
            giveUSDT(account_add, lockid, amount);
        }
    }

    // this will be called by the giveUSDT function , to calculate LTV
    function calculateLTV()internal returns(uint8){

    }


    // this will also be called by the giveUSDT function , to calculate rate of interest on loan
    function calculateRateOfInterest() internal returns(uint8){

    }


    // lenders can call and get back their usdt
    function getBackMyUSDT() public{
        
    }
}
