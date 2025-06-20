// SPDX-License-Identifier: MIT
pragma solidity >=0.7.0 <0.9.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {InterestModel} from "./InterestModel.sol";
import { AggregatorV3Interface }  from "lib/chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import { CCIPReceiver }  from "lib/chainlink/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol" ;
import { Client } from "lib/chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "lib/chainlink/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";

/// @notice A lending pool: deposit USDC for LP, borrow/repay with utilization-based rates
contract Pool is ERC20("LP Token", "LPT"), CCIPReceiver {
    using InterestModel for uint256;

    /// @notice Underlying USDC token
    IERC20 public immutable usdc;

    /// chainlink feeda on Avalanche
    AggregatorV3Interface public immutable i_ethUsdFeed;
    AggregatorV3Interface public immutable i_volFeed;

     /// CCIP router client (inherited CCIPReceiver only handles incoming)
    IRouterClient public immutable ccipRouter;
    /// Chainlink CCIP selector for Ethereum Sepolia (example: 1)
    uint64 public immutable i_ethChainSelector;
    /// your Vault's address on Ethereum
    address public immutable i_ethVaultReceiver;

    /// @notice Total outstanding loans (principal + interest accrued)
    uint256 public totalBorrows;
    /// @notice Protocol’s reserve of fees
    uint256 public totalReserves;
    /// @notice Last timestamp when interest was accrued
    uint256 public lastAccrual;

    struct LockInfo {
        address user;
        uint256 amountWei;
    }

    /// @notice Per‐user debt balance (principal + their share of accrued interest)
    mapping(address => uint256) public debt;

    /// how much eth (in wei) each user has locked (populated via CCIP)
    mapping(address=> uint256) public collateralWei;

    
    // map th ethereum-side lockId -> (user, amountWei)
    mapping(bytes32 => LockInfo) public locks;
    mapping(address => bytes32) public userLocks; // in case if we need all the lockids locked by user

    /// @notice Reserve factor (portion of interest protocol keeps), e.g. 1000 = 10%
    uint256 public reserveFactorBps = 1_000;

    /// @notice Curve params (all in BPS: 10 000 = 100%)
    uint256 public baseBps   = 300;   // 3% base APR
    uint256 public slope1Bps = 1_500; // 15% slope until kink
    uint256 public slope2Bps = 3_000; // 30% slope after kink
    uint256 public kinkBps   = 8_000; // 80% utilization

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user,   uint256 amount);
    event MessageSent( bytes32 indexed messageId, uint64 indexed destChain, address receiver, address user);

    constructor(address _usdc, address _ethUsdFeed, address _volFeed, address router, uint64 _ethChainSelector, address i_ethVaultReceiver)  CCIPReceiver(router) {
        require(_usdc != address(0), "Pool: zero USDC");
        require(_ethUsdFeed != address(0), "Pool: zero USDC");
        require(_volFeed != address(0), "Pool: zerp vol feed");
        require(i_ethVaultReceiver!= address(0), "Pool: zero vault receiver");

        usdc = IERC20(_usdc);
        i_ethUsdFeed = AggregatorV3Interface(_ethUsdFeed);
        i_volFeed = AggregatorV3Interface(_volFeed);
        ccipRouter = IRouterClient(router);
        i_ethChainSelector = _ethChainSelector;
        i_ethVaultReceiver = i_ethVaultReceiver;
        lastAccrual = block.timestamp;
    }

    /// @notice CCIP hook - called by the Router when ethereum vault emits a lock 
    function _ccipReceive(Client.Any2EVMMessage memory msg_) internal override {
        //  decode the payload: (user, lockId, amountWei)
        (address user, bytes32 lockId, uint256 amountWei) = abi.decode(msg_.data, (address, bytes32, uint256));

        // store the lockId so we can refer back to it later
        locks[lockId] = LockInfo({user: user, amountWei: amountWei});  
        userLocks[user] = lockId;

        // record their collateral
        collateralWei[user] = amountWei;

         // auto-mint USDC by borrowing up to their LTV
        uint256 usdCol = collateralUsd(user);
        uint256 ltvBps = currentLTVBps();
        uint256 mintAmt = (usdCol * ltvBps) / 10_000;
    

    // increase debt & totalBorrows, then send USDC
    debt[user] += mintAmt;
    totalBorrows += mintAmt;
    usdc.transfer(user, mintAmt);
    emit Borrowed(user, mintAmt);
}

