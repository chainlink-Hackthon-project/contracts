// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";
import {MockV3Aggregator} from "lib/chainlink/contracts/src/v0.8/shared/mocks/MockV3Aggregator.sol";
import {Client} from "lib/chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IRouterClient}          from "lib/chainlink/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {MockRouter} from "./MockRouter.sol";
import { TestablePool } from "./TestablePool.sol";
import { Pool } from "../src/Pool.sol";





contract MockUSDT is ERC20{
    constructor() ERC20("Mock USDT", "mUSDT") {
        _mint(msg.sender, 1_000_000e6);
    }
    function decimals() public pure override returns(uint8){
        return 6;
    }
}

contract PoolLiquidationTest is Test {
  MockUSDT        usdt;
  MockV3Aggregator priceFeed;
  MockV3Aggregator volFeed;
  MockRouter      router;
  TestablePool    pool;
  
  address constant ETH_VAULT = address(0x123);
  address alice    = address(0xA11CE);
  address liquidator = address(0xB0B);

  bytes32 lockId;
  uint256 amountWei = 1 ether;

  function setUp() public {
    // 1) Deploy mocks
    usdt      = new MockUSDT();
    priceFeed = new MockV3Aggregator(8, 2_000 * 10**8);  // $2000
    volFeed   = new MockV3Aggregator(18, 2 * 10**17);    // 20% vol → LTV = 50%
    router    = new MockRouter();

    // 2) Give Alice some USDT & fund the pool
    usdt.transfer(alice, 10_000e6);
    usdt.transfer(address(this), 10_000e6);
    vm.prank(address(this));
    usdt.approve(address(this), type(uint256).max);

    // 3) Deploy Pool
    pool = new TestablePool(
      address(usdt),
      address(priceFeed),
      address(volFeed),
      address(router),
      1,
      ETH_VAULT
    );

    // 4) Alice approves & pool gets USDT liquidity
    vm.prank(alice);
    usdt.approve(address(pool), type(uint256).max);
    usdt.transfer(address(pool), 5_000e6);

    // fund and approve the liquidatoe(bob)
    usdt.transfer(liquidator, 10_1000e6);
    vm.prank(liquidator);
    usdt.approve(address(pool), type(uint256).max);

    // 5) Precompute lockId and simulate CCIP + backend confirms
    lockId = keccak256(abi.encodePacked("alice-lock"));
    Client.Any2EVMMessage memory ccipMsg = Client.Any2EVMMessage({
      messageId:           lockId,
      sourceChainSelector: 1,
      sender:              abi.encode(address(0x999)),
      data:                abi.encode(alice, lockId, amountWei),
      destTokenAmounts:    new Client.EVMTokenAmount[](0)
    });
    // first on‐chain confirmation
    vm.prank(address(router));
    pool.ccipReceivePublic(ccipMsg);
    // second, backend
    pool.backendConfirmation(alice, lockId, amountWei);

    // 6) Borrow at the *initial* LTV (vol=0.2 → LTV=50%): collateralUsd = $2000 → maxBorrow = 1000 USDT
    vm.prank(alice);
    pool.borrowWithLock(lockId, 1_000e6);
  }



  function testCannotLiquidateHealthy() public {
    // after borrow, debt=1000, collateralUsd=2000 → LTV=50%, threshold=50% → still healthy
    vm.prank(liquidator);
    vm.expectRevert("Pool: healthy");
    pool.liquidate(lockId, 100e6);
  }





  function testLiquidationSeizesCollateral() public {
        // 1) Drop ETH price to $1000 → debt/collateral = 100% >50% → unhealthy
        priceFeed.updateAnswer(int256(1_000 * 10**8));

        // 2) Calculate how much the liquidator may repay
        uint256 repay     = (pool.debt(alice) * pool.closeFactorBps()) / 10_000;
        uint256 seizeUsd6 = (repay * pool.liquidationBonusBps()) / 10_000;
        uint256 seizeWei  = (seizeUsd6 * 1e20) / uint256(1_000 * 10**8);

        // 3) Expect CCIP unlock message


        // 4) Expect LiquidationExecuted(...)

        // 5) Run liquidation
        vm.startPrank(liquidator);
        usdt.approve(address(pool), repay);
        pool.liquidate(lockId, repay);
        vm.stopPrank();

        // 6) State assertions
        assertEq(pool.debt(alice), 1_000e6 - repay,    "debt reduced");
        assertEq(pool.collateralWei(alice), amountWei - seizeWei, "collateral seized");
    }
}