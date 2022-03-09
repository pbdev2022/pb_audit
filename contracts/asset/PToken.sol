// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../admin/PBAdminInterface.sol";
import "./PTokenInterfaces.sol";
import "../errrpt/ErrorReporter.sol";
import "../math/ExpMath.sol";
import "../math/ExpMathRtn.sol";
import "../interest/InterestModelInterface.sol";

abstract contract PToken is PTokenInterface, ExpMath, ExpMathRtn, TokenErrorReporter {
    using SafeMath for uint256;

    constructor() {
        admin = msg.sender;
    }

    function initialize(PBAdminInterface pbAdmin_,
                        InterestModelInterface interestModel_,
                        string memory name_,
                        string memory symbol_,
                        uint8 decimals_) public {

        require(msg.sender == admin, "PToken: only admin may initialize the market");
        require(accrualBlockNumber == 0 && borrowIndex == 0, "PToken: market may only be initialized once");
		
        uint256 err = _setPBAdmin(pbAdmin_);
        require(err == uint256(Error.NO_ERROR), "PToken: setting PBAdmin failed");

        accrualBlockNumber = getBlockNumber();
        borrowIndex = mantissaOne;

        err = _setInterestModelFresh(interestModel_);
        require(err == uint256(Error.NO_ERROR), "PToken: setting interest rate model failed");

        name = name_;
        symbol = symbol_;
        decimals = decimals_;

        _notEntered = true;
    }

    function transferTokens(address spender, address src, address dst, uint256 tokens) internal returns (uint256) {
        uint256 allowed = pbAdmin.transferAllowed(address(this), src, dst, tokens);
        if (allowed != 0) {
            return failOpaque(Error.PB_ADMIN_REJECTION, FailureInfo.TRANSFER_PB_ADMIN_REJECTION, allowed);
        }

        if (src == dst) {
            return fail(Error.BAD_INPUT, FailureInfo.TRANSFER_NOT_ALLOWED);
        }

        uint256 startingAllowance = 0;

        MathError mathErr;
        uint256 allowanceNew;
        uint256 srcTokensNew;
        uint256 dstTokensNew;

        if (spender != src) {
            startingAllowance = transferAllowances[src][spender];
            (mathErr, allowanceNew) = subRtn(startingAllowance, tokens);
            if (mathErr != MathError.NO_ERROR) {
                return fail(Error.MATH_ERROR, FailureInfo.TRANSFER_NOT_ALLOWED);
            }
        }

        (mathErr, srcTokensNew) = subRtn(accountTokens[src], tokens);
        if (mathErr != MathError.NO_ERROR) {
            return fail(Error.MATH_ERROR, FailureInfo.TRANSFER_NOT_ENOUGH);
        }

        (mathErr, dstTokensNew) = addRtn(accountTokens[dst], tokens);
        if (mathErr != MathError.NO_ERROR) {
            return fail(Error.MATH_ERROR, FailureInfo.TRANSFER_TOO_MUCH);
        }

        accountTokens[src] = srcTokensNew;
        accountTokens[dst] = dstTokensNew;

        if (startingAllowance != 0) {
            transferAllowances[src][spender] = allowanceNew;
        }

        emit Transfer(src, dst, tokens);

        return uint256(Error.NO_ERROR);
    }

    function transfer(address dst, uint256 amount) external override nonReentrant returns (bool) {
        return transferTokens(msg.sender, msg.sender, dst, amount) == uint256(Error.NO_ERROR);
    }

    function transferFrom(address src, address dst, uint256 amount) external override nonReentrant returns (bool) {
        return transferTokens(msg.sender, src, dst, amount) == uint256(Error.NO_ERROR);
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        address src = msg.sender;
        transferAllowances[src][spender] = amount;
        emit Approval(src, spender, amount);
        return true;
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return transferAllowances[owner][spender];
    }

    function balanceOf(address owner) external view override returns (uint256) {
        return accountTokens[owner];
    }

    function balanceOfUnderlying(address owner) external view override returns (uint256) {
        return accountTokens[owner];
    }

    function getAccountSnapshot(address account) external override view returns (uint256, uint256, uint256) {
        uint256 pTokenBalance = accountTokens[account];
        uint256 borrowBalance;

        MathError mErr;
        (mErr, borrowBalance) = borrowBalanceStoredInternal(account);
        if (mErr != MathError.NO_ERROR) {
            return (uint256(Error.MATH_ERROR), 0, 0);
        }

        return (uint256(Error.NO_ERROR), pTokenBalance, borrowBalance);
    }

    function getBlockNumber() internal view returns (uint256) {
        return block.number;
    }

    function borrowRatePerBlock() external view override returns (uint256) {
        return interestModel.getBorrowRate(getCashPrior(), totalBorrows, totalReserves);
    }

    function supplyRatePerBlock() external view override returns (uint256) {
        return interestModel.getSupplyRate(getCashPrior(), totalBorrows, totalReserves);
    }

    function totalBorrowsCurrent() external override nonReentrant returns (uint256) {
        require(accrueInterest() == uint256(Error.NO_ERROR), "PToken: accrue interest failed");
        return totalBorrows;
    }

    function borrowBalanceCurrent(address account) external override nonReentrant returns (uint256) {
        require(accrueInterest() == uint256(Error.NO_ERROR), "PToken: accrue interest failed");
        return borrowBalanceStored(account);
    }

    function borrowBalanceStored(address account) public view override returns (uint256) {
        (MathError err, uint256 result) = borrowBalanceStoredInternal(account);
        require(err == MathError.NO_ERROR, "PToken: borrowBalanceStoredInternal failed");
        return result;
    }

    function borrowBalanceStored2(address account) public view override returns (uint256, uint256) {
        (MathError err, uint256 result, uint256 purePrincipal) = borrowBalanceStoredInternal2(account);
        require(err == MathError.NO_ERROR, "PToken: borrowBalanceStoredInternal failed");
        return (result, purePrincipal);
    }    

    function borrowBalanceStoredInternal(address account) internal view returns (MathError, uint256) {
        MathError mathErr;
        uint256 principalTimesIndex;
        uint256 result;

        BorrowSnapshot storage borrowSnapshot = accountBorrows[account];

        if (borrowSnapshot.principal == 0) {
            return (MathError.NO_ERROR, 0);
        }

        (mathErr, principalTimesIndex) = mulRtn(borrowSnapshot.principal, borrowIndex);
        if (mathErr != MathError.NO_ERROR) {
            return (mathErr, 0);
        }

        (mathErr, result) = divRtn(principalTimesIndex, borrowSnapshot.interestIndex);
        if (mathErr != MathError.NO_ERROR) {
            return (mathErr, 0);
        }

        return (MathError.NO_ERROR, result);
    }

    function borrowBalanceStoredInternal2(address account) internal view returns (MathError, uint256, uint256) {
        (MathError mathErr, uint256 result) = borrowBalanceStoredInternal(account);
        return (mathErr, result, accountBorrows[account].purePrincipal);
    }    

    function getCash() external view override returns (uint256) {
        return getCashPrior();
    }

    function accrueInterest() public override virtual returns (uint256) {
        uint256 currentBlockNumber = getBlockNumber();
        uint256 accrualBlockNumberPrior = accrualBlockNumber;

        if (accrualBlockNumberPrior == currentBlockNumber) {
            return uint256(Error.NO_ERROR);
        }

        uint256 cashPrior = getCashPrior();
        uint256 borrowsPrior = totalBorrows;
        uint256 reservesPrior = totalReserves;
        uint256 borrowIndexPrior = borrowIndex;

        uint256 borrowRateMantissa = interestModel.getBorrowRate(cashPrior, borrowsPrior, reservesPrior);
        require(borrowRateMantissa <= borrowRateMaxMantissa, "PToken: borrow rate is absurdly high");

        (MathError mathErr, uint256 blockDelta) = subRtn(currentBlockNumber, accrualBlockNumberPrior);
        require(mathErr == MathError.NO_ERROR, "PToken: could not calculate block delta");

        Exp memory simpleInterestFactor;
        uint256 interestAccumulated;
        uint256 totalBorrowsNew;
        uint256 totalReservesNew;
        uint256 borrowIndexNew;

        (mathErr, simpleInterestFactor) = mulExpUintRtn(Exp({mantissa: borrowRateMantissa}), blockDelta);
        if (mathErr != MathError.NO_ERROR) {
            return failOpaque(Error.MATH_ERROR, FailureInfo.ACCRUE_INTEREST_SIMPLE_INTEREST_FACTOR_CALCULATION_FAILED, uint256(mathErr));
        }

        (mathErr, interestAccumulated) = mulExpUintTruncRtn(simpleInterestFactor, borrowsPrior);
        if (mathErr != MathError.NO_ERROR) {
            return failOpaque(Error.MATH_ERROR, FailureInfo.ACCRUE_INTEREST_ACCUMULATED_INTEREST_CALCULATION_FAILED, uint256(mathErr));
        }

        (mathErr, totalBorrowsNew) = addRtn(interestAccumulated, borrowsPrior);
        if (mathErr != MathError.NO_ERROR) {
            return failOpaque(Error.MATH_ERROR, FailureInfo.ACCRUE_INTEREST_NEW_TOTAL_BORROWS_CALCULATION_FAILED, uint256(mathErr));
        }

        (mathErr, totalReservesNew) = mulExpUintTruncExpAddUintRtn(Exp({mantissa: reserveFactorMantissa}), interestAccumulated, reservesPrior);
        if (mathErr != MathError.NO_ERROR) {
            return failOpaque(Error.MATH_ERROR, FailureInfo.ACCRUE_INTEREST_NEW_TOTAL_RESERVES_CALCULATION_FAILED, uint256(mathErr));
        }

        (mathErr, borrowIndexNew) = mulExpUintTruncExpAddUintRtn(simpleInterestFactor, borrowIndexPrior, borrowIndexPrior);
        if (mathErr != MathError.NO_ERROR) {
            return failOpaque(Error.MATH_ERROR, FailureInfo.ACCRUE_INTEREST_NEW_BORROW_INDEX_CALCULATION_FAILED, uint256(mathErr));
        }

        accrualBlockNumber = currentBlockNumber;
        borrowIndex = borrowIndexNew;
        totalBorrows = totalBorrowsNew;
        totalReserves = totalReservesNew;

        emit AccrueInterest(cashPrior, interestAccumulated, borrowIndexNew, totalBorrowsNew);

        return uint256(Error.NO_ERROR);
    }

    function mintInternal(uint256 mintAmount) internal nonReentrant returns (uint256, uint256) {
        uint256 error = accrueInterest();
        if (error != uint256(Error.NO_ERROR)) {
            return (fail(Error(error), FailureInfo.MINT_ACCRUE_INTEREST_FAILED), 0);
        }

        return mintFresh(msg.sender, mintAmount);
    }

    struct MintLocalVars {
        Error err;
        MathError mathErr;
        uint256 mintTokens;
        uint256 totalSupplyNew;
        uint256 accountTokensNew;
        uint256 actualMintAmount;
    }

    function mintFresh(address minter, uint256 mintAmount) internal returns (uint256, uint256) {
        uint256 allowed = pbAdmin.mintAllowed(address(this), minter, mintAmount);
        if (allowed != 0) {
            return (failOpaque(Error.PB_ADMIN_REJECTION, FailureInfo.MINT_PB_ADMIN_REJECTION, allowed), 0);
        }

        if (accrualBlockNumber != getBlockNumber()) {
            return (fail(Error.MARKET_NOT_FRESH, FailureInfo.MINT_FRESHNESS_CHECK), 0);
        }

        MintLocalVars memory vars;

        vars.actualMintAmount = doTransferIn(minter, mintAmount);

        vars.mintTokens = vars.actualMintAmount;

        (vars.mathErr, vars.totalSupplyNew) = addRtn(totalSupply, vars.mintTokens);
        require(vars.mathErr == MathError.NO_ERROR, "PToken: MINT_NEW_TOTAL_SUPPLY_CALCULATION_FAILED");

        (vars.mathErr, vars.accountTokensNew) = addRtn(accountTokens[minter], vars.mintTokens);
        require(vars.mathErr == MathError.NO_ERROR, "PToken: MINT_NEW_ACCOUNT_BALANCE_CALCULATION_FAILED");

        totalSupply = vars.totalSupplyNew;
        accountTokens[minter] = vars.accountTokensNew;

        emit Mint(minter, vars.actualMintAmount, vars.mintTokens);
        emit Transfer(address(this), minter, vars.mintTokens);

        return (uint256(Error.NO_ERROR), vars.actualMintAmount);
    }

    function redeemInternal(uint256 redeemTokens) internal nonReentrant returns (uint256) {
        uint256 error = accrueInterest();
        if (error != uint256(Error.NO_ERROR)) {
            return fail(Error(error), FailureInfo.REDEEM_ACCRUE_INTEREST_FAILED);
        }

        return redeemFresh(payable(msg.sender), redeemTokens, 0);
    }

    struct RedeemLocalVars {
        Error err;
        MathError mathErr;
        uint256 redeemTokens;
        uint256 redeemAmount;
        uint256 totalSupplyNew;
        uint256 accountTokensNew;
    }

    function redeemFresh(address payable redeemer, uint256 redeemTokensIn, uint256 redeemAmountIn) internal returns (uint256) {
        require(redeemTokensIn == 0 || redeemAmountIn == 0, "PToken: one of redeemTokensIn or redeemAmountIn must be zero");

        RedeemLocalVars memory vars;

        if (redeemTokensIn > 0) {
            vars.redeemTokens = redeemTokensIn;
            vars.redeemAmount = redeemTokensIn;
        } else {
            vars.redeemTokens = redeemAmountIn;
            vars.redeemAmount = redeemAmountIn;
        }

        uint256 allowed = pbAdmin.redeemAllowed(address(this), redeemer, vars.redeemTokens);
        if (allowed != 0) {
            return failOpaque(Error.PB_ADMIN_REJECTION, FailureInfo.REDEEM_PB_ADMIN_REJECTION, allowed);
        }

        if (accrualBlockNumber != getBlockNumber()) {
            return fail(Error.MARKET_NOT_FRESH, FailureInfo.REDEEM_FRESHNESS_CHECK);
        }

        (vars.mathErr, vars.totalSupplyNew) = subRtn(totalSupply, vars.redeemTokens);
        if (vars.mathErr != MathError.NO_ERROR) {
            return failOpaque(Error.MATH_ERROR, FailureInfo.REDEEM_NEW_TOTAL_SUPPLY_CALCULATION_FAILED, uint256(vars.mathErr));
        }

        (vars.mathErr, vars.accountTokensNew) = subRtn(accountTokens[redeemer], vars.redeemTokens);
        if (vars.mathErr != MathError.NO_ERROR) {
            return failOpaque(Error.MATH_ERROR, FailureInfo.REDEEM_NEW_ACCOUNT_BALANCE_CALCULATION_FAILED, uint256(vars.mathErr));
        }

        if (getCashPrior() < vars.redeemAmount) {
            return fail(Error.TOKEN_INSUFFICIENT_CASH, FailureInfo.REDEEM_TRANSFER_OUT_NOT_POSSIBLE);
        }

        doTransferOut(redeemer, vars.redeemAmount);

        totalSupply = vars.totalSupplyNew;
        accountTokens[redeemer] = vars.accountTokensNew;

        emit Transfer(redeemer, address(this), vars.redeemTokens);
        emit Redeem(redeemer, vars.redeemAmount, vars.redeemTokens);

        pbAdmin.redeemVerify(address(this), redeemer, vars.redeemAmount, vars.redeemTokens);

        return uint256(Error.NO_ERROR);
    }

    function borrowInternal(uint256 borrowAmount) internal nonReentrant returns (uint256) {
        uint256 error = accrueInterest();
        if (error != uint256(Error.NO_ERROR)) {
            return fail(Error(error), FailureInfo.BORROW_ACCRUE_INTEREST_FAILED);
        }

        return borrowFresh(payable(msg.sender), borrowAmount);
    }

    struct BorrowLocalVars {
        MathError mathErr;
        uint256 accountBorrows;
        uint256 accountBorrowsNew;
        uint256 totalBorrowsNew;
    }

    function borrowAllowed(address payable borrower, uint256 borrowAmount) public returns (uint256) {
        return pbAdmin.borrowAllowed(address(this), borrower, borrowAmount);
    }

    function borrowFresh(address payable borrower, uint256 borrowAmount) internal returns (uint256) {
        uint256 allowed = pbAdmin.borrowAllowed(address(this), borrower, borrowAmount);
        if (allowed != 0) {
            return failOpaque(Error.PB_ADMIN_REJECTION, FailureInfo.BORROW_PB_ADMIN_REJECTION, allowed);
        }

        if (accrualBlockNumber != getBlockNumber()) {
            return fail(Error.MARKET_NOT_FRESH, FailureInfo.BORROW_FRESHNESS_CHECK);
        }

        if (getCashPrior() < borrowAmount) {
            return fail(Error.TOKEN_INSUFFICIENT_CASH, FailureInfo.BORROW_CASH_NOT_AVAILABLE);
        }

        BorrowLocalVars memory vars;

        (vars.mathErr, vars.accountBorrows) = borrowBalanceStoredInternal(borrower);
        if (vars.mathErr != MathError.NO_ERROR) {
            return failOpaque(Error.MATH_ERROR, FailureInfo.BORROW_ACCUMULATED_BALANCE_CALCULATION_FAILED, uint256(vars.mathErr));
        }

        (vars.mathErr, vars.accountBorrowsNew) = addRtn(vars.accountBorrows, borrowAmount);
        if (vars.mathErr != MathError.NO_ERROR) {
            return failOpaque(Error.MATH_ERROR, FailureInfo.BORROW_NEW_ACCOUNT_BORROW_BALANCE_CALCULATION_FAILED, uint256(vars.mathErr));
        }

        (vars.mathErr, vars.totalBorrowsNew) = addRtn(totalBorrows, borrowAmount);
        if (vars.mathErr != MathError.NO_ERROR) {
            return failOpaque(Error.MATH_ERROR, FailureInfo.BORROW_NEW_TOTAL_BALANCE_CALCULATION_FAILED, uint256(vars.mathErr));
        }

        doTransferOut(borrower, borrowAmount);

        accountBorrows[borrower].principal = vars.accountBorrowsNew;
        accountBorrows[borrower].interestIndex = borrowIndex;
        accountBorrows[borrower].purePrincipal =  accountBorrows[borrower].purePrincipal.add(borrowAmount);
        totalBorrows = vars.totalBorrowsNew;

        emit Borrow(borrower, borrowAmount, vars.accountBorrowsNew, vars.totalBorrowsNew);

        return uint256(Error.NO_ERROR);
    }

    function repayBorrowInternal(uint256 repayAmount) internal nonReentrant returns (uint256, uint256) {
        uint256 error = accrueInterest();
        if (error != uint256(Error.NO_ERROR)) {
            return (fail(Error(error), FailureInfo.REPAY_BORROW_ACCRUE_INTEREST_FAILED), 0);
        }
        return repayBorrowFresh(msg.sender, msg.sender, repayAmount);
    }

    function repayBorrowBehalfInternal(address borrower, uint256 repayAmount) internal nonReentrant returns (uint256, uint256) {
        uint256 error = accrueInterest();
        if (error != uint256(Error.NO_ERROR)) {
            return (fail(Error(error), FailureInfo.REPAY_BEHALF_ACCRUE_INTEREST_FAILED), 0);
        }
        return repayBorrowFresh(msg.sender, borrower, repayAmount);
    }

    struct RepayBorrowLocalVars {
        Error err;
        MathError mathErr;
        uint256 repayAmount;
        uint256 borrowerIndex;
        uint256 accountBorrows;
        uint256 accountPureBorrows;
        uint256 interestCalculated;
        uint256 interestInClank;
        uint256 accountBorrowsNew;
        uint256 accountPureBorrowsNew;
        uint256 totalBorrowsNew;
        uint256 actualRepayAmount;
    }

    function repayBorrowFresh(address payer, address borrower, uint256 repayAmount) internal returns (uint256, uint256) {
        uint256 allowed = pbAdmin.repayBorrowAllowed(address(this), payer, borrower, repayAmount);
        if (allowed != 0) {
            return (failOpaque(Error.PB_ADMIN_REJECTION, FailureInfo.REPAY_BORROW_PB_ADMIN_REJECTION, allowed), 0);
        }

        if (accrualBlockNumber != getBlockNumber()) {
            return (fail(Error.MARKET_NOT_FRESH, FailureInfo.REPAY_BORROW_FRESHNESS_CHECK), 0);
        }

        RepayBorrowLocalVars memory vars;

        vars.borrowerIndex = accountBorrows[borrower].interestIndex;
        (vars.mathErr, vars.accountBorrows, vars.accountPureBorrows) = borrowBalanceStoredInternal2(borrower);
        if (vars.mathErr != MathError.NO_ERROR) {
            return (failOpaque(Error.MATH_ERROR, FailureInfo.REPAY_BORROW_ACCUMULATED_BALANCE_CALCULATION_FAILED, uint256(vars.mathErr)), 0);
        }

        vars.interestCalculated = repayAmount.mul(vars.accountBorrows.sub(vars.accountPureBorrows)).div(vars.accountPureBorrows);

        bool ret = pbAdmin.clankTransferIn(address(this), payer, vars.interestCalculated);
        require(ret == true, "PToken: REPAY_BORROW_CLANK_TRANSFER_FAILED");

        vars.repayAmount = repayAmount;
        vars.actualRepayAmount = doTransferIn(payer, vars.repayAmount);

        (vars.mathErr, vars.accountPureBorrowsNew) = subRtn(vars.accountPureBorrows, vars.actualRepayAmount);
        require(vars.mathErr == MathError.NO_ERROR, "PToken: REPAY_BORROW_NEW_ACCOUNT_BORROW_BALANCE_CALCULATION_FAILED");

        if (vars.accountPureBorrowsNew != 0) {
            (vars.mathErr, vars.accountBorrowsNew) = subRtn((vars.accountBorrows).sub(vars.interestCalculated), vars.actualRepayAmount);
            require(vars.mathErr == MathError.NO_ERROR, "PToken: REPAY_BORROW_NEW_ACCOUNT_BORROW_BALANCE_CALCULATION_FAILED");
        }
        else {
            vars.accountBorrowsNew = 0;
        }

        (vars.mathErr, vars.totalBorrowsNew) = subRtn(totalBorrows, vars.actualRepayAmount.add(vars.interestCalculated));        
        require(vars.mathErr == MathError.NO_ERROR, "PToken: REPAY_BORROW_NEW_TOTAL_BALANCE_CALCULATION_FAILED");

        accountBorrows[borrower].principal = vars.accountBorrowsNew;
        accountBorrows[borrower].purePrincipal = vars.accountPureBorrowsNew;
        accountBorrows[borrower].interestIndex = borrowIndex;
        totalBorrows = vars.totalBorrowsNew;

        emit RepayBorrow(payer, borrower, vars.actualRepayAmount, vars.accountBorrowsNew, vars.totalBorrowsNew);

        return (uint256(Error.NO_ERROR), vars.actualRepayAmount);
    }

    function liquidateBorrowInternal(address borrower, uint256 repayAmount, PTokenInterface pTokenCollateral) internal nonReentrant returns (uint256, uint256) {
        uint256 error = accrueInterest();
        if (error != uint256(Error.NO_ERROR)) {
            return (fail(Error(error), FailureInfo.LIQUIDATE_ACCRUE_BORROW_INTEREST_FAILED), 0);
        }

        error = pTokenCollateral.accrueInterest();
        if (error != uint256(Error.NO_ERROR)) {
            return (fail(Error(error), FailureInfo.LIQUIDATE_ACCRUE_COLLATERAL_INTEREST_FAILED), 0);
        }

        return liquidateBorrowFresh(msg.sender, borrower, repayAmount, pTokenCollateral);
    }

    function liquidateBorrowFresh(address liquidator, address borrower, uint256 repayAmount, PTokenInterface pTokenCollateral) internal returns (uint256, uint256) {
        uint256 allowed = pbAdmin.liquidateBorrowAllowed(address(this), address(pTokenCollateral), liquidator, borrower, repayAmount);
        if (allowed != 0) {
            return (failOpaque(Error.PB_ADMIN_REJECTION, FailureInfo.LIQUIDATE_PB_ADMIN_REJECTION, allowed), 0);
        }

        if (accrualBlockNumber != getBlockNumber()) {
            return (fail(Error.MARKET_NOT_FRESH, FailureInfo.LIQUIDATE_FRESHNESS_CHECK), 0);
        }

        if (pTokenCollateral.accrualBlockNumber() != getBlockNumber()) {
            return (fail(Error.MARKET_NOT_FRESH, FailureInfo.LIQUIDATE_COLLATERAL_FRESHNESS_CHECK), 0);
        }

        if (borrower == liquidator) {
            return (fail(Error.INVALID_ACCOUNT_PAIR, FailureInfo.LIQUIDATE_LIQUIDATOR_IS_BORROWER), 0);
        }

        if (repayAmount == 0) {
            return (fail(Error.INVALID_CLOSE_AMOUNT_REQUESTED, FailureInfo.LIQUIDATE_CLOSE_AMOUNT_IS_ZERO), 0);
        }

        if (repayAmount == type(uint256).max) {            
            return (fail(Error.INVALID_CLOSE_AMOUNT_REQUESTED, FailureInfo.LIQUIDATE_CLOSE_AMOUNT_IS_UINT_MAX), 0);
        }

        (uint256 repayBorrowError, uint256 actualRepayAmount) = repayBorrowFresh(liquidator, borrower, repayAmount);
        if (repayBorrowError != uint256(Error.NO_ERROR)) {
            return (fail(Error(repayBorrowError), FailureInfo.LIQUIDATE_REPAY_BORROW_FRESH_FAILED), 0);
        }

        (uint256 amountSeizeError, uint256 seizeTokens) = pbAdmin.liquidateCalculateSeizeTokens(address(this), address(pTokenCollateral), actualRepayAmount);
        require(amountSeizeError == uint256(Error.NO_ERROR), "PToken: LIQUIDATE_PB_ADMIN_CALCULATE_AMOUNT_SEIZE_FAILED");
        require(pTokenCollateral.balanceOf(borrower) >= seizeTokens, "PToken: LIQUIDATE_SEIZE_TOO_MUCH");

        uint256 seizeError;
        if (address(pTokenCollateral) == address(this)) {
            seizeError = seizeInternal(address(this), liquidator, borrower, seizeTokens);
        } else {
            seizeError = pTokenCollateral.seize(liquidator, borrower, seizeTokens);
        }

        require(seizeError == uint256(Error.NO_ERROR), "PToken: token seizure failed");

        emit LiquidateBorrow(liquidator, borrower, actualRepayAmount, address(pTokenCollateral), seizeTokens);

        return (uint256(Error.NO_ERROR), actualRepayAmount);
    }

    function seize(address liquidator, address borrower, uint256 seizeTokens) external override nonReentrant returns (uint256) {
        return seizeInternal(msg.sender, liquidator, borrower, seizeTokens);
    }

    struct SeizeInternalLocalVars {
        MathError mathErr;
        uint256 borrowerTokensNew;
        uint256 liquidatorTokensNew;
        uint256 liquidatorSeizeTokens;
        uint256 protocolSeizeTokens;
        uint256 protocolSeizeAmount;
        uint256 totalReservesNew;
        uint256 totalSupplyNew;
    }

    function seizeInternal(address seizerToken, address liquidator, address borrower, uint256 seizeTokens) internal returns (uint256) {
        uint256 allowed = pbAdmin.seizeAllowed(address(this), seizerToken, liquidator, borrower, seizeTokens);
        if (allowed != 0) {
            return failOpaque(Error.PB_ADMIN_REJECTION, FailureInfo.LIQUIDATE_SEIZE_PB_ADMIN_REJECTION, allowed);
        }

        if (borrower == liquidator) {
            return fail(Error.INVALID_ACCOUNT_PAIR, FailureInfo.LIQUIDATE_SEIZE_LIQUIDATOR_IS_BORROWER);
        }

        SeizeInternalLocalVars memory vars;

        (vars.mathErr, vars.borrowerTokensNew) = subRtn(accountTokens[borrower], seizeTokens);
        if (vars.mathErr != MathError.NO_ERROR) {
            return failOpaque(Error.MATH_ERROR, FailureInfo.LIQUIDATE_SEIZE_BALANCE_DECREMENT_FAILED, uint256(vars.mathErr));
        }

        vars.protocolSeizeTokens = mulUintExp(seizeTokens, Exp({mantissa: protocolSeizeShareMantissa}));
        vars.liquidatorSeizeTokens = seizeTokens.sub(vars.protocolSeizeTokens);

        vars.protocolSeizeAmount = vars.protocolSeizeTokens;

        vars.totalReservesNew = totalReserves.add(vars.protocolSeizeAmount);
        vars.totalSupplyNew = totalSupply.sub(vars.protocolSeizeTokens);

        (vars.mathErr, vars.liquidatorTokensNew) = addRtn(accountTokens[liquidator], vars.liquidatorSeizeTokens);
        if (vars.mathErr != MathError.NO_ERROR) {
            return failOpaque(Error.MATH_ERROR, FailureInfo.LIQUIDATE_SEIZE_BALANCE_INCREMENT_FAILED, uint256(vars.mathErr));
        }

        totalReserves = vars.totalReservesNew;
        totalSupply = vars.totalSupplyNew;
        accountTokens[borrower] = vars.borrowerTokensNew;
        accountTokens[liquidator] = vars.liquidatorTokensNew;

        emit Transfer(borrower, liquidator, vars.liquidatorSeizeTokens);
        emit Transfer(borrower, address(this), vars.protocolSeizeTokens);
        emit ReservesAdded(address(this), vars.protocolSeizeAmount, vars.totalReservesNew);

        return uint256(Error.NO_ERROR);
    }

    function getAccruedTokens() external view override returns (uint256) {
        return pbAdmin.getAccruedTokens(address(this), msg.sender);
    }    

    /*** Admin Functions ***/

    function _setPendingAdmin(address payable newPendingAdmin) external override returns (uint256) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PENDING_ADMIN_OWNER_CHECK);
        }

        address oldPendingAdmin = pendingAdmin;
        pendingAdmin = newPendingAdmin;

        emit NewPendingAdmin(oldPendingAdmin, newPendingAdmin);

        return uint256(Error.NO_ERROR);
    }

    function _acceptAdmin() external override returns (uint256) {
        if (msg.sender != pendingAdmin || msg.sender == address(0)) {
            return fail(Error.UNAUTHORIZED, FailureInfo.ACCEPT_ADMIN_PENDING_ADMIN_CHECK);
        }

        address oldAdmin = admin;
        address oldPendingAdmin = pendingAdmin;

        admin = pendingAdmin;

        pendingAdmin = payable(address(0));

        emit NewAdmin(oldAdmin, admin);
        emit NewPendingAdmin(oldPendingAdmin, pendingAdmin);

        return uint256(Error.NO_ERROR);
    }

    function _setPBAdmin(PBAdminInterface newPBAdmin) public override returns (uint256) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PB_ADMIN_OWNER_CHECK);
        }

        PBAdminInterface oldPBAdmin = pbAdmin;
        require(newPBAdmin.isPBAdmin(), "PToken: marker method returned false");

        pbAdmin = newPBAdmin;

        emit NewPBAdmin(oldPBAdmin, newPBAdmin);

        return uint256(Error.NO_ERROR);
    }

    function _setReserveFactor(uint256 newReserveFactorMantissa) external override nonReentrant returns (uint256) {
        uint256 error = accrueInterest();
        if (error != uint256(Error.NO_ERROR)) {
            return fail(Error(error), FailureInfo.SET_RESERVE_FACTOR_ACCRUE_INTEREST_FAILED);
        }
        return _setReserveFactorFresh(newReserveFactorMantissa);
    }

    function _setReserveFactorFresh(uint256 newReserveFactorMantissa) internal returns (uint256) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_RESERVE_FACTOR_ADMIN_CHECK);
        }

        if (accrualBlockNumber != getBlockNumber()) {
            return fail(Error.MARKET_NOT_FRESH, FailureInfo.SET_RESERVE_FACTOR_FRESH_CHECK);
        }

        if (newReserveFactorMantissa > reserveFactorMaxMantissa) {
            return fail(Error.BAD_INPUT, FailureInfo.SET_RESERVE_FACTOR_BOUNDS_CHECK);
        }

        uint256 oldReserveFactorMantissa = reserveFactorMantissa;
        reserveFactorMantissa = newReserveFactorMantissa;

        emit NewReserveFactor(oldReserveFactorMantissa, newReserveFactorMantissa);

        return uint256(Error.NO_ERROR);
    }

    function _addReservesInternal(uint256 addAmount) internal nonReentrant returns (uint256) {
        uint256 error = accrueInterest();
        if (error != uint256(Error.NO_ERROR)) {
            return fail(Error(error), FailureInfo.ADD_RESERVES_ACCRUE_INTEREST_FAILED);
        }

        (error, ) = _addReservesFresh(addAmount);
        return error;
    }

    function _addReservesFresh(uint256 addAmount) internal returns (uint256, uint256) {
        uint256 totalReservesNew;
        uint256 actualAddAmount;

        if (accrualBlockNumber != getBlockNumber()) {
            return (fail(Error.MARKET_NOT_FRESH, FailureInfo.ADD_RESERVES_FRESH_CHECK), actualAddAmount);
        }

        actualAddAmount = doTransferIn(msg.sender, addAmount);

        totalReservesNew = totalReserves + actualAddAmount;

        require(totalReservesNew >= totalReserves, "PToken: add reserves unexpected overflow");
        totalReserves = totalReservesNew;

        emit ReservesAdded(msg.sender, actualAddAmount, totalReservesNew);

        return (uint256(Error.NO_ERROR), actualAddAmount);
    }

    function _reduceReserves(uint256 reduceAmount) external override nonReentrant returns (uint256) {
        uint256 error = accrueInterest();
        if (error != uint256(Error.NO_ERROR)) {
            return fail(Error(error), FailureInfo.REDUCE_RESERVES_ACCRUE_INTEREST_FAILED);
        }

        return _reduceReservesFresh(reduceAmount);
    }

    function _reduceReservesFresh(uint256 reduceAmount) internal returns (uint256) {
        uint256 totalReservesNew;

        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.REDUCE_RESERVES_ADMIN_CHECK);
        }

        if (accrualBlockNumber != getBlockNumber()) {
            return fail(Error.MARKET_NOT_FRESH, FailureInfo.REDUCE_RESERVES_FRESH_CHECK);
        }

        if (getCashPrior() < reduceAmount) {
            return fail(Error.TOKEN_INSUFFICIENT_CASH, FailureInfo.REDUCE_RESERVES_CASH_NOT_AVAILABLE);
        }

        if (reduceAmount > totalReserves) {
            return fail(Error.BAD_INPUT, FailureInfo.REDUCE_RESERVES_VALIDATION);
        }

        totalReservesNew = totalReserves - reduceAmount;
        require(totalReservesNew <= totalReserves, "PToken: reduce reserves unexpected underflow");
        totalReserves = totalReservesNew;

        doTransferOut(payable(admin), reduceAmount);

        emit ReservesReduced(admin, reduceAmount, totalReservesNew);

        return uint256(Error.NO_ERROR);
    }

    function _setInterestModel(InterestModelInterface newInterestModel) public override returns (uint256) {
        uint256 error = accrueInterest();
        if (error != uint256(Error.NO_ERROR)) {
            return fail(Error(error), FailureInfo.SET_INTEREST_RATE_MODEL_ACCRUE_INTEREST_FAILED);
        }

        return _setInterestModelFresh(newInterestModel);
    }

    function _setInterestModelFresh(InterestModelInterface newInterestModel) internal returns (uint256) {
        InterestModelInterface oldInterestModel;

        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_INTEREST_RATE_MODEL_OWNER_CHECK);
        }

        if (accrualBlockNumber != getBlockNumber()) {
            return fail(Error.MARKET_NOT_FRESH, FailureInfo.SET_INTEREST_RATE_MODEL_FRESH_CHECK);
        }

        oldInterestModel = interestModel;
        require(newInterestModel.isInterestModel(), "PToken: marker method returned false");
        interestModel = newInterestModel;

        emit NewMarketInterestModel(oldInterestModel, newInterestModel);

        return uint256(Error.NO_ERROR);
    }

    function getCashPrior() internal view virtual returns (uint256);
    function doTransferIn(address from, uint256 amount) internal virtual returns (uint256);
    function doTransferOut(address payable to, uint256 amount) internal virtual;

    modifier nonReentrant() {
        require(_notEntered, "PToken: re-entered");
        _notEntered = false;
        _;
        _notEntered = true; 
    }
}
