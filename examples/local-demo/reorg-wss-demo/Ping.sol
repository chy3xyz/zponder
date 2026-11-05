// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract Ping {
    event Ping(uint256 n);

    function ping(uint256 n) external {
        emit Ping(n);
    }
}
