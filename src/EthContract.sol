// SPDX-License-Identifier: MIT

pragma solidity >=0.7.0 <0.9.0;


contract EthContract {


    event lockedEther(address indexed user_address, uint256 amount , bytes32 indexed lockId);
    

    // maximum allowed locking ether is 10 eth , because if any failure happens then , anything bug shouldnt happne
    uint256 max_eth_lock = 10;
    uint256 wai_in_one_eth = 1000000000000000000;

    // we will store wai/smallest unit
    uint256 totalEth = 0;


    function StoreCollateral() public {


    }


    function sendChainlLink_Confirmation()internal{

    }

    function ReleaseCollateral() public {

    }

}