// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./SafeMath.sol";

contract DoubleMath {    
    uint256 constant doubleScale = 1e36;    
	using SafeMath for uint256;
	
    struct Double {
        uint256 mantissa;
    }    
	
    function addDouble(Double memory a, Double memory b) pure internal returns (Double memory) {
        return Double({mantissa: (a.mantissa).add(b.mantissa)});
    }

    function mulUintDouble(uint256 a, Double memory b) pure internal returns (uint256) {
        return a.mul(b.mantissa) / doubleScale;
    }

    function fractionDouble(uint a, uint b) pure internal returns (Double memory) {
        return Double({mantissa: a.mul(doubleScale).div(b)});
    }
}
