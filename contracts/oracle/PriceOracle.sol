// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "../asset/PToken.sol";

abstract contract PriceOracle {
    bool public constant isPriceOracle = true;

    function getUnderlyingPrice(PToken pToken) external view virtual returns (uint256);
}
