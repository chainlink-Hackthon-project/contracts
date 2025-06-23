// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

// ─────────────────────────────────────────────────────────────────────────────
//                             EXTERNAL DEPENDENCIES
// ─────────────────────────────────────────────────────────────────────────────

import {ERC20}                  from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20}                 from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable}                from "@openzeppelin/contracts/access/Ownable.sol";
import {AggregatorV3Interface}  from "lib/chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {CCIPReceiver}           from "lib/chainlink/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {Client}                 from "lib/chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient}          from "lib/chainlink/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";

import {InterestModel}          from "./InterestModel.sol";

// ─────────────────────────────────────────────────────────────────────────────
//                               CONTRACT HEADER
// ─────────────────────────────────────────────────────────────────────────────

/**
 * @title  Cross-Chain Lending Pool
 * @notice Users lock ETH on Ethereum → borrow USDT on Avalanche, repay → unlock.
 *         Lenders deposit USDT for LP shares and earn utilization-based interest.
 *         Includes dynamic LTV (via Chainlink Volatility), kinked APR curve,
 *         CCIP dual-confirmation, and on-chain liquidation.
 */
contract Pool is ERC20, CCIPReceiver, Ownable {
    using InterestModel for uint256;

    // ─────────────────────────────────────────────────────────────────────────
    //                               STATE VARIABLES
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Underlying USDT token on Avalanche
    IERC20 public immutable usdt;

    /// @notice Chainlink ETH/USD price feed (8 decimals)
    AggregatorV3Interface public immutable i_ethUsdFeed;
    /// @notice Chainlink ETH volatility feed (decimals vary)
    AggregatorV3Interface public immutable i_volFeed;

    /// @notice Chainlink CCIP router (for cross-chain messages)
    IRouterClient public immutable ccipRouter;
    modifier onlyCcipRouter() {
        require(msg.sender == address(ccipRouter), "Pool: caller not CCIP router");
        _;
    }

    /// @notice CCIP selector for Ethereum Sepolia
    uint64 public immutable i_ethChainSelector;
    /// @notice Address of the Vault contract on Ethereum to receive messages
    address public immutable i_ethVaultReceiver;

    /// @notice Total outstanding loans (principal + accrued interest)
    uint256 public totalBorrows;
    /// @notice Protocol’s accumulated interest reserves
    uint256 public totalReserves;
    /// @notice Last timestamp when interest was accrued
    uint256 public lastAccrual;

    /// @notice Mapping of user → their current USDT debt
    mapping(address => uint256) public debt;
    /// @notice Mapping of user → amount of ETH-wei they locked (via CCIP)
    mapping(address => uint256) public collateralWei;

    /// @notice Details for each cross-chain lock
    struct LockInfo {
        address user;
        uint256 amountWei;
    }
    /// @notice lockId → LockInfo
    mapping(bytes32 => LockInfo) public locks;
    /// @notice user → latest lockId (for unlocks)
    mapping(address => bytes32) public userLocks;

    /// @notice CCIP + backend confirmation counts: [lockId][user][amount] → 0,1,2
    mapping(bytes32 => mapping(address => mapping(uint256 => uint8)))
        public lockConfirmations;
    /// @notice Whether a lockId has been fully confirmed (2/2)
    mapping(bytes32 => bool) public lockVerified;
    /// @notice Prevent double‐use of the same lockId
    mapping(bytes32 => bool) public isTxDone;

    /// @notice Reserve factor (e.g. 1000 = 10%) of interest that the protocol keeps
    uint256 public reserveFactorBps = 1_000;

    /// @notice Interest-rate curve parameters (BPS)
    uint256 public baseBps   =   300;  //  3% base APR
    uint256 public slope1Bps = 1_500;  // 15% APR slope before kink
    uint256 public slope2Bps = 3_000;  // 30% APR slope after kink
    uint256 public kinkBps   = 8_000;  // 80% utilization

    /// @notice Liquidation parameters
    uint256 public closeFactorBps      = 5_000;   // max repay = 50% of debt
    uint256 public liquidationBonusBps = 10_500;  // 105% seize (5% bonus)

    /// @notice For observability: last raw CCIP message
    bytes32 public s_lastReceivedMessageId;
    bytes   public s_lastReceivedData;

    // ─────────────────────────────────────────────────────────────────────────
    //                                    EVENTS
    // ─────────────────────────────────────────────────────────────────────────

    event Deposited(address indexed user, uint256 amount, uint256 shares);
    event Withdrawn(address indexed user, uint256 amount, uint256 shares);
    event Borrowed(
      address indexed user,
      uint256 amount,
      uint256 rateBps,
      uint256 timestamp
    );
    event Repaid(address indexed user, uint256 amount);

    event MessageReceived(
      bytes32 indexed messageId,
      uint64  indexed sourceChain,
      address          sender,
      bytes            data
    );
    event MessageSent(
      bytes32 indexed messageId,
      uint64  indexed destChain,
      address          receiver,
      address          user
    );

    event InterestAccrued(uint256 interest, uint256 fee, uint256 timestamp);
    event LiquidationExecuted(
      bytes32 indexed lockId,
      address indexed liquidator,
      uint256 repayAmount,
      uint256 seizedWei
    );

    // ─────────────────────────────────────────────────────────────────────────
    //                                CONSTRUCTOR
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @param _usdt              Address of the USDT token on Avalanche
     * @param _ethUsdFeed        Chainlink ETH/USD feed proxy
     * @param _volFeed           Chainlink ETH volatility feed proxy
     * @param _router            CCIP router address on Avalanche
     * @param _ethChainSelector  CCIP chain selector for Ethereum
     * @param _ethVaultReceiver  Address of Vault on Ethereum to unlock/seize
     */
    constructor(
        address _usdt,
        address _ethUsdFeed,
        address _volFeed,
        address _router,
        uint64  _ethChainSelector,
        address _ethVaultReceiver
    )
        ERC20("LP Token", "LPT")
        CCIPReceiver(_router)
        Ownable(msg.sender)
    {
        require(_usdt             != address(0), "Pool: zero USDT");
        require(_ethUsdFeed       != address(0), "Pool: zero price feed");
        require(_volFeed          != address(0), "Pool: zero vol feed");
        require(_ethVaultReceiver != address(0), "Pool: zero vault");

        usdt               = IERC20(_usdt);
        i_ethUsdFeed       = AggregatorV3Interface(_ethUsdFeed);
        i_volFeed          = AggregatorV3Interface(_volFeed);
        ccipRouter         = IRouterClient(_router);
        i_ethChainSelector = _ethChainSelector;
        i_ethVaultReceiver = _ethVaultReceiver;
        lastAccrual        = block.timestamp;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //                          CROSS-CHAIN LOCK HANDLING
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @dev CCIP hook invoked by the router when ETH is locked on Ethereum.
     *      We do a two-step confirmation before marking lockVerified.
     */
    function _ccipReceive(Client.Any2EVMMessage memory msg_)
        internal override onlyCcipRouter
    {
        // 1) Log the raw message for indexing
        emit MessageReceived(
            msg_.messageId,
            msg_.sourceChainSelector,
            abi.decode(msg_.sender, (address)),
            msg_.data
        );
        s_lastReceivedMessageId = msg_.messageId;
        s_lastReceivedData      = msg_.data;

        // 2) Decode (user, lockId, amountWei)
        (address user, bytes32 lockId, uint256 amountWei) =
            abi.decode(msg_.data, (address, bytes32, uint256));

        // 3) If already verified, skip
        if (lockVerified[lockId]) return;

        // 4) Record lock info
        locks[lockId]       = LockInfo(user, amountWei);
        userLocks[user]     = lockId;
        collateralWei[user] = amountWei;

        // 5) Two-step confirmation
        uint8 count = lockConfirmations[lockId][user][amountWei];
        if (count == 0) {
            lockConfirmations[lockId][user][amountWei] = 1;
        } else if (count == 1) {
            lockConfirmations[lockId][user][amountWei] = 2;
            lockVerified[lockId] = true;
        }
    }

    /**
     * @notice Second confirmation from your off-chain backend.
     * @dev Only the owner (your backend key) may call this.
     */
    function backendConfirmation(
        address user,
        bytes32 lockId,
        uint256 amountWei
    )
        external onlyOwner
    {
        // Validate against stored lock
        LockInfo memory info = locks[lockId];
        require(info.user == user, "BC: wrong user");
        require(info.amountWei == amountWei,  "BC: wrong amount");

        // Skip if already done
        if (lockVerified[lockId]) return;

        // Bump to 2 → verified
        uint8 cnt = lockConfirmations[lockId][user][amountWei];
        if (cnt == 0) {
            lockConfirmations[lockId][user][amountWei] = 1;
        } else if (cnt == 1) {
            lockConfirmations[lockId][user][amountWei] = 2;
            lockVerified[lockId] = true;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    //                              PRICE & LTV HELPERS
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Convert a user’s ETH collateral (wei) → USD with 6 decimals
    function collateralUsd(address user) public view returns (uint256) {
        uint256 ethAmt = collateralWei[user];
        require(ethAmt > 0, "Pool: no collateral");

        ( , int256 p, , uint256 updatedAt, ) = i_ethUsdFeed.latestRoundData();
        require(p > 0, "Pool: bad price");
        require(block.timestamp - updatedAt < 1 hours, "Pool: stale price");

        // (ethAmt * price) has 18 + 8 decimals → divide by 1e18 → 8 decimals
        uint256 usd8 = (ethAmt * uint256(p)) / 1e18;
        // scale from 8 → 6 decimals
        return usd8 / 1e2;
    }

    /// @notice Dynamic LTV based on ETH volatility: ≤5%→80%, ≤10%→60%, else 50%
    function currentLTVBps() public view returns (uint256) {
        ( , int256 rv, , uint256 updatedAt, ) = i_volFeed.latestRoundData();
        require(rv > 0, "Pool: bad vol");
        require(block.timestamp - updatedAt < 1 hours, "Pool: stale vol");

        uint256 vol = uint256(rv);
        uint8   d   = i_volFeed.decimals();
        uint256 th1 = (5  * 10**d) / 100; // 5%
        uint256 th2 = (10 * 10**d) / 100; // 10%

        if (vol <= th1) return 8_000;
        else if (vol <= th2) return 6_000;
        else return 5_000;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //                            INTEREST RATE MODEL
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Accrue interest since `lastAccrual`, split fees into reserves.
    function accrueInterest() public {
        uint256 nowTs = block.timestamp;
        uint256 delta = nowTs - lastAccrual;
        if (delta == 0) return;

        uint256 cash    = usdt.balanceOf(address(this));
        uint256 utr     = InterestModel.utilizationRate(cash, totalBorrows);
        uint256 aprBps  = InterestModel.getBorrowRate(
            utr, baseBps, slope1Bps, slope2Bps, kinkBps
        );

        // interest = totalBorrows * APRbps/10k * (delta / 365 days)
        uint256 interest = (totalBorrows * aprBps * delta) /
                           (InterestModel.BPS * 365 days);

        uint256 fee    = (interest * reserveFactorBps) / InterestModel.BPS;
        uint256 toPool = interest - fee;

        totalReserves += fee;
        totalBorrows  += toPool;
        lastAccrual    = nowTs;

        emit InterestAccrued(interest, fee, nowTs);
    }

    /// @notice Current borrow APR, in basis-points (BPS)
    function borrowAPR() public view returns (uint256) {
        uint256 cash   = usdt.balanceOf(address(this));
        uint256 utr    = InterestModel.utilizationRate(cash, totalBorrows);
        return InterestModel.getBorrowRate(
            utr, baseBps, slope1Bps, slope2Bps, kinkBps
        );
    }

    /// @notice Current supply APR for depositors, in basis-points
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

    // ─────────────────────────────────────────────────────────────────────────
    //                              DEPOSITS & WITHDRAWALS
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Returns total USDT in the pool
    function totalAssets() public view returns (uint256) {
        return usdt.balanceOf(address(this));
    }

    /**
     * @notice Deposit USDT and receive LP shares that accrue interest.
     * @param amount  Amount of USDT to deposit
     */
    function deposit(uint256 amount) external {
        accrueInterest();
        require(amount > 0, "Pool: zero deposit");

        usdt.transferFrom(msg.sender, address(this), amount);

        uint256 before   = totalAssets() - amount;
        uint256 supply   = totalSupply();
        uint256 shares   = supply == 0 || before == 0 ? amount : (amount * supply) / before;

        _mint(msg.sender, shares);
        emit Deposited(msg.sender, amount, shares);
    }

    /**
     * @notice Burn LP shares and redeem underlying USDT pro-rata.
     * @param shareAmount  Number of LP shares to burn
     */
    function withdraw(uint256 shareAmount) external {
        accrueInterest();
        require(shareAmount > 0, "Pool: zero withdraw");

        uint256 supply    = totalSupply();
        uint256 assets    = totalAssets();
        uint256 amountOut = (shareAmount * assets) / supply;
        require(amountOut > 0, "Pool: zero output");

        _burn(msg.sender, shareAmount);
        usdt.transfer(msg.sender, amountOut);

        emit Withdrawn(msg.sender, amountOut, shareAmount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //                              BORROW & REPAY
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Borrow USDT against a verified ETH lock. Must be called once per lock.
     * @param lockId  Cross-chain lock identifier
     * @param amount  Amount of USDT to borrow (≤ dynamic LTV)
     */
    function borrowWithLock(bytes32 lockId, uint256 amount) external {
        require(lockVerified[lockId], "Pool: lock not confirmed");
        require(!isTxDone[lockId], "Pool: lock already used");
        isTxDone[lockId] = true;

        LockInfo memory info = locks[lockId];
        require(info.user == msg.sender, "Pool: not lock owner");

        accrueInterest();

        uint256 maxBorrow = (collateralUsd(msg.sender) * currentLTVBps()) / 10_000;
        require(amount > 0, "Pool: zero borrow");
        require(debt[msg.sender] + amount <= maxBorrow,  "Pool: exceeds LTV");
        require(usdt.balanceOf(address(this)) >= amount, "Pool: insufficient liquidity");

        uint256 rateNow = borrowAPR();
        debt[msg.sender] += amount;
        totalBorrows += amount;

        usdt.transfer(msg.sender, amount);
        emit Borrowed(msg.sender, amount, rateNow, block.timestamp);
    }

    /**
     * @notice Repay borrowed USDT. On full repayment, triggers an ETH unlock back on Ethereum.
     * @param amount  Amount of USDT to repay
     */
    function repay(uint256 amount) external {
        accrueInterest();
        require(amount > 0, "Pool: zero repay");
        require(debt[msg.sender] >= amount, "Pool: overpay");

        usdt.transferFrom(msg.sender, address(this), amount);

        debt[msg.sender]  -= amount;
        totalBorrows      -= amount;
        emit Repaid(msg.sender, amount);

        // If fully repaid, clear lock and send unlock message
        if (debt[msg.sender] == 0) {
            bytes32 lockId = userLocks[msg.sender];
            require(lockId != bytes32(0), "Pool: no lock to unlock");

            lockVerified[lockId]    = false;
            userLocks[msg.sender]   = bytes32(0);
            collateralWei[msg.sender] = 0;

            _sendUnlockMessage(msg.sender);
        }
    }

    /**
 * @dev Once a user’s debt hits zero, call this to instruct your Ethereum Vault
 *      to release the ETH collateral.
 * @param user The borrower who has fully repaid
 * @return messageId The CCIP message ID
 */
function _sendUnlockMessage(address user) internal returns (bytes32 messageId) {
    // Fetch their lockId
    bytes32 lockId = userLocks[user];
    require(lockId != bytes32(0), "Pool: no lock to unlock");

    // Payload = (user, lockId)
    bytes memory data = abi.encode(user, lockId);

    // Build CCIP message
    Client.EVM2AnyMessage memory ccipMsg = Client.EVM2AnyMessage({
        receiver:     abi.encode(i_ethVaultReceiver),
        data:         data,
        tokenAmounts: new Client.EVMTokenAmount[](0),
        extraArgs:    Client._argsToBytes(
                          Client.GenericExtraArgsV2({
                              gasLimit:                 200_000,
                              allowOutOfOrderExecution: true
                          })
                      ),
        feeToken:     address(0)
    });

    // Query native AVAX fee and ensure we can pay it
    uint256 fee = ccipRouter.getFee(i_ethChainSelector, ccipMsg);
    require(address(this).balance >= fee, "Pool: insufficient AVAX");

    // Send and emit
    messageId = ccipRouter.ccipSend{ value: fee }(
      i_ethChainSelector,
      ccipMsg
    );
    emit MessageSent(messageId, i_ethChainSelector, i_ethVaultReceiver, user);
}

    // ─────────────────────────────────────────────────────────────────────────
    //                              LIQUIDATION LOGIC
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Liquidate an under-collateralized position.
     * @param lockId      Cross-chain lock identifier
     * @param repayAmount Amount of USDT the liquidator repays on behalf of borrower
     */
    function liquidate(bytes32 lockId, uint256 repayAmount) external {
        accrueInterest();

        // --- 1) position sanity ---
        LockInfo storage info = locks[lockId];
        require(info.user != address(0), "Pool: unknown lock");

        // --- 2) health factor check (debt / collateral) ---
        uint256 userDebt    = debt[info.user];
        uint256 collateral  = collateralUsd(info.user);
        uint256 currentLTV  = (userDebt * 10_000) / collateral;
        require(currentLTV > currentLTVBps(), "Pool: healthy");

        // --- 3) close factor (max repay) ---
        uint256 maxRepay = (userDebt * closeFactorBps) / 10_000;
        require(repayAmount > 0 && repayAmount <= maxRepay, "Pool: repay too big");

        // --- 4) pull USDT and reduce debt ---
        usdt.transferFrom(msg.sender, address(this), repayAmount);
        debt[info.user]   = userDebt - repayAmount;
        totalBorrows     -= repayAmount;
        emit Repaid(info.user, repayAmount);

        // --- 5) compute and remove collateral (with bonus) ---
        uint256 seizeUsd6 = (repayAmount * liquidationBonusBps) / 10_000;
        (, int256 price8,,,) = i_ethUsdFeed.latestRoundData();
        require(price8 > 0, "Pool: bad price");
        uint256 seizeWei = (seizeUsd6 * 1e20) / uint256(price8);

        require(collateralWei[info.user] >= seizeWei, "Pool: not enough collateral");
        collateralWei[info.user] -= seizeWei;

        // --- 6) notify Ethereum vault to actually transfer ETH to liquidator ---
        _sendLiquidateMessage(lockId, info.user, msg.sender, seizeWei);

        emit LiquidationExecuted(lockId, msg.sender, repayAmount, seizeWei);
    }

    /**
     * @dev Internal helper to send a CCIP “liquidate” message back to Ethereum.
     */
    function _sendLiquidateMessage(
        bytes32 lockId,
        address borrower,
        address liquidator,
        uint256 amountWei
    ) internal {
        bytes memory data = abi.encode(lockId, liquidator, amountWei);
        Client.EVM2AnyMessage memory ccipMsg = Client.EVM2AnyMessage({
            receiver:     abi.encode(i_ethVaultReceiver),
            data:         data,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs:    Client._argsToBytes(
                              Client.GenericExtraArgsV2({
                                  gasLimit:                 200_000,
                                  allowOutOfOrderExecution: true
                              })
                          ),
            feeToken:     address(0)
        });

        uint256 fee = ccipRouter.getFee(i_ethChainSelector, ccipMsg);
        require(address(this).balance >= fee, "Pool: insufficient AVAX");

        bytes32 messageId = ccipRouter.ccipSend{ value: fee }(
            i_ethChainSelector,
            ccipMsg
        );
        emit MessageSent(messageId, i_ethChainSelector, i_ethVaultReceiver, borrower);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //                              ADMIN FUNCTIONS
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Adjust the protocol’s reserve factor (max 10000 BPS = 100%)
    function setReserveFactor(uint256 newBps) external onlyOwner {
        require(newBps <= InterestModel.BPS, "Pool: invalid BPS");
        reserveFactorBps = newBps;
    }

    /// @notice Adjust the kinked APR curve parameters
    function setCurveParams(
        uint256 _baseBps,
        uint256 _slope1Bps,
        uint256 _slope2Bps,
        uint256 _kinkBps
    ) external onlyOwner {
        require(_baseBps   <= InterestModel.BPS,       "bad base");
        require(_slope1Bps <= 5 * InterestModel.BPS,   "bad slope1");
        require(_slope2Bps <= 10 * InterestModel.BPS,  "bad slope2");
        require(_kinkBps   <= InterestModel.BPS,       "bad kink");
        baseBps   = _baseBps;
        slope1Bps = _slope1Bps;
        slope2Bps = _slope2Bps;
        kinkBps   = _kinkBps;
    }

}
