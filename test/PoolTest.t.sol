// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import {Test, console} from "forge-std/Test.sol";
import { Pool } from "../src/Pool.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";



contract MockUSDT is ERC20{
    constructor() ERC20("Mock USDT", "mUSDT") {
        _mint(msg.sender, 1_000_000e6);
    }
    function decimals() public pure override returns(uint8){
        return 6;
    }
}

contract PoolTest is Test {
    MockUSDT public usdt;
    Pool public pool;
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);

    // ─────────────────────────────────────────────────────────────────────────
    //                              SETUP 
    // ─────────────────────────────────────────────────────────────────────────


    // this setup runs before each test and ensures each test starts with a fresh state where :
    // - there is a new Pool contract
    // - the test users has 1000 USDC each 
    // - the Pool has approval to spend the user's(alice and bob) USDC 
    function setUp() public {
        usdt = new MockUSDT();
        usdt.transfer(alice, 10_000e6);
        usdt.transfer(bob, 10_000e6);

        pool = new Pool(address(usdt), address(0x1), address(0x2), address(this), 1, address(0x3));

        vm.prank(alice);
        usdt.approve(address(pool), type(uint256).max);
        vm.prank(bob);
        usdt.approve(address(pool),type(uint256).max);
    }


    // ─────────────────────────────────────────────────────────────────────────
    //                              DEPOSIT AND WITHDRAWL TEST
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice First depositor should get 1:1 shares
    function  testFirstDeposit() public {
        vm.prank(alice);
        pool.deposit(1_000e6);
        assertEq(pool.balanceOf(alice), 1_000e6, "Alice should have 1000 shares");
        assertEq(usdt.balanceOf(address(pool)), 1_000e6, "Pool holds 1000 USDT");
    }


    /// @notice subsequent depositors mint proportional shares
    function testProportionalDeposit() public {
        // Alice deposits 1000 USDT => recieves 1000 shares 
        vm.prank(alice);
        pool.deposit(1_000e6);
        // Simulate some interest so assets > shares
        //  (here we just mint extra USDT to pool to mimic interest)
        usdt.transfer(address(pool), 100e6);

        //Bob deposits 100 USDT; because poolassets =1100 and supply = 1000
        // bob should recieve: 100* 1000 / 1100  = 90 shares
        vm.prank(bob);
        pool.deposit(100e6);
        uint256 bobShares = pool.balanceOf(bob);
        assertApproxEqRel(bobShares, 90e6, 1_500e14, "Bob should get ~90 shares");
   }



    /// @notice Withdrawl burns shares and retunrs correct USDT
   function testWithdraw() public {
    vm.prank(alice);
    pool.deposit(1_000e6);

    uint256 usdtBefore = usdt.balanceOf(alice);
    uint256 lpBefore = pool.balanceOf(alice);

    // poolAssets = 1000, supply = 1000 shares
    // withdraw 500 shares => get 500 USDT
    vm.prank(alice);
    pool.withdraw(500e6);

    assertEq(pool.balanceOf(alice), lpBefore - 500e6, "Alice left with 500 shares");
    assertEq(usdt.balanceOf(alice), usdtBefore + 500e6, "Alice recovers 500 USDT");
   }



    // ─────────────────────────────────────────────────────────────────────────
    //                             BORROW 
    // ─────────────────────────────────────────────────────────────────────────



}