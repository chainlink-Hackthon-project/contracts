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


     // ──────────────── Revert Tests ────────────────

    function testDepositZeroReverts() public {
        vm.prank(user);
        vm.expectRevert("Pool: zero deposit");
        pool.deposit(0);
    }

    function testWithdrawZeroReverts() public {
        vm.prank(user);
        vm.expectRevert("Pool: zero withdraw");
        pool.withdraw(0);
    }

    function testRepayZeroReverts() public {
        vm.prank(user);
        vm.expectRevert("Pool: zero repay");
        pool.repay(0);
    }

    // ──────────────── APR View Tests ────────────────

    /// @notice At 0% utilization, borrow APR == baseBps == 300 and supply APR == 0.
    function testAPRAtZeroUtilization() public view {
        assertEq(pool.borrowAPR(), 300);
        assertEq(pool.supplyAPR(), 0);
    }

    /// @notice At 40% utilization (deposit 1000 → borrow 400):
    /// borrowAPR = 3% + 15% * 40% = 3% + 6% = 9% → 900 bps
    /// supplyAPR = U * borrowAPR * (1 - 10% reserve) = 0.4 * 9% * 0.9 = 3.24% → 324 bps
    function testAPRAtFortyPercentUtilization() public {
        vm.startPrank(user);
        pool.deposit(1_000e6);
        pool.borrow(400e6);
        vm.stopPrank();

        uint256 borrowAPR = pool.borrowAPR();
        uint256 supplyAPR = pool.supplyAPR();

        assertEq(borrowAPR, 900, "expected 9% borrow APR (900bps)");
        assertEq(supplyAPR, 324, "expected 3.24% supply APR (324bps)");
    }

    // ──────────────── Interest Accrual Tests ────────────────

    /// @notice After 1 year at 40% utilization:
    /// - interest       = 400 * 9% = 36 USDC  → 36e6 units
    /// - fees (10%)     = 3.6 USDC            → 3.6e6 units
    /// - added to borrows = 36 − 3.6 = 32.4   → 32.4e6 units
    function testAccrueInterestFortyPercentUtilAfterOneYear() public {
        vm.startPrank(user);
        pool.deposit(1_000e6);
        pool.borrow(400e6);
        vm.stopPrank();

        // Fast-forward exactly one year
        vm.warp(block.timestamp + 365 days);

        // Manually accrue interest
        pool.accrueInterest();

        // Check protocol reserves (10% of 36e6 = 3.6e6)
        uint256 expectedFee = 36e6 * pool.reserveFactorBps() / 10_000;
        assertEq(pool.totalReserves(), expectedFee);

        // Check totalBorrows increased by (36e6 − 3.6e6) = 32.4e6
        uint256 expectedBorrows = 400e6 + (36e6 - expectedFee);
        assertEq(pool.totalBorrows(), expectedBorrows);
    }

}