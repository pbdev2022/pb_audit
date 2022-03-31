// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./ExpBase.sol";
import "./SafeMath.sol";

contract ExpMath is ExpBase {
	using SafeMath for uint256;
	
    function mulExp(Exp memory a, Exp memory b) pure internal returns (Exp memory) {
        return Exp({mantissa: a.mantissa.mul(b.mantissa) / expScale});
    }

    function mulExpUint(Exp memory a, uint256 b) pure internal returns (Exp memory) {
        return Exp({mantissa: a.mantissa.mul(b)});
    }

    function mulUintExp(uint256 a, Exp memory b) pure internal returns (uint256) {
        return a.mul(b.mantissa) / expScale;
    }

    function divExp(Exp memory a, Exp memory b) pure internal returns (Exp memory) {
        return Exp({mantissa: a.mantissa.mul(expScale).div(b.mantissa)});
    }

    function mulExpUnitTrunc(Exp memory a, uint256 scalar) pure internal returns (uint256) {
        Exp memory product = mulExpUint(a, scalar);
        return truncExp(product);
    }    

    function mulExpUintTruncAddUint(Exp memory a, uint scalar, uint addend) pure internal returns (uint) {
        Exp memory product = mulExpUint(a, scalar);
        return truncExp(product).add(addend);
    }

    function mulExpUintTrunc(Exp memory a, uint scalar) pure internal returns (uint) {
        Exp memory product = mulExpUint(a, scalar);
        return truncExp(product);
    }
}
