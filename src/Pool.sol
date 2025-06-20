// SPDX-License-Identifier: MIT
pragma solidity >=0.7.0 <0.9.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {InterestModel} from "./InterestModel.sol";
import { AggregatorV3Interface }  from "lib/chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import { CCIPReceiver }  from "lib/chainlink/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol" ;
import { Client } from "lib/chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "lib/chainlink/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";

/// @notice A lending pool: deposit USDC for LP, borrow/repay with utilization-based rates
contract Pool is ERC20, CCIPReceiver, Ownable {
    using InterestModel for uint256;

    /// @notice Underlying USDT token on Avalanche
    IERC20 public immutable usdt;

    /// chainlink feeda on Avalanche
    AggregatorV3Interface public immutable i_ethUsdFeed;
    AggregatorV3Interface public immutable i_volFeed;

     /// CCIP router client (inherited CCIPReceiver only handles incoming)
    IRouterClient public immutable ccipRouter;
    modifier onlyCcipRouter() {
        require(msg.sender ==address(ccipRouter), "Pool: caller is not CCIP router");
        _;
    }

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

    //after 2 confirmations only mint function will be called, one by chainlink and other by backend
    mapping(bytes32 => mapping(address => mapping(uint256 => uint8))) public lockId_account_confirmations;

    /// @notice Once we hit 2 confirms, we mark the lock as verified
    mapping(bytes32 => bool) public lockVerified;

    // guard to ensure we only mint once per lockId
    mapping(bytes32 => bool) public isTxDone;

    /// @notice Reserve factor (portion of interest protocol keeps), e.g. 1000 = 10%
    uint256 public reserveFactorBps = 1_000;

    /// @notice Curve params (all in BPS: 10 000 = 100%)
    uint256 public baseBps   = 300;   // 3% base APR
    uint256 public slope1Bps = 1_500; // 15% slope until kink
    uint256 public slope2Bps = 3_000; // 30% slope after kink
    uint256 public kinkBps   = 8_000; // 80% utilization

    /// @notice Last CCIP message ID we saw
    bytes32 public s_lastReceivedMessageId;
    /// @notice Raw payload of the last CCIP message
    bytes  public s_lastReceivedData;

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount, uint256 rateBps, uint256 timestamp);
    event Repaid(address indexed user,   uint256 amount);
    event MessageReceived(bytes32 indexed messageId, uint64 indexed sourceChain, address sender, bytes data);
    event MessageSent( bytes32 indexed messageId, uint64 indexed destChain, address receiver, address user);

    constructor(address _usdt, address _ethUsdFeed, address _volFeed, address _router, uint64 _ethChainSelector, address _ethVaultReceiver)ERC20("LP Token", "LPT") CCIPReceiver(_router) Ownable(msg.sender) {
        require(_usdt != address(0), "Pool: zero USDC");
        require(_ethUsdFeed != address(0), "Pool: zero USDC");
        require(_volFeed != address(0), "Pool: zerp vol feed");
        require(i_ethVaultReceiver!= address(0), "Pool: zero vault receiver");

        usdt = IERC20(_usdt);
        i_ethUsdFeed = AggregatorV3Interface(_ethUsdFeed);
        i_volFeed = AggregatorV3Interface(_volFeed);
        ccipRouter = IRouterClient(_router);
        i_ethChainSelector = _ethChainSelector;
        i_ethVaultReceiver = _ethVaultReceiver;
        lastAccrual = block.timestamp;
    }

    /// @notice CCIP hook - called by the Router when ethereum vault emits a lock 
    function _ccipReceive(Client.Any2EVMMessage memory msg_) internal override onlyCcipRouter {

        emit MessageReceived(msg_.messageId, msg_.sourceChainSelector, abi.decode(msg_.sender,(address)), msg_.data);

        s_lastReceivedMessageId = msg_.messageId;
        s_lastReceivedData = msg_.data;

        //  decode the payload: (user, lockId, amountWei)
        (address user, bytes32 lockId, uint256 amountWei) = abi.decode(msg_.data, (address, bytes32, uint256));
        
        // store the lockId so we can refer back to it later
        locks[lockId] = LockInfo({user: user, amountWei: amountWei});  
        userLocks[user] = lockId;

        // record their collateral
        collateralWei[user] = amountWei;

        // step-1 of confirmation 
        uint8 count = lockId_account_confirmations[lockId][user][amountWei];
        if(count ==0){
            lockId_account_confirmations[lockId][user][amountWei] = 1;
        }
        else if(count ==1){
            lockId_account_confirmations[lockId][user][amountWei] = 2;
            lockVerified[lockId] = true;
        }
}
// backend confirmation
function backendConfirmation(address user, bytes32 lockId, uint256 amountWei) external onlyOwner {
    uint8 count = lockId_account_confirmations[lockId][user][amountWei];
    if(count == 0){
        lockId_account_confirmations[lockId][user][amountWei] = 1;
    }
    else if(count ==1){
            lockId_account_confirmations[lockId][user][amountWei] = 2;
            lockVerified[lockId] = true;
    }
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
    function setCollateral(address user, uint256 amountWei) external onlyCcipRouter{
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
        uint256 cash   = usdt.balanceOf(address(this));
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
    function borrowAPR() public view returns (uint256) {
        uint256 cash   = usdt.balanceOf(address(this));
        uint256 utr    = InterestModel.utilizationRate(cash, totalBorrows);
        return InterestModel.getBorrowRate(
            utr, baseBps, slope1Bps, slope2Bps, kinkBps
        );
    }

    /// @notice Current supply APR (in BPS)
    function supplyAPR() public view returns (uint256) {
        uint256 cash        = usdt.balanceOf(address(this));
        uint256 utr         = InterestModel.utilizationRate(cash, totalBorrows);
        uint256 borrowBps   = InterestModel.getBorrowRate(
            utr, baseBps, slope1Bps, slope2Bps, kinkBps
        );
        return InterestModel.getSupplyRate(
            utr, borrowBps, reserveFactorBps
        );
    }

    // ========== Deposit & Withdraw ==========
    /// @notice Returns current USDT in the pool
    function totalAssets() public view returns (uint256) {
        return usdt.balanceOf(address(this));
    }

    /// @notice Deposit USDT and mint LP shares
    function deposit(uint256 amount) external {
        accrueInterest();
        require(amount > 0, "Pool: zero deposit");


       usdt.transferFrom(msg.sender, address(this), amount);

        uint256 assetsBefore = totalAssets() - amount;
        uint256 supply       = totalSupply();
        uint256 shares;
        if (supply == 0 || assetsBefore == 0) {
            shares = amount;
        } else {
            shares = (amount * supply) / assetsBefore;
        }

        _mint(msg.sender, shares);
        emit Deposited(msg.sender, amount);
    }

    /// @notice Burn LP shares and redeem USDT
    function withdraw(uint256 shareAmount) external {
        accrueInterest();
        require(shareAmount > 0, "Pool: zero withdraw");

        uint256 supply    = totalSupply();
        uint256 assets    = totalAssets();
        uint256 amountOut = (shareAmount * assets) / supply;

        _burn(msg.sender, shareAmount);

       usdt.transfer(msg.sender, amountOut);

        emit Withdrawn(msg.sender, amountOut);
    }

    // ========== Borrow & Repay ==========
    function borrowWithLock(bytes32 lockId, uint256 amount) external {
        require(lockVerified[lockId], "Pool: lock not confirmed");
        LockInfo memory info = locks[lockId];
        require(info.user == msg.sender, "Pool: not lock owner");

        uint256 maxBorrow = (collateralUsd(msg.sender) * currentLTVBps()) / 10_000;
        require(amount > 0, "Pool: zero borrow");
        require(debt[msg.sender] + amount <= maxBorrow, "Pool: exceeds dynamic LTV");

        accrueInterest();
        uint256 rateNow = borrowAPR();
        debt[msg.sender] += amount;
        totalBorrows    += amount;

        usdt.transfer(msg.sender, amount, rateNow, block.timestamp);

        emit Borrowed(msg.sender, amount);
    }

    

    function repay(uint256 amount) external {
        accrueInterest();
        require(amount > 0, "Pool: zero repay");
        require(debt[msg.sender] >= amount, "Pool: overpay");


       usdt.transferFrom(msg.sender, address(this), amount);

        debt[msg.sender]  -= amount;
        totalBorrows     -= amount;
        emit Repaid(msg.sender, amount);

        _sendUnlockMessage(msg.sender);
    }

        //=========OWNER-ONLY SETTERS ===
    
    function setReserveFactor(uint256 newBps) external onlyOwner {
        require(newBps <= 10_000, "Pool: invalid BPS");
        reserveFactorBps = newBps;
    }

    function setCurveParams(uint256 _baseBps, uint256 _slope1Bps, uint256 _slope2Bps, uint256 _kinkBps) external onlyOwner{
        require(_baseBps <= 10_000, "bad base");
        require(_slope1Bps <= 50_000, "bad slope1");
        require(_slope2Bps <= 100_000, "bad slope2");
        require(_kinkBps <= 10_000, "bad kink");
        baseBps = _baseBps;
        slope1Bps = _slope1Bps;
        slope2Bps = _slope2Bps;
        kinkBps = _kinkBps;
    }

    function setFeeds(address _ethUsdFeed, address _volFeed) external onlyOwner {
        require(_ethUsdFeed != address(0) && _volFeed != address(0), "Pool: zero feed");
        i_ethUsdFeed = AggregatorV3Interface(_ethUsdFeed);
        i_volFeed = AggregatorV3Interface(_volFeed);
    }

}
