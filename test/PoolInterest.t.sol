// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";
import {MockV3Aggregator} from "lib/chainlink/contracts/src/v0.8/shared/mocks/MockV3Aggregator.sol";
import {MockRouter} from "./MockRouter.sol";
import {Client} from "lib/chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { TestablePool } from "./TestablePool.sol";



contract MockUSDT is ERC20{
    constructor() ERC20("Mock USDT", "mUSDT") {
        _mint(msg.sender, 1_000_000e6);
    }
    function decimals() public pure override returns(uint8){
        return 6;
    }
}

contract PoolInterestTest is Test {
    MockUSDT         usdt;
    MockV3Aggregator priceFeed;
    MockV3Aggregator volFeed;
    MockRouter       router;
    TestablePool     pool;

    address alice = address(0xA11CE);
    bytes32 lockId;
    uint256 amountWei = 1 ether;    // 1 ETH
    uint256 maxBorrow;

    function setUp() public {
        // 1) Deploy mocks
        usdt      = new MockUSDT();
        router    = new MockRouter();
        priceFeed = new MockV3Aggregator(8, 2_000 * 1e8); // $2,000
        volFeed   = new MockV3Aggregator(18, 2 * 1e17);   // 20% vol

        // 2) Seed Alice and the pool
        usdt.transfer(alice, 10_000e6);
        usdt.transfer(address(this), 5_000e6);

        // 3) Deploy Pool
        pool = new TestablePool(
          address(usdt),
          address(priceFeed),
          address(volFeed),
          address(router),
          1,              // sepolia selector
          address(0x123)  // dummy eth vault
        );

        // 4) Give pool its USDT liquidity
        usdt.approve(address(pool), type(uint256).max);
        usdt.transfer(address(pool), 5_000e6);

        // 5) CCIP‐receive + backend confirmation so we can borrow
        lockId = keccak256("alice-lock");
        Client.Any2EVMMessage memory ccipMsg = Client.Any2EVMMessage({
          messageId:           lockId,
          sourceChainSelector: 1,
          sender:              abi.encode(address(0x999)),
          data:                abi.encode(alice, lockId, amountWei),
          destTokenAmounts:        new Client.EVMTokenAmount[](0)
        });

        // impersonate router for the CCIP hook
        vm.prank(address(router));
        pool.ccipReceivePublic(ccipMsg);
        // off‐chain confirmation
        pool.backendConfirmation(alice, lockId, amountWei);

        // 6) Alice borrows the full 50% LTV:
        maxBorrow = (pool.collateralUsd(alice) * pool.currentLTVBps()) / 10_000;
        vm.startPrank(alice);
        pool.borrowWithLock(lockId, maxBorrow);
        vm.stopPrank();

        // at this point:
        //   pool.totalBorrows() == maxBorrow (500e6 USDT)
        //   pool.balanceOf(alice) unchanged
    }


    function testAccrueOneYearOfInterest() public {
        uint256 maximumBorrow = pool.totalBorrows();           // e.g. 1_000e6
        uint256 aprBps    = pool.borrowAPR();              // grab the rate at t0 (e.g. 600)

        // sanity
        assertEq(maximumBorrow,        maxBorrow);
        assertEq(pool.totalReserves(), 0);

        // warp 1 year
        vm.warp(block.timestamp + 365 days);

        // accrue interest using that aprBps
        pool.accrueInterest();

        // expected based on the aprBps from before the warp
        uint256 expectedInterest = (maximumBorrow * aprBps) / 10_000;        // 60e6
        uint256 expectedFee      = (expectedInterest * pool.reserveFactorBps()) / 10_000; // 6e6
        uint256 expectedToPool   = expectedInterest - expectedFee;      // 54e6
        uint256 expectedBorrows  = maximumBorrow + expectedToPool;          // 1_054e6

        assertEq(pool.totalReserves(), expectedFee);
        assertEq(pool.totalBorrows(),  expectedBorrows);
    }
}
