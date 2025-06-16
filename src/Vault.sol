// SPDX-License-Identifier: MIT

pragma solidity >=0.7.0 <0.9.0;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Vault
 * @notice Holds ETH collateral in a time-locked vault with a fixed maturity.
 */


contract Vault is ReentrancyGuard {

    event Locked(address indexed user, uint256 amount); // emits when a user locks eth collateral 
    event Unlocked(address indexed user, uint256 amount); // wmits when a user unlocks ETH collateral 

    // mapping of user address to their locked eth
    mapping(address=>uint256) public locked;

    // timestamp when fundds become available for unlocking
    uint256 public immutable i_maturity;

    constructor(uint256 duration) {
        require(duration>0, "Vault : zero duration");
        i_maturity = block.timestamp + duration;
    }

    function lock() external payable {
        require(msg.value>0, "Vault: zero amount");

        locked[msg.sender] += msg.value;
        emit Locked(msg.sender, msg.value);
    }


    /**
     * @notice Unlock staked ETH after maturity
     * @dev Transfers entire locked balance back to caller, guarded against reentrancy
     */
    function unlock() external nonReentrant {
        require(block.timestamp>= i_maturity, "Vault: not matured");
        uint256 amount = locked[msg.sender];
        
        require(amount>0, "Vault:nothing to unlock");
        locked[msg.sender]  = 0;

        (bool succ, ) = payable(msg.sender).call{value: amount}("");
        require(succ, "Vault: transfer failed");

        emit Unlocked(msg.sender, amount);
    }

    

}

