// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// Minimal bonding-curve clone for testing template indexing.
/// `Launchpad.createCurve()` deploys one of these per launch; zponder must
/// index `Buy` from every clone into a single `event_curve_Buy` table.
contract Curve {
    address public immutable token;
    uint256 public totalBought;

    event Buy(address buyer, uint256 amount);

    /// 毕业后市场（Pancake pair）地址：由 clone 自己发出 —— zponder 的
    /// `[[factories]] from_template` 以本模板的事件作为发现源，把 pair 喂给
    /// 第二个模板（见 config.toml 的 pair_discovery）。
    event Paired(address indexed pair);

    constructor(address _token) {
        token = _token;
    }

    function buy(uint256 amount) external {
        totalBought += amount;
        emit Buy(msg.sender, amount);
    }

    function setPair(address pair) external {
        emit Paired(pair);
    }
}
