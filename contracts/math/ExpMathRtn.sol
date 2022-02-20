// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./ExpBase.sol";
import "./SafeMathRtn.sol";

contract ExpMathRtn is ExpBase, SafeMathRtn {
    function mulExpRtn(Exp memory a, Exp memory b) pure internal returns (MathError, Exp memory) {
        (MathError err0, uint256 doubleScaledProduct) = mulRtn(a.mantissa, b.mantissa);
        if (err0 != MathError.NO_ERROR) {
            return (err0, Exp({mantissa: 0}));
        }

        (MathError err1, uint256 doubleScaledProductWithHalfScale) = addRtn(halfExpScale, doubleScaledProduct);
        if (err1 != MathError.NO_ERROR) {
            return (err1, Exp({mantissa: 0}));
        }

        (MathError err2, uint256 product) = divRtn(doubleScaledProductWithHalfScale, expScale);
        assert(err2 == MathError.NO_ERROR);

        return (MathError.NO_ERROR, Exp({mantissa: product}));
    }

    function addExpUintRtn(Exp memory a, uint256 added) pure internal returns (MathError, uint256) {
        (MathError err, Exp memory product) = mulExpUintRtn(a, added);
        if (err != MathError.NO_ERROR) {
            return (err, 0);
        }
        return (MathError.NO_ERROR, product.mantissa);
    }

	
    function mulExpRtn(uint256 a, uint256 b) pure internal returns (MathError, Exp memory) {
        return mulExpRtn(Exp({mantissa: a}), Exp({mantissa: b}));
    }
	
    function mulExpUintRtn(Exp memory a, uint256 scalar) pure internal returns (MathError, Exp memory) {
        (MathError err0, uint256 scaledMantissa) = mulRtn(a.mantissa, scalar);
        if (err0 != MathError.NO_ERROR) {
            return (err0, Exp({mantissa: 0}));
        }

        return (MathError.NO_ERROR, Exp({mantissa: scaledMantissa}));
    }


    function divExpRtn(uint256 num, uint256 denom) pure internal returns (MathError, Exp memory) {
        (MathError err0, uint256 scaledNumerator) = mulRtn(num, expScale);
        if (err0 != MathError.NO_ERROR) {
            return (err0, Exp({mantissa: 0}));
        }

        (MathError err1, uint256 rational) = divRtn(scaledNumerator, denom);
        if (err1 != MathError.NO_ERROR) {
            return (err1, Exp({mantissa: 0}));
        }

        return (MathError.NO_ERROR, Exp({mantissa: rational}));
    }
	
    function divExpRtn(Exp memory a, Exp memory b) pure internal returns (MathError, Exp memory) {
        return divExpRtn(a.mantissa, b.mantissa);
    }

    function divUintExpRtn(uint256 scalar, Exp memory divisor) pure internal returns (MathError, Exp memory) {
        (MathError err0, uint256 numerator) = mulRtn(expScale, scalar);
        if (err0 != MathError.NO_ERROR) {
            return (err0, Exp({mantissa: 0}));
        }
        return divExpRtn(numerator, divisor.mantissa);
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

    function divUintExpTruncRtn(uint256 scalar, Exp memory divisor) pure internal returns (MathError, uint256) {
        (MathError err, Exp memory fraction) = divUintExpRtn(scalar, divisor);
        if (err != MathError.NO_ERROR) {
            return (err, 0);
        }

        return (MathError.NO_ERROR, truncExp(fraction));
    }
}
