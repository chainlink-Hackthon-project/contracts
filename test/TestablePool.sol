// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../src/Pool.sol";
import {Client} from "lib/chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";


/// @notice Exposes Pool’s internal CCIP hook for testing
contract TestablePool is Pool {
    constructor(
        address _usdt,
        address _ethUsdFeed,
        address _volFeed,
        address _router,
        uint64  _ethChainSelector,
        address _ethVaultReceiver
    )
        Pool(
            _usdt,
            _ethUsdFeed,
            _volFeed,
            _router,
            _ethChainSelector,
            _ethVaultReceiver
        )
    {}

    /// @notice Allow tests to call the CCIP‐receive hook directly
    function ccipReceivePublic(Client.Any2EVMMessage memory msg_) external {
        _ccipReceive(msg_);
    }
}
