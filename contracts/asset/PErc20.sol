// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./PToken.sol";

contract PErc20 is PToken, PErc20Interface {
    event Log(string message);
    event LogBytes(bytes data);    

    constructor(address underlying_,
                PBAdminInterface pbAdmin_,
                InterestModelInterface interestModel_,
                string memory name_,
                string memory symbol_,
                uint8 decimals_) PToken() {

        super.initialize(pbAdmin_, interestModel_, name_, symbol_, decimals_);
        underlying = underlying_;
    }

    function mint(uint256 mintAmount) external override returns (uint256) {
        (uint256 err,) = mintInternal(mintAmount);
        return err;
    }

    function redeem(uint256 redeemTokens) external override returns (uint256) {
        return redeemInternal(redeemTokens);
    }

    function borrow(uint256 borrowAmount) external override returns (uint256) {
        return borrowInternal(borrowAmount);
    }

    function repayBorrow(uint256 repayAmount) external override returns (uint256) {
        (uint256 err,) = repayBorrowInternal(repayAmount);
        return err;
    }

    function repayBorrowBehalf(address borrower, uint256 repayAmount) external override returns (uint256) {
        (uint256 err,) = repayBorrowBehalfInternal(borrower, repayAmount);
        return err;
    }

    function liquidateBorrow(address borrower, uint256 repayAmount, PTokenInterface pTokenCollateral) external override returns (uint256) {
        (uint256 err,) = liquidateBorrowInternal(borrower, repayAmount, pTokenCollateral);
        return err;
    }

    function sweepToken(EIP20Interface token) external override {    
    	require(address(token) != underlying, "PErc20: sweepToken() - can not sweep underlying token");
    	uint256 balance = token.balanceOf(address(this));
    	token.transfer(admin, balance);
    }

    function _addReserves(uint256 addAmount) external override returns (uint256) {
        return _addReservesInternal(addAmount);
    }

    function getCashPrior() internal view override virtual returns (uint256) {
        EIP20Interface token = EIP20Interface(underlying);
        return token.balanceOf(address(this));
    }

    function doTransferIn(address from, uint256 amount) internal override virtual returns (uint256) {
        EIP20Interface token = EIP20Interface(underlying);
        uint256 balanceBefore = EIP20Interface(underlying).balanceOf(address(this));
        token.transferFrom(from, address(this), amount);

        bool success;
        assembly {
            switch returndatasize()
                case 0 {                    
                    success := not(0)       
                }
                case 32 {                   
                    returndatacopy(0, 0, 32)
                    success := mload(0)     
                }
                default {                   
                    revert(0, 0)
                }
        }
        require(success, "PErc20: TOKEN_TRANSFER_IN_FAILED");

        uint256 balanceAfter = EIP20Interface(underlying).balanceOf(address(this));
        require(balanceAfter >= balanceBefore, "PErc20: TOKEN_TRANSFER_IN_OVERFLOW");
        return balanceAfter - balanceBefore;
    }

    function doTransferOut(address payable to, uint256 amount) internal override virtual {
        EIP20Interface token = EIP20Interface(underlying);
        token.transfer(to, amount);

        bool success;
        assembly {
            switch returndatasize()
                case 0 {           
                    success := not(0)
                }
                case 32 {            
                    returndatacopy(0, 0, 32)
                    success := mload(0)
                }
                default {              
                    revert(0, 0)
                }
        }
        require(success, "PErc20: TOKEN_TRANSFER_OUT_FAILED");
    }
}
