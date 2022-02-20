// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../asset/PToken.sol";

abstract contract PriceOracle {
    bool public constant isPriceOracle = true;

    function getDirectPrice(address asset) external view virtual returns (uint256);
    function getUnderlyingPrice(PToken pToken) external view virtual returns (uint256);
}