/// @notice Build and sends the ccip message to unlock on ethereum 
function _sendUnlockMessage(address user) internal {
    bytes32 lockId = userLocks[user];
    require(lockId != bytes32(0), "Pool: no lockId");

    // Pack user and lockId into the payload
    bytes memory data = abi.encode(user, lockId);

    Client.EVM2AnyMessage memory msg = Client.EVM2AnyMessage({
        receiver: abi.encode(i_ethVaultReceiver),
        data: data,
        tokenAmounts: new Client.EVMTokenAmount,
        extraArga: Client._argsToBytes(
            Client.GenericExtraArgsV2({
                gasLimit: 200_000,
                allowOutOfOrderExecution: true
            })
        ),
        feeToken: address(0)
    });

    // 1) query the fee in native AVAX
    uint256 fee = ccipRouter.getFee(i_ethChainSelector, msg);
    
    //2) send an dpay the fee
    bytes32 messageId = ccipRouter.ccipSend{value: fee}(i_ethChainSelector,msg);
    emit MessageSent(messageId, i_ethChainSelector, i_ethVaultReceiver, user);
}


    /// @notice called by your CCIp handler when the user locks eth on ethereum
    function setCollateral(address user, uint256 amountWei) external {
        // TODO: restrict this to only CCIP endpoint 
        collateralWei[user] = amountWei;
    }

    /// @notice Convert a user’s ETH (wei) → USD (6 decimals like USDC)
    function collateralUsd(address user) public view returns (uint256) {
        uint256 ethAmt = collateralWei[user];
        require(ethAmt > 0, "Pool: no collateral");

        (, int256 p,,,) = i_ethUsdFeed.latestRoundData();
        require(p > 0, "Pool: invalid price");

        // price has 8 decimals, ethAmt has 18 → (ethAmt * p) / 1e18 = USD with 8 decimals
        uint256 usd8 = (ethAmt * uint256(p)) / 1e18;
        // scale from 8 → 6 decimals
        return usd8 / 1e2;
    }

    /// @notice Dynamic LTV based on ETH volatility:
    ///  ≤5% → 80%, ≤10% → 60%, >10% → 50%
    function currentLTVBps() public view returns (uint256) {
        (, int256 rv,,,) = i_volFeed.latestRoundData();
        require(rv > 0, "Pool: bad vol");
        uint256 vol = uint256(rv);
        uint8   d   = i_volFeed.decimals();

        // thresholds
        uint256 th1 = (5  * 10**d) / 100;  // 5% of 1.0
        uint256 th2 = (10 * 10**d) / 100;  // 10% of 1.0

        if      (vol <= th1) return 8_000;  // 80%
        else if (vol <= th2) return 6_000;  // 60%
        else                  return 5_000;  // 50%
    }

    /// @notice Accrue interest on totalBorrows since lastAccrual
    function accrueInterest() public {
        uint256 nowTs = block.timestamp;
        uint256 delta = nowTs - lastAccrual;
        if (delta == 0) return;

        // 1. Compute current APR in BPS
        uint256 cash   = usdc.balanceOf(address(this));
        uint256 utr    = InterestModel.utilizationRate(cash, totalBorrows);
        uint256 aprBps = InterestModel.getBorrowRate(
            utr, baseBps, slope1Bps, slope2Bps, kinkBps
        );

        // 2. interest = totalBorrows * aprBps/10k * (delta / 1 year)
        uint256 interest = (totalBorrows * aprBps * delta) / (10_000 * 365 days);

        // 3. split fee vs. pool
        uint256 fee    = (interest * reserveFactorBps) / 10_000;
        uint256 toPool = interest - fee;

        totalReserves += fee;
        totalBorrows  += toPool;
        lastAccrual    = nowTs;
    }

    /// @notice Current borrow APR (in BPS)
    function borrowAPR() external view returns (uint256) {
        uint256 cash   = usdc.balanceOf(address(this));
        uint256 utr    = InterestModel.utilizationRate(cash, totalBorrows);
        return InterestModel.getBorrowRate(
            utr, baseBps, slope1Bps, slope2Bps, kinkBps
        );
    }

    /// @notice Current supply APR (in BPS)
    function supplyAPR() external view returns (uint256) {
        uint256 cash        = usdc.balanceOf(address(this));
        uint256 utr         = InterestModel.utilizationRate(cash, totalBorrows);
        uint256 borrowBps   = InterestModel.getBorrowRate(
            utr, baseBps, slope1Bps, slope2Bps, kinkBps
        );
        return InterestModel.getSupplyRate(
            utr, borrowBps, reserveFactorBps
        );
    }

    /// @notice Deposit USDC and mint LP tokens
    function deposit(uint256 amount) external {
        accrueInterest();
        require(amount > 0, "Pool: zero deposit");
        usdc.transferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, amount);
        emit Deposited(msg.sender, amount);
    }

    /// @notice Burn LP tokens and redeem USDC
    function withdraw(uint256 lpAmount) external {
        accrueInterest();
        require(lpAmount > 0, "Pool: zero withdraw");
        _burn(msg.sender, lpAmount);
        usdc.transfer(msg.sender, lpAmount);
        emit Withdrawn(msg.sender, lpAmount);
    }

    /// @notice Now enforces that (oldDebt+amount) <=collateralUsd * dynamicLTV%
    function borrow(uint256 amount) external {
        accrueInterest();
        require(amount > 0, "Pool: zero borrow");
        // TODO: enforce dynamic LTV or collateral check before this
        uint256 maxBorrow = (collateralUsd(msg.sender)* currentLTVBps()) / 10_000;
        require(debt[msg.sender] + amount <=maxBorrow, "Exceeds dynamic LTV");

        debt[msg.sender] += amount;
        totalBorrows     += amount;
        usdc.transfer(msg.sender, amount);
        emit Borrowed(msg.sender, amount);
    }

    /// @notice Repay USDC loan
    function repay(uint256 amount) external {
        accrueInterest();
        require(amount > 0, "Pool: zero repay");
        require(debt[msg.sender] >= amount, "Pool: overpay");
        usdc.transferFrom(msg.sender, address(this), amount);
        debt[msg.sender]   -= amount;
        totalBorrows      -= amount;
        emit Repaid(msg.sender, amount);

        // Send a CCIP message back to ethereum to unlock collateral
        _sendUnlockMessage(msg.sender);
    }
}
