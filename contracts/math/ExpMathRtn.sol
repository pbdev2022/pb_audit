// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./ExpBase.sol";
import "./SafeMathRtn.sol";

contract ExpMathRtn is ExpBase, SafeMathRtn {
    function addExpUintRtn(Exp memory a, uint256 addend) pure internal returns (MathError, uint256) {
        return addRtn(truncExp(a), addend);
    }

    function mulExpUintRtn(Exp memory a, uint256 scalar) pure internal returns (MathError, Exp memory) {
        (MathError err0, uint256 scaledMantissa) = mulRtn(a.mantissa, scalar);
        if (err0 != MathError.NO_ERROR) {
            return (err0, Exp({mantissa: 0}));
        }

        return (MathError.NO_ERROR, Exp({mantissa: scaledMantissa}));
    }

    function subExpUintRtn(Exp memory a, uint256 scalar) pure internal returns (MathError, Exp memory) {
        (MathError err0, uint256 scaledMantissa) = subRtn(a.mantissa, scalar);
        if (err0 != MathError.NO_ERROR) {
            return (err0, Exp({mantissa: 0}));
        }

        return (MathError.NO_ERROR, Exp({mantissa: scaledMantissa}));
    }       

    function mulExpUintTruncRtn(Exp memory a, uint256 scalar) pure internal returns (MathError, uint256) {
        (MathError err, Exp memory product) = mulExpUintRtn(a, scalar);
        if (err != MathError.NO_ERROR) {
            return (err, 0);
        }

        return (MathError.NO_ERROR, truncExp(product));
    }

    function mulExpUintTruncExpAddUintRtn(Exp memory a, uint256 scalar, uint256 addend) pure internal returns (MathError, uint256) {
        (MathError err, Exp memory product) = mulExpUintRtn(a, scalar);
        if (err != MathError.NO_ERROR) {
            return (err, 0);
        }

        return addRtn(truncExp(product), addend);
    }

}
