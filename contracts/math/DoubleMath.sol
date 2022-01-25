// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "./SafeMath.sol";

contract DoubleMath {    
    uint256 constant doubleScale = 1e36;    
	using SafeMath for uint256;
	
    struct Double {
        uint256 mantissa;
    }    
	
    function mulUintDouble(uint256 a, Double memory b) pure internal returns (uint256) {
        return a.mul(b.mantissa) / doubleScale;
    }
}
