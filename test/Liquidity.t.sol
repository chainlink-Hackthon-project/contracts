// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/PoolContract/Liquidity.sol";

/// @dev A minimal ERC20 to stand in for USDT
contract MockUSDT is ERC20 {
    constructor() ERC20("Mock USDT", "MUSDT") {}
    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

/// @dev Expose Liquidity so we can deploy it directly
contract TestLiquidity is Liquidity {
    constructor(IERC20 _usdt) Liquidity(_usdt) {}
}

/// @dev We redeclare the events so vm.expectEmit can pick them up
contract LiquidityTest is Test {
    MockUSDT        usdt;
    TestLiquidity  vault;
    address constant ALICE = address(0xABCD);
    address constant BOB   = address(0xBEEF);

    // match the event signatures in Liquidity.sol
    event Deposited(address indexed user, uint256 amount,  uint256 shares);
    event Withdrawn(address indexed user, uint256 amount,  uint256 shares);

    function setUp() public {
        usdt  = new MockUSDT();
        vault = new TestLiquidity(IERC20(usdt));

        // give Alice & Bob some mock USDT
        usdt.mint(ALICE, 1000 ether);
        usdt.mint(BOB,   1000 ether);
    }

    function testDepositZeroReverts() public {
        vm.prank(ALICE);
        vm.expectRevert("Liquidity: zero deposit");
        vault.deposit(0);
    }

    function testFirstDepositMintsEqualShares() public {
        vm.startPrank(ALICE);
        usdt.approve(address(vault), 100 ether);

        // expect event Deposited(ALICE,100,100)
        vm.expectEmit(true, true, true, true);
        emit Deposited(ALICE, 100 ether, 100 ether);

        vault.deposit(100 ether);
        assertEq(vault.balanceOf(ALICE), 100 ether, "shares");
        vm.stopPrank();
    }

    function testSubsequentDepositMintsProportionalShares() public {
        // Alice puts in 100
        vm.startPrank(ALICE);
        usdt.approve(address(vault), 100 ether);
        vault.deposit(100 ether);
        vm.stopPrank();

        // Bob puts in 50 → should get (50*100)/100 = 50 shares
        vm.startPrank(BOB);
        usdt.approve(address(vault), 50 ether);
        vm.expectEmit(true, true, true, true);
        emit Deposited(BOB, 50 ether, 50 ether);

        vault.deposit(50 ether);
        assertEq(vault.balanceOf(BOB), 50 ether, "bob's shares");
        vm.stopPrank();
    }

    function testWithdrawZeroReverts() public {
        vm.prank(ALICE);
        vm.expectRevert("Liquidity: zero withdraw");
        vault.withdraw(0);
    }

    function testWithdrawBurnsSharesAndReturnsUSDT() public {
        // deposit 100 for Alice
        vm.startPrank(ALICE);
        usdt.approve(address(vault), 100 ether);
        vault.deposit(100 ether);

        // she withdraws 50 shares → gets 50 USDT back
        vm.expectEmit(true, true, true, true);
        emit Withdrawn(ALICE, 50 ether, 50 ether);

        vault.withdraw(50 ether);

        // USDT balance = 1000 - 100 + 50
        assertEq(usdt.balanceOf(ALICE), 950 ether, "USDT refund");
        // shares left = 50
        assertEq(vault.balanceOf(ALICE),    50 ether, "shares left");
        vm.stopPrank();
    }

    function testWithdrawZeroOutputReverts() public {
        // --- 1) Alice deposits 1 USDT into the vault ---
        vm.startPrank(ALICE);
        usdt.approve(address(vault), 1 ether);
        vault.deposit(1 ether);
        vm.stopPrank();

        // --- 2) Make sure the vault actually holds that 1 USDT ---
        address vaultAddr = address(vault);
        uint256 vaultBalance = usdt.balanceOf(vaultAddr);
        assertEq(vaultBalance, 1 ether, "vault should hold exactly 1 USDT");

        // --- 3) Impersonate the vault itself and drain it out ---
        vm.prank(vaultAddr);
        usdt.transfer(address(0xDEAD), vaultBalance);

        // Confirm it’s zeroed out
        assertEq(usdt.balanceOf(vaultAddr), 0, "vault must now hold 0 USDT");

        // --- 4) Now Alice’s withdraw should hit “zero output” revert ---
        vm.startPrank(ALICE);
        vm.expectRevert("Liquidity: zero output");
        vault.withdraw(1 ether);
        vm.stopPrank();
    }
}
