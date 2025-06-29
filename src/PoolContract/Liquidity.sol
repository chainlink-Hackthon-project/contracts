// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {ERC20}           from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20}          from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {InterestAccrual} from "./InterestAccrual.sol";

/// @title  Liquidity Module
/// @notice Enables depositors to mint LP shares against USDT and redeem pro rata
/// @dev    Inherits ERC20 for LP tokens and accrues interest on each action.
abstract contract Liquidity is ERC20, InterestAccrual {
    /// -----------------------------------------------------------------------
    /// Events
    /// -----------------------------------------------------------------------
    /// @notice Emitted when a user deposits USDT and receives LP shares
    /// @param user   Depositor’s address
    /// @param amount Amount of USDT deposited
    /// @param shares Number of LP shares minted
    event Deposited(address indexed user, uint256 amount, uint256 shares);

    /// @notice Emitted when a user burns LP shares to redeem USDT
    /// @param user   Redeemer’s address
    /// @param amount Amount of USDT returned
    /// @param shares Number of LP shares burned
    event Withdrawn(address indexed user, uint256 amount, uint256 shares);

    /// -----------------------------------------------------------------------
    /// Constructor
    /// -----------------------------------------------------------------------
    /// @param _usdt The USDT token this pool accepts for liquidity
    constructor(IERC20 _usdt) 
        ERC20("LP Token", "LPT") 
        InterestAccrual(_usdt) 
    {}

    /// -----------------------------------------------------------------------
    /// Deposit & Mint
    /// -----------------------------------------------------------------------
    /// @notice Deposit USDT and mint LP shares, accruing any pending interest
    /// @param amount The amount of USDT to deposit (must be > 0)
    function deposit(uint256 amount) external {
        // 1) settle any accrued interest before changing balances
        accrueInterest();

        // 2) sanity check
        require(amount > 0, "LQ: zero deposit");

        // 3) pull in USDT from the user
        usdt.transferFrom(msg.sender, address(this), amount);

        // 4) determine shares to mint:
        //    - if no existing shares or assets, mint 1:1
        //    - otherwise, maintain pool ratio: shares = amount * totalSupply / preAssets
        uint256 preAssets = usdt.balanceOf(address(this)) - amount;
        uint256 totalSh   = totalSupply();
        uint256 shares    = (totalSh == 0 || preAssets == 0)
            ? amount
            : (amount * totalSh) / preAssets;

        // 5) mint LP tokens and emit
        _mint(msg.sender, shares);
        emit Deposited(msg.sender, amount, shares);
    }

    /// -----------------------------------------------------------------------
    /// Burn & Withdraw
    /// -----------------------------------------------------------------------
    /// @notice Burn LP shares to redeem USDT pro rata, accruing any pending interest
    /// @param shares The number of LP shares to redeem (must be > 0)
    function withdraw(uint256 shares) external {
        // 1) settle interest so supply APR is updated
        accrueInterest();

        // 2) sanity check
        require(shares > 0, "LQ: zero withdraw");

        // 3) compute USDT output: out = shares * totalAssets / totalSupply
        uint256 totalSh = totalSupply();
        uint256 assets  = usdt.balanceOf(address(this));
        uint256 out     = (shares * assets) / totalSh;

        // 4) ensure the user actually receives something
        require(out > 0, "LQ: zero output");

        // 5) burn shares then transfer USDT
        _burn(msg.sender, shares);
        usdt.transfer(msg.sender, out);

        emit Withdrawn(msg.sender, out, shares);
    }
}
