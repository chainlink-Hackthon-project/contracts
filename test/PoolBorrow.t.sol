// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import {Test, console} from "forge-std/Test.sol";
import { Pool } from "../src/Pool.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockV3Aggregator} from "lib/chainlink/contracts/src/v0.8/shared/mocks/MockV3Aggregator.sol";
import {Client} from "lib/chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";
import {MockRouter} from "./MockRouter.sol";


contract MockUSDT is ERC20{
    constructor() ERC20("Mock USDT", "mUSDT") {
        _mint(msg.sender, 1_000_000e6);
    }
    function decimals() public pure override returns(uint8){
        return 6;
    }
}

/// @notice Expose the internal CCIPReceiver hook so tests can call it
contract TestablePool is Pool {
  constructor(
    address _usdt,
    address _ethUsdFeed,
    address _volFeed,
    address _router,
    uint64  _ethChainSelector,
    address _ethVaultReceiver
  ) Pool(
    _usdt, _ethUsdFeed, _volFeed, _router, _ethChainSelector, _ethVaultReceiver
  ) {}

function ccipReceivePublic(Client.Any2EVMMessage memory msg_) external {
    _ccipReceive(msg_);
  }
}

contract PoolBorrowTest is Test {
  MockUSDT            public usdt;
  MockV3Aggregator    public priceFeed;
  MockV3Aggregator    public volFeed;
  TestablePool        public pool;
  address             public alice = address(0xA11CE);
  bytes32             public lockId;
  uint256             public amountWei = 1e18; // 1 ETH


  function setUp() public {
    // 1. Deploy mocks
    usdt      = new MockUSDT();
    MockRouter router = new MockRouter();
    priceFeed = new MockV3Aggregator(8, 2_000 * 10**8);  // $2000
    volFeed   = new MockV3Aggregator(18, 2 * 10**17);    // 0.2 = 20% vol

    // 2. Give Alice some USDT so pool can lend it back
    usdt.transfer(alice, 10_000e6);

    // 3. Deploy Pool (use this contract as CCIP router stub)
    pool = new TestablePool(
      address(usdt),
      address(priceFeed),
      address(volFeed),
      address(router),
      1,                // dummy chain selector
      address(0x123)    // dummy Ethereum vault
    );

    // 4. Alice & pool approve
    vm.prank(alice);
    usdt.approve(address(pool), type(uint256).max);
    // Fund pool so it has liquidity to lend
    usdt.transfer(address(pool), 5_000e6);

    // 5. Precompute a lockId
    lockId = keccak256(abi.encodePacked("alice-lock"));

    // 6. Simulate CCIP on‐chain confirmation step
    Client.Any2EVMMessage memory ccipMsg = Client.Any2EVMMessage({
      messageId:          lockId,
      sourceChainSelector: 1,
      sender:             abi.encode(address(0x999)),
      data:               abi.encode(alice, lockId, amountWei),
      destTokenAmounts: new Client.EVMTokenAmount[](0)
    });
    vm.prank(address(router));
    pool.ccipReceivePublic(ccipMsg);

    // 7. Simulate off‐chain backend confirmation
    pool.backendConfirmation(alice, lockId, amountWei);
  }

  /// @notice Now the lock is fully verified; Alice should be able to borrow up to LTV
  function testBorrowWithLockSucceeds() public {
    // collateralUsd = (1e18 * 2000e8)/1e18/1e2 = 2000e6 USDT; vol=20% → LTV=50%
    // maxBorrow = 2000e6 * 5000 / 10000 = 1000e6 USDT
    uint256 maxBorrow = (2000e6 * 5_000) / 10_000;

    vm.prank(alice);
    pool.borrowWithLock(lockId, maxBorrow);

    assertEq(pool.debt(alice), maxBorrow, "debt updated");
    assertEq(usdt.balanceOf(alice), 10_000e6 + maxBorrow, "Alice got USDT"); 
    assertTrue(pool.isTxDone(lockId), "lock marked used");
  }

  /// @notice Cannot borrow more than dynamic LTV
  function testBorrowExceedsLTVReverts() public {
    uint256 tooMuch = 1_001e6;
    vm.prank(alice);
    vm.expectRevert("Pool: exceeds LTV");
    pool.borrowWithLock(lockId, tooMuch);
  }

  /// @notice Cannot reuse the same lockId twice
  function testDoubleBorrowReverts() public {
    vm.prank(alice);
    pool.borrowWithLock(lockId, 500e6);
    vm.prank(alice);
    vm.expectRevert("Pool: lock already used");
    pool.borrowWithLock(lockId, 100e6);
  }

  /// @notice Cannot borrow more than the pool’s USDT balance
  function testBorrowInsufficientLiquidityReverts() public {
    // pool only funded with 5000 USDT, Alice tries 6000
    vm.prank(alice);
    vm.expectRevert("Pool: insufficient liquidity");
    pool.borrowWithLock(lockId, 6_000e6);
  }

  /// @notice Partial repay reduces debt but does NOT unlock
  function testPartialRepay() public {
    vm.prank(alice);
    pool.borrowWithLock(lockId, 500e6);
    vm.prank(alice);
    pool.repay(200e6);

    assertEq(pool.debt(alice), 300e6);
    // lock should still be verified
    assertTrue(pool.lockVerified(lockId));
  }

  /// @notice Full repay zeroes debt and clears lock
  function testFullRepayClearsLock() public {
    vm.prank(alice);
    pool.borrowWithLock(lockId, 500e6);

    vm.prank(alice);
    pool.repay(500e6);

    assertEq(pool.debt(alice), 0);
    assertFalse(pool.lockVerified(lockId), "lockVerified cleared");
    assertEq(pool.userLocks(alice), bytes32(0), "userLocks cleared");
  }
}
