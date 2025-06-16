// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import { Pool } from "../src/Pool.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";


contract MockUSDC is ERC20{
    constructor() ERC20("Mock USDC", "mUSDC") {
        _mint(msg.sender, 1_000_000e6);
    }
    function decimals() public pure override returns(uint8){
        return 6;
    }
}

contract PoolTest is Test {
    MockUSDC public usdc;
    Pool public pool;
    address public user = address(0xBEEF);


    // this setup runs before each test and ensures each test starts with a fresh state where :
    // - there is a new Pool contract
    // - the test user has 1000 USDC
    // - the Pool has approval to spend the user's USDC 
    function setUp() public {
        usdc = new MockUSDC();
        pool = new Pool(address(usdc));

        // give use some USDC and approval
        usdc.transfer(user, 1_000e6);
        vm.startPrank(user);
        usdc.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function testDepositMintLP() public {
        vm.startPrank(user);
        pool.deposit(500e6);
        assertEq(pool.balanceOf(user), 500e6);
        assertEq(usdc.balanceOf(address(pool)), 500e6);
        vm.stopPrank();
    }

    function testWithdrawBurnLP() public {
        vm.startPrank(user);
        pool.deposit(300e6);
        pool.withdraw(300e6);
        assertEq(pool.balanceOf(user), 0);
        assertEq(usdc.balanceOf(user), 1_000e6);
        vm.stopPrank();
    }

    function testBorrowAndRepay() public {
        vm.startPrank(user);
        pool.deposit(500e6);
        pool.borrow(200e6);
        assertEq(pool.debt(user), 200e6);
        assertEq(usdc.balanceOf(user), 700e6); // had 1000, +200 borrowed, -500 deposit

        pool.repay(100e6);
        assertEq(pool.debt(user), 100e6);

        vm.stopPrank();
    }

    function testCannotBorrowZero() public {
        vm.startPrank(user);
        vm.expectRevert("Pool: zero borrow");
        pool.borrow(0);
        vm.stopPrank();
    }

    function testCannotRepayOverDebt() public {
        vm.startPrank(user);
        pool.deposit(100e6);
        vm.expectRevert("Pool: overpay");
        pool.repay(200e6);
        vm.stopPrank();
    }


}