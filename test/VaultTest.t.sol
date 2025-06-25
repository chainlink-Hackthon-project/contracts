// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import {EthVault} from "../src/EthVault.sol";
import {Client} from "lib/chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "lib/chainlink/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";

/// @notice A minimal stub that satisfies IRouterClient
contract MockRouter is IRouterClient {
    function getFee(
        uint64,
        Client.EVM2AnyMessage calldata
    ) external pure returns (uint256) {
        return 0;
    }

    function ccipSend(
        uint64,
        Client.EVM2AnyMessage calldata
    ) external payable returns (bytes32) {
        // return a deterministic messageId
        return keccak256("MOCK_CIP");
    }

    function isChainSupported(
        uint64 destChainSelector
    ) external view override returns (bool supported) {}
}

contract EthVaultTest is Test {
  EthVault       vault;
  MockRouter     router;
  uint64 constant AVAX_CHAIN = 43114;
  address constant POOL        = address(0x777);
  address constant USER        = address(0x123);
  address constant LIQ = address(0x456);

  function setUp() public {
    router = new MockRouter();
    vault  = new EthVault(
      address(router),
      AVAX_CHAIN,
      POOL
    );
    // give USER some ETH
    vm.deal(USER, 5 ether);
    vm.deal(LIQ, 1 ether);
  }

  function testDepositEmitsLockedAndStoresLock() public {
    uint256 amount = 1 ether;

        // impersonate USER for both expectEmit and deposit
        vm.startPrank(USER);

        // 1) expect the Locked event
        vm.expectEmit(false, true, false, true);
        emit EthVault.Locked(bytes32(0), USER, amount, 0);

        // 2) call deposit directly and get the lockId
        bytes32 lockId = vault.deposit{ value: amount }(amount);

        vm.stopPrank();

        // 3) verify that the mapping was updated
        (address user, uint256 amountWei) = vault.locks(lockId);
        assertEq(user, USER,   "wrong user in mapping");
        assertEq(amountWei, amount, "wrong amount in mapping");
  }


  /// @notice deposit() should reject a zero‐amount lock
    function testDepositRevertsOnZeroAmount() public {
        vm.prank(USER);
        vm.expectRevert("vault: zero amount");
        // even if they send ETH, amount == 0 must revert first
        vault.deposit{ value: 1 ether }(0);
    }

    /// @notice deposit() should reject when msg.value < amount+fee
    function testDepositRevertsOnInsufficientETH() public {
        uint256 amount = 1 ether;
        vm.prank(USER);
        // fee is zero in MockRouter, so sending less than `amount` reverts
        vm.expectRevert("vault: insufficient ETH");
        vault.deposit{ value: 0.5 ether }(amount);
    }


    function testUnlockAfterFullRepay() public {
        // 1) deposit 1 ETH
        vm.prank(USER);
        bytes32 lockId = vault.deposit{ value: 1 ether }(1 ether);

        // 2) simulate the Avalanche Pool sending us back the "unlock" message:
        Client.Any2EVMMessage memory msg_ = Client.Any2EVMMessage({
            messageId:           lockId,
            sourceChainSelector: AVAX_CHAIN,
            sender:              abi.encode(POOL),
            data:                abi.encode(USER, lockId),
            destTokenAmounts:    new Client.EVMTokenAmount[](0)
        });

        // capture balances & expect event
        uint256 before = USER.balance;
        vm.expectEmit(true, true, true, true);
        emit EthVault.Unlocked(lockId, USER, 1 ether);

        // 3) call the CCIP hook
        vm.prank(address(router));
        vault.ccipReceivePublic(msg_);

        // 4) user got their ETH back
        assertEq(USER.balance, before + 1 ether, "ETH not returned");

        // 5) the lock was deleted
        (address u, uint256 w) = vault.locks(lockId);
        assertEq(u, address(0),   "lock not cleared");
        assertEq(w, 0,            "amount not cleared");
    }


    function testLiquidatePartialCollateral() public {
        // 1) deposit 2 ETH
        vm.prank(USER);
        bytes32 lockId = vault.deposit{ value: 2 ether }(2 ether);

        // 2) now simulate a “liquidate” callback for 0.6 ETH
        Client.Any2EVMMessage memory msg_ = Client.Any2EVMMessage({
            messageId:           lockId,
            sourceChainSelector: AVAX_CHAIN,
            sender:              abi.encode(POOL),
            data:                abi.encode(lockId, LIQ, uint256(0.6 ether)),
            destTokenAmounts:    new Client.EVMTokenAmount[](0)
        });

        // 3) expect the event and track balances
        uint256 beforeLiq = LIQ.balance;
        vm.expectEmit(true, true, true, true);
        emit EthVault.Liquidated(lockId, LIQ, 0.6 ether);

        // 4) run the CCIP hook
        vm.prank(address(router));
        vault.ccipReceivePublic(msg_);

        // 5) liquidator got 0.6 ETH
        assertEq(LIQ.balance, beforeLiq + 0.6 ether);

        // 6) 1.4 ETH remains in the vault
        ( , uint256 rem) = vault.locks(lockId);
        assertEq(rem, 1.4 ether);
    }

}
