// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import {Client}                 from "lib/chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient}          from "lib/chainlink/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";

/// @notice A test‐only stub that never charges a fee and returns a dummy messageId
contract MockRouter is IRouterClient {
    function getFee(
        uint64 /*destChain*/,
        Client.EVM2AnyMessage calldata /*msg_*/
    ) external pure override returns (uint256) {
        return 0;
    }

    function ccipSend(
        uint64 /*dst*/,
        Client.EVM2AnyMessage calldata /*msg_*/
    ) external payable override returns (bytes32) {
        // just return a fixed bytes32 so you can assert on it
        return keccak256("fake-ccip-id");
    }

    function isChainSupported(
        uint64 destChainSelector
    ) external view override returns (bool supported) {}
}
