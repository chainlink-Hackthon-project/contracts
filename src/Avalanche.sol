// SPDX-License-Identifier: MIT

pragma solidity >=0.7.0 <0.9.0;


contract AvalancheContract{
    
    bytes32 private s_lastReceivedMessageId; // Store the last received messageId.
    string private s_lastReceivedText; // Store the last received text.

    // is txn for this lockid  done ?
    mapping(bytes32 => bool) public is_tx_done;

    // is this lockid => account == amount == confirmations( 2 ) ? , then only mint function will be called
    // 1 confrimation done by the chainlink and other by backend
    mapping(bytes32 => mapping(address => mapping(uint256 => uint8))) internal lockId_account_confirmations;



    // this will be called when both backend and chainlink gives confirmation
    function giveLoan() internal {

    }



    // chainlink reciever function , change the name according to the chainlink recievr function
    // when this will be called , we will update lockId_account_confirmations mapping , if confirmation ==2 then we will call the give loan function
    function chainLinK_reciever() internal {

    }


// same for this , this will update the lockId_account_confirmations mapping , if confirmation == 2 then we will call the give loan , 
// whoever did the confirmation =2 , will call the giveloan function , 
    function BackendConfirmation () public{

    }



}