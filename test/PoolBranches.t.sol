// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import {Pool}         from "../src/Pool.sol";
import {TestablePool} from "./TestablePool.sol"; // extends Pool but exposes ccipReceivePublic
import {MockV3Aggregator} from "lib/chainlink/contracts/src/v0.8/shared/mocks/MockV3Aggregator.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockRouter}   from "./MockRouter.sol";
import {InterestModel} from "../src/InterestModel.sol";

contract MockUSDT is ERC20{
    constructor() ERC20("Mock USDT", "mUSDT") {}
    function mint(address to, uint256 amount) external{
        _mint(to, amount);
    }
    function decimals() public pure override returns(uint8){
        return 6;
    }
}

contract PoolBranchTests is Test {
  TestablePool pool;
  MockUSDT     usdt;
  MockV3Aggregator ethUsd;
  MockV3Aggregator volFeed;
  MockRouter   router;

  address alice = address(0xA11CE);
  address bob   = address(0xB0B);

  bytes32 lockId1 = bytes32(uint256(1));
  bytes32 lockId2 = bytes32(uint256(2));

  function setUp() public {
    // deploy mocks
    usdt    = new MockUSDT();
    ethUsd  = new MockV3Aggregator(8, 2e11);   // $2000
    volFeed = new MockV3Aggregator(2, 6);      // 6% vol
    router  = new MockRouter();

    // deploy pool
    pool = new TestablePool(
      address(usdt),
      address(ethUsd),
      address(volFeed),
      address(router),
      /*ethChainSelector=*/ 1,
      /*vault=*/ address(0xDEAD)
    );

    // pre‐mint USDT to pool for liquidity
    usdt.mint(address(pool), 1_000_000e6);
  }

  // —— zero‐deposit and zero‐withdraw
  function testZeroDepositReverts() public {
    vm.expectRevert("Pool: zero deposit");
    pool.deposit(0);
  }
  function testZeroWithdrawReverts() public {
    vm.expectRevert("Pool: zero withdraw");
    pool.withdraw(0);
  }

  // —— stale price and stale vol

  function testStaleVolReverts() public {
    vm.warp(block.timestamp + 3601);
    vm.expectRevert("Pool: stale vol");
    pool.currentLTVBps();
  }

  // —— boundary LTV tiers
  function testLTVBoundaries() public {
    // vol = 4% → LTV = 8000
    volFeed.updateAnswer(int256(4 * 10**volFeed.decimals() / 100));
    assertEq(pool.currentLTVBps(), 8000);

    // vol = 8% → LTV = 6000
    volFeed.updateAnswer(int256(8 * 10**volFeed.decimals() / 100));
    assertEq(pool.currentLTVBps(), 6000);

    // vol = 11% → LTV = 5000
    volFeed.updateAnswer(int256(11 * 10**volFeed.decimals() / 100));
    assertEq(pool.currentLTVBps(), 5000);
  }

  // —— interest accrual path
  function testAccrueZeroDeltaIsNoOp() public {
    uint256 preTime   = pool.lastAccrual();
    uint256 preRes    = pool.totalReserves();
    uint256 preBorrows= pool.totalBorrows();
    pool.accrueInterest();
    assertEq(pool.lastAccrual(), preTime);
    assertEq(pool.totalReserves(), preRes);
    assertEq(pool.totalBorrows(), preBorrows);
  }
}
