// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "forge-std/Test.sol";

// pull in your CrossChainLock
import {CrossChainLock} from "../src/PoolContract/CrossChainLock.sol";

// chainlink types
import {Client}         from "lib/chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient}  from "lib/chainlink/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";

/// @notice A minimal router stub: fees=0, ccipSend returns a dummy id
contract MockRouter is IRouterClient {
    function getFee(uint64, Client.EVM2AnyMessage calldata) external pure returns (uint256) {
        return 0;
    }
    function ccipSend(uint64, Client.EVM2AnyMessage calldata) external payable returns (bytes32) {
        return bytes32("MOCK_CIP_ID");
    }
    function isChainSupported(uint64) external pure returns (bool) {
        return true;
    }
}

/// @notice Expose the internal `_ccipReceive` via a public wrapper
contract TestLock is CrossChainLock {
    constructor(address router, uint64 chainSelector, address vaultReceiver)
      CrossChainLock(router, chainSelector, vaultReceiver)
    {}

    /// @notice allow our tests to call the internal CCIP receive hook
    function ccipReceivePublic(Client.Any2EVMMessage calldata msg_) external onlyCcipRouter {
        _ccipReceive(msg_);
    }
}

contract CrossChainLockTest is Test {
    MockRouter  router;
    TestLock    lockContract;

    uint64 constant   ETH_CHAIN = 1;
    address constant VAULT      = address(0x777);
    address constant USER       = address(0x1234);

    // pick any lockId & amount
    bytes32 constant  LOCK_ID   = keccak256("SOME_LOCK");
    uint256 constant  AMT       = 1 ether;

    function setUp() public {
        router       = new MockRouter();
        // deploy stub with owner = this test contract
        lockContract = new TestLock(address(router), ETH_CHAIN, VAULT);
    }

    function _makeMsg() internal pure returns (Client.Any2EVMMessage memory) {
        return Client.Any2EVMMessage({
            messageId:           LOCK_ID,
            sourceChainSelector: ETH_CHAIN,
            sender:              abi.encode(USER),
            data:                abi.encode(USER, LOCK_ID, AMT),
            destTokenAmounts:   new Client.EVMTokenAmount[](0)
            
        });
    }

    function test_ccipArrival_onlyIncrementsToOne() public {
        // 1) simulate the CCIP router calling in
        vm.prank(address(router));
        lockContract.ccipReceivePublic(_makeMsg());

        // 2) the lock should be recorded
        (address u, uint256 w) = lockContract.locks(LOCK_ID);
        assertEq(u, USER, "wrong user recorded");
        assertEq(w, AMT,  "wrong amount recorded");

        // 3) confirmation count is 1
        uint8 cnt = lockContract.lockConfirmations(LOCK_ID, USER, AMT);
        assertEq(cnt, 1, "should have 1st confirmation");

        // 4) but still not fully verified
        assertFalse(lockContract.lockVerified(LOCK_ID), "should not be verified yet");
    }

}
