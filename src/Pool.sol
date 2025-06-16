// SPDX-License-Identifier: MIT

pragma solidity >=0.7.0 <0.9.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// simple lending pool : deposit usdc, mint LP, borrow and repayf
contract Pool is ERC20("LP Token", "LPT"){
    IERC20 public immutable usdc;
    mapping(address => uint256) public debt;
    uint256 public totalBorrowed;

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount);
    
    constructor(address _usdc){
        require(_usdc != address(0), "Pool: zero USDC address");
        usdc = IERC20(_usdc);
    }

    function deposit(uint256 amount) external{
        require(amount>0,"Pool: zero deposit");
        usdc.transferFrom(msg.sender, address(this), amount);
        _mint(msg.sender,amount);
        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 lpAmount) external{
        require(lpAmount>0, "Pool: zero withdraw");
        _burn(msg.sender, lpAmount);
        usdc.transfer(msg.sender, lpAmount);
        emit Withdrawn(msg.sender, lpAmount);
    }




    function borrow(uint256 amount) external{
        require(amount>0,"Pool: zero borrow");
        // TODO: check liquidity and collateral
        debt[msg.sender] += amount;
        totalBorrowed += amount;
        usdc.transfer(msg.sender, amount);
        emit Borrowed(msg.sender, amount);
    }

    function repay(uint256 amount) external {
        require(amount>0, "Pool: zero repay");
        require(debt[msg.sender] >= amount, "Pool: overpay");
        usdc.transferFrom(msg.sender, address(this), amount);
        debt[msg.sender] -= amount;
        totalBorrowed -= amount;
        emit Repaid(msg.sender,amount);
    }


}