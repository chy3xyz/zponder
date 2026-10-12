// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./Curve.sol";

/// Minimal factory for testing template indexing.
/// Every `createCurve()` deploys a new `Curve` and emits `CurveCreated`,
/// which is the discovery event zponder feeds into the `curve` template.
///
/// `CurveCreated` deliberately carries two address fields (`curve`, `token`)
/// so that `discovery_address_field = "curve"` actually has to select the
/// right one instead of picking whatever address comes first.
contract Launchpad {
    /// Every curve trades the same token, so `token` differs from `curve`.
    address public constant TOKEN = 0x1111111111111111111111111111111111111111;

    event CurveCreated(address curve, address token);

    function createCurve() external returns (address curve) {
        curve = address(new Curve(TOKEN));
        emit CurveCreated(curve, TOKEN);
    }
}
