// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockFeeOnTransferERC20 is ERC20 {
    error InvalidFeeBps();

    uint256 public feeBps;

    constructor(uint256 feeBps_) ERC20("Mock FoT", "MFOT") {
        _setFeeBps(feeBps_);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFeeBps(uint256 newFeeBps) external {
        _setFeeBps(newFeeBps);
    }

    function _setFeeBps(uint256 newFeeBps) internal {
        if (newFeeBps > 10_000) revert InvalidFeeBps();
        feeBps = newFeeBps;
    }

    function _update(address from, address to, uint256 value) internal virtual override {
        if (from == address(0) || to == address(0) || feeBps == 0) {
            super._update(from, to, value);
            return;
        }

        uint256 fee = (value * feeBps) / 10_000;
        uint256 received = value - fee;

        if (fee != 0) {
            super._update(from, address(0), fee);
        }

        super._update(from, to, received);
    }
}
