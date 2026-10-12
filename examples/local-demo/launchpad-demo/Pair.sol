// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// Minimal "post-graduation market" stand-in for testing template discovery.
///
/// Its address is not known at config time: the Curve clone emits `Paired(pair)`
/// and zponder's `[[factories]] from_template` feeds that address into the
/// `pair` template, so `Swap` lands in one shared `event_pair_Swap` table.
contract Pair {
    event Swap(uint256 amountIn, uint256 amountOut);

    function swap(uint256 amountIn, uint256 amountOut) external {
        emit Swap(amountIn, amountOut);
    }
}
