// SPDX-License-Identifier: MIT

pragma solidity >=0.7.0 <0.9.0;

import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {LinkTokenInterface} from "@chainlink/contracts/src/v0.8/shared/interfaces/LinkTokenInterface.sol";

contract EthContract {
    // Custom errors to provide more descriptive revert messages.
    error NotEnoughBalance(uint256 currentBalance, uint256 calculatedFees); // Used to make sure contract has enough balance.

    event lockedEther(
        address indexed user_address,
        uint256 amount,
        bytes32 indexed lockId
    );

    //  chainlink ccip event
    event MessageSent(
        bytes32 indexed messageId, // The unique ID of the CCIP message.
        uint64 indexed destinationChainSelector, // The chain selector of the destination chain.
        address receiver, // The address of the receiver on the destination chain.
        address userAddress
    );

    // maximum allowed locking ether is 10 eth , because if any failure happens then , anything bug shouldnt happne
    uint256 max_eth_lock = 10;
    uint256 wai_in_one_eth = 1000000000000000000;

    // how much collateral user has stored , we will store it in backend also, to show it in the frontend
    mapping(address => uint256) public user_collateral;

    // we will store in wai/smallest unit
    uint256 totalEth = 0;

    // router client for eth sepolia
    IRouterClient private s_router =
        IRouterClient(0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59);

    function StoreCollateral() public payable {
        require(
            msg.sender != address(0),
            "null address is calling , not allowed"
        );
        require(
            msg.value > 0 && msg.value < max_eth_lock * wai_in_one_eth,
            "amount sent is not in limit"
        );

        // unique id for every txn
        bytes32 lockId = keccak256(
            abi.encodePacked(block.timestamp, msg.sender, msg.value)
        );

        // calculating the ccip fees for sending message
        uint256 ccipFees = Calculate_ccip_message_sending_fees(
            14767482510784806043,
            msg.sender,
            lockId,
            msg.value
        );

        // we wont go further , if collateral is not even enough to pay for gas + ccip message fees
        if (msg.value <= ccipFees) {
            revert NotEnoughBalance(msg.value, ccipFees);
        }

        // saved user's collateral amount
        user_collateral[msg.sender] = msg.value;

        // increased the net eth of the contract
        totalEth += msg.value;

        // backend will pick this and call the avalanche contract
        emit lockedEther(msg.sender, msg.value, lockId);


        // chainlick will send this to the avalanche _reciever function
        sendChainlLink_Confirmation(
            14767482510784806043,
            address(0x925d2885e8FD7cD701CaA78ab6450685f308F1ac), // todo => change it to the avalanche contract address
            msg.sender,
            lockId,
            msg.value
        );
    }


    function sendChainlLink_Confirmation(
        uint64 destinationChainSelector,
        address receiver,
        address userAddress,
        bytes32 lockId,
        uint256 amount
    ) internal {
        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(userAddress, lockId, amount),
            data: abi.encode( userAddress , lockId , amount), // ABI-encoded string 
            tokenAmounts: new Client.EVMTokenAmount[](0), // no tokens are being sent
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({
                    gasLimit: 200_000, // Gas limit for the callback on the destination chain
                    allowOutOfOrderExecution: true // Allows the message to be executed out of order relative to other messages from the same sender
                })
            ),
            //here , 0 means , it will deduct in currency , on which chain this is deployed , that is eth sepolia
            feeToken: address(0)
        });

        uint256 fees = s_router.getFee(
            destinationChainSelector,
            evm2AnyMessage
        );

        // Send the message through the router and store the returned message ID
        // also it will take fees(wai/eth) from the contract
        bytes32 messageId = s_router.ccipSend{value: fees}(
            destinationChainSelector,
            evm2AnyMessage
        );

        // Emit an event with message details
        emit MessageSent(
            messageId,
            destinationChainSelector,
            receiver,
            userAddress
        );
    }


    //  this function will use chainlink price feed and calclulate the equivalent usdt for eth , based on eth performance
    function calculate_eth_equivalent() internal returns(uint8){
    }

    // this will calculate the ccip message sending fees in eth
    function Calculate_ccip_message_sending_fees(
        uint64 destinationChainSelector,
        address userAddress,
        bytes32 lockId,
        uint256 amount
    ) internal view returns (uint256) {
        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(userAddress, lockId, amount),
            data: abi.encode(userAddress , lockId , amount ), // ABI-encoded string
            tokenAmounts: new Client.EVMTokenAmount[](0), // no tokens are being sent
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({
                    gasLimit: 200_000, // Gas limit for the callback on the destination chain
                    allowOutOfOrderExecution: true // Allows the message to be executed out of order relative to other messages from the same sender
                })
            ),
            //here , 0 means , it will deduct in currency , on which chain this is deployed , that is eth sepolia
            feeToken: address(0)
        });

        // Get the fee required to send the message
        uint256 fees = s_router.getFee(
            destinationChainSelector,
            evm2AnyMessage
        );

        return fees;
    }



    function ReleaseCollateral() public {}
}
