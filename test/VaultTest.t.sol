// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import { Vault } from "../src/Vault.sol";

contract VaultTest is Test {
    Vault public vault;
    address borrower = address(0xABCD);

    function setUp() public {
       vault = new Vault(1 days);
    }

    function testRevertZeroDuration() public{
        vm.expectRevert(bytes("Vault : zero duration"));
        new Vault(0);
    }

    function testLockRevertsZeroAmount() public {
        vm.prank(borrower);
        vm.expectRevert(bytes("Vault: zero amount"));
        vault.lock{value:0}();
    }

    //successful lock updates balance and emits event
    function testLockUpdatesBalanceAndEmits() public {
        vm.deal(borrower, 2 ether);
        vm.prank(borrower);
        vm.expectEmit(true, true, false, false);
        emit Vault.Locked(borrower, 1 ether);
        vault.lock{value: 1 ether}();

        assertEq(vault.locked(borrower), 1 ether);
    }

    //unlock before maturity should revert
    function testUnlockRevertsBeforeMaturity() public {
        vm.deal(borrower, 1 ether);
        vm.prank(borrower);
        vault.lock{value: 1 ether}();

        vm.prank(borrower);
        vm.expectRevert(bytes("Vault: not matured"));
        vault.unlock();
    }

    //unlcok after maturity returns funds and resets balance
    function testUnlockAfterMaturityTransfersAndResets() public {
        vm.deal(borrower, 1 ether);
        vm.prank(borrower);
        vault.lock{value:1 ether}();

        vm.warp(block.timestamp + 1 days + 1);

        uint256 before = borrower.balance;
        vm.prank(borrower);
        vm.expectEmit(true, true, false, false);
        emit Vault.Unlocked(borrower, 1 ether);
        vault.unlock();
        assertEq(borrower.balance, before + 1 ether);

        assertEq(vault.locked(borrower),0);
    }
}
