// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract ExpBase {
    uint256 constant expScale = 1e18;
    uint256 constant halfExpScale = expScale/2;
    uint256 constant mantissaOne = expScale;	

    struct Exp {
        uint256 mantissa;
    }

    function truncExp(Exp memory exp) pure internal returns (uint256) {
        return exp.mantissa / expScale;
    }
	
    function lessThanExp(Exp memory left, Exp memory right) pure internal returns (bool) {
        return left.mantissa < right.mantissa;
    }
}