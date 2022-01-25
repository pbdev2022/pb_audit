// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "../oracle/PriceOracle.sol";
import "../asset/PErc20.sol";

contract PBOracle is PriceOracle {
    mapping(address => uint256) prices;
    event PricePosted(address asset, uint256 previousPriceMantissa, uint256 requestedPriceMantissa, uint256 newPriceMantissa);

    function _getUnderlyingAddress(PToken pToken) private view returns (address) {
        address asset;
        if (compareStrings(pToken.symbol(), "pETH")) {
            asset = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        } else {
            asset = address(PErc20(address(pToken)).underlying());
        }
        return asset;
    }

    function getUnderlyingPrice(PToken pToken) public view override returns (uint256) {
        return prices[_getUnderlyingAddress(pToken)];
    }

    function setUnderlyingPrice(PToken pToken, uint256 underlyingPriceMantissa) public {
        address asset = _getUnderlyingAddress(pToken);
        emit PricePosted(asset, prices[asset], underlyingPriceMantissa, underlyingPriceMantissa);
        prices[asset] = underlyingPriceMantissa;
    }

    function setDirectPrice(address asset, uint256 price) public {
        emit PricePosted(asset, prices[asset], price, price);
        prices[asset] = price;
    }

    function assetPrices(address asset) external view returns (uint256) {
        return prices[asset];
    }

    function compareStrings(string memory a, string memory b) internal pure returns (bool) {
        return (keccak256(abi.encodePacked((a))) == keccak256(abi.encodePacked((b))));
    }
}
