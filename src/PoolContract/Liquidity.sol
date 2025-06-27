// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {InterestAccrual} from "./InterestAccrual.sol";

abstract contract Liquidity is ERC20, InterestAccrual {
  event Deposited(address indexed user, uint256 amount, uint256 shares);
  event Withdrawn(address indexed user, uint256 amount, uint256 shares);

  constructor(IERC20 _usdt) ERC20("LP Token", "LPT") InterestAccrual(_usdt) {}

  function deposit(uint256 amount) external {
    accrueInterest();
    require(amount > 0, "Liquidity: zero deposit");

    usdt.transferFrom(msg.sender, address(this), amount);

    uint256 before = usdt.balanceOf(address(this)) - amount;
    uint256 supply = totalSupply();
    uint256 shares = (supply == 0 || before == 0) 
      ? amount 
      : (amount * supply) / before;

    _mint(msg.sender, shares);
    emit Deposited(msg.sender, amount, shares);
  }


  function withdraw(uint256 shares) external {
    accrueInterest();
    require(shares > 0, "Liquidity: zero withdraw");

    uint256 totalSup = totalSupply();
    uint256 assets   = usdt.balanceOf(address(this));
    uint256 out      = (shares * assets) / totalSup;
    require(out > 0, "Liquidity: zero output");

    _burn(msg.sender, shares);
    usdt.transfer(msg.sender, out);

    emit Withdrawn(msg.sender, out, shares);
  }
}
