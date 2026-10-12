// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// Minimal bonding-curve clone for testing template indexing.
/// `Launchpad.createCurve()` deploys one of these per launch; zponder must
/// index `Buy` from every clone into a single `event_curve_Buy` table.
contract Curve {
    address public immutable token;
    uint256 public totalBought;

    event Buy(address buyer, uint256 amount);

    constructor(address _token) {
        token = _token;
    }

    function buy(uint256 amount) external {
        totalBought += amount;
        emit Buy(msg.sender, amount);
    }
}
