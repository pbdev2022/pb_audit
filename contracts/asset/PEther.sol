// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "./PToken.sol";

contract PEther is PToken {
    constructor(PBAdminInterface pbAdmin_,
                InterestModelInterface interestModel_,
                uint256 initialExchangeRateMantissa_,
                string memory name_,
                string memory symbol_,
                uint8 decimals_) PToken() {
        super.initialize(pbAdmin_, interestModel_, initialExchangeRateMantissa_, name_, symbol_, decimals_);
    }

    function mint() external payable {
        (uint256 err,) = mintInternal(msg.value);
        requireNoError(err, "mint failed");
    }

    function redeem(uint256 redeemTokens) external returns (uint256) {
        return redeemInternal(redeemTokens);
    }

    function redeemUnderlying(uint256 redeemAmount) external returns (uint256) {
        return redeemUnderlyingInternal(redeemAmount);
    }

    function borrow(uint256 borrowAmount) external returns (uint256) {
        return borrowInternal(borrowAmount);
    }

    function repayBorrow() external payable {
        (uint256 err,) = repayBorrowInternal(msg.value);
        requireNoError(err, "repayBorrow failed");
    }

    function repayBorrowBehalf(address borrower) external payable {
        (uint256 err,) = repayBorrowBehalfInternal(borrower, msg.value);
        requireNoError(err, "repayBorrowBehalf failed");
    }

    function liquidateBorrow(address borrower, PToken pTokenCollateral) external payable {
        (uint256 err,) = liquidateBorrowInternal(borrower, msg.value, pTokenCollateral);
        requireNoError(err, "liquidateBorrow failed");
    }

    function _addReserves() external payable returns (uint256) {
        return _addReservesInternal(msg.value);
    }

    receive() external payable {
        (uint256 err,) = mintInternal(msg.value);
        requireNoError(err, "mint failed");
    }

    function getCashPrior() internal view override returns (uint256) {
        (MathError err, uint256 startingBalance) = subRtn(address(this).balance, msg.value);
        require(err == MathError.NO_ERROR);
        return startingBalance;
    }

    function doTransferIn(address from, uint256 amount) internal override returns (uint256) {
        require(msg.sender == from, "sender mismatch");
        require(msg.value == amount, "value mismatch");
        return amount;
    }

    function doTransferOut(address payable to, uint256 amount) internal override {
        to.transfer(amount);
    }

    function requireNoError(uint256 errCode, string memory message) internal pure {
        if (errCode == uint256(Error.NO_ERROR)) {
            return;
        }

        bytes memory fullMessage = new bytes(bytes(message).length + 5);
        uint256 i;

        for (i = 0; i < bytes(message).length; i++) {
            fullMessage[i] = bytes(message)[i];
        }

        fullMessage[i+0] = bytes1(uint8(32));
        fullMessage[i+1] = bytes1(uint8(40));
        fullMessage[i+2] = bytes1(uint8(48 + ( errCode / 10 )));
        fullMessage[i+3] = bytes1(uint8(48 + ( errCode % 10 )));
        fullMessage[i+4] = bytes1(uint8(41));

        require(errCode == uint256(Error.NO_ERROR), string(fullMessage));
    }
}
