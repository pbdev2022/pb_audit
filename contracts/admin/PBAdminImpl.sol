// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "../errrpt/ErrorReporter.sol";
import "../asset/PToken.sol";
import "../_govtoken/Clank.sol";
import "../oracle/PriceOracle.sol";
import "../math/DoubleMath.sol";
import "../math/UintSafeConvert.sol";
import "./PbUniAdmin.sol";
import "./PBAdminInterface.sol";
import "./PBAdminStorage.sol";

contract PBAdminImpl is PBAdminStorage, PBAdminInterface, PBAdminErrorReporter, ExpMath, DoubleMath, UintSafeConvert {    
    using SafeMath for uint;

    event MarketListed(PToken pToken);
    event MarketEntered(PToken pToken, address account);
    event MarketExited(PToken pToken, address account);
    event NewCloseFactor(uint oldCloseFactorMantissa, uint newCloseFactorMantissa);
    event NewCollateralFactor(PToken pToken, uint oldCollateralFactorMantissa, uint newCollateralFactorMantissa);
    event NewLiquidationIncentive(uint oldLiquidationIncentiveMantissa, uint newLiquidationIncentiveMantissa);
    event NewPriceOracle(PriceOracle oldPriceOracle, PriceOracle newPriceOracle);
    event NewPauseGuardian(address oldPauseGuardian, address newPauseGuardian);
    event ActionPaused(string action, bool pauseState);
    event ActionPaused(PToken pToken, string action, bool pauseState);
    event DistributedSupplierPb(PToken indexed pToken, address indexed supplier, uint pbDelta, uint pbSupplyIndex);
    event DistributedBorrowerPb(PToken indexed pToken, address indexed borrower, uint pbDelta, uint pbBorrowIndex);
    event NewBorrowCap(PToken indexed pToken, uint newBorrowCap);
    event NewBorrowCapGuardian(address oldBorrowCapGuardian, address newBorrowCapGuardian);
    event ClankGranted(address recipient, uint amount);
    event PbAccruedAdjusted(address indexed user, uint oldPbAccrued, uint newPbAccrued);
    event PbReceivableUpdated(address indexed user, uint oldPbReceivable, uint newPbReceivable);

    uint224 public constant pbInitialIndex = 1e36;
    uint internal constant closeFactorMinMantissa = 0.05e18; // 0.05
    uint internal constant closeFactorMaxMantissa = 0.9e18; // 0.9
    uint internal constant collateralFactorMaxMantissa = 0.9e18; // 0.9

    address clankAddress;

    constructor() {
        admin = msg.sender;
    }

    function setClankAddress(address clankAddress_) public {
        require(msg.sender == admin, "only admin can set clank address");
        clankAddress = clankAddress_;
    }

    function getAssetsIn(address account) external view returns (PToken[] memory) {
        PToken[] memory assetsIn = accountAssets[account];
        return assetsIn;
    }

    function checkMembership(address account, PToken pToken) external view returns (bool) {
        return marketsAccountMembership[address(pToken)][account];
    }

    function enterMarkets(address[] memory pTokens) public override returns (uint[] memory) {
        uint len = pTokens.length;
        uint[] memory results = new uint[](len);
        for (uint i = 0; i < len; i++) {
            PToken pToken = PToken(pTokens[i]);
            results[i] = uint(addToMarketInternal(pToken, msg.sender));
        }

        return results;
    }    

    function addToMarketInternal(PToken pToken, address borrower) internal returns (Error) {
        Market storage marketToJoin = markets[address(pToken)];
        if (!marketToJoin.isListed) {
            return Error.MARKET_NOT_LISTED;
        }

        if (marketsAccountMembership[address(pToken)][borrower] == false) {
            marketsAccountMembership[address(pToken)][borrower] = true;
            accountAssets[borrower].push(pToken);
            emit MarketEntered(pToken, borrower);            
        }

        return Error.NO_ERROR;
    }

    function exitMarket(address pTokenAddress) external override returns (uint) {
        PToken pToken = PToken(pTokenAddress);

        (uint oErr, uint tokensHeld, uint amountOwed, ) = pToken.getAccountSnapshot(msg.sender);
        require(oErr == 0, "exitMarket: getAccountSnapshot failed"); // semi-opaque error code

        if (amountOwed != 0) {
            return fail(Error.NONZERO_BORROW_BALANCE, FailureInfo.EXIT_MARKET_BALANCE_OWED);
        }

        uint allowed = redeemAllowedInternal(pTokenAddress, msg.sender, tokensHeld);
        if (allowed != 0) {
            return failOpaque(Error.REJECTION, FailureInfo.EXIT_MARKET_REJECTION, allowed);
        }

        if (!marketsAccountMembership[address(pToken)][msg.sender]) {
            return uint(Error.NO_ERROR);
        }

        delete marketsAccountMembership[address(pToken)][msg.sender];

        PToken[] memory userAssetList = accountAssets[msg.sender];
        uint len = userAssetList.length;
        uint assetIndex = len;
        for (uint i = 0; i < len; i++) {
            if (userAssetList[i] == pToken) {
                assetIndex = i;
                break;
            }
        }
        assert(assetIndex < len);

        PToken[] storage storedList = accountAssets[msg.sender];
        storedList[assetIndex] = storedList[storedList.length - 1];
        storedList.pop();

        emit MarketExited(pToken, msg.sender);

        return uint(Error.NO_ERROR);
    }

    function mintAllowed(address pToken, address minter, uint mintAmount) external override returns (uint) {
        require(!mintGuardianPaused[pToken], "mint is paused");
        if (!markets[pToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        mintAmount;

        updatePbSupplyIndex(pToken);
        distributeSupplierPb(pToken, minter);

        return uint(Error.NO_ERROR);
    }

    function redeemAllowed(address pToken, address redeemer, uint redeemTokens) external override returns (uint) {
        uint allowed = redeemAllowedInternal(pToken, redeemer, redeemTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        updatePbSupplyIndex(pToken);
        distributeSupplierPb(pToken, redeemer);

        return uint(Error.NO_ERROR);
    }

    function redeemAllowedInternal(address pToken, address redeemer, uint redeemTokens) internal view returns (uint) {
        if (!markets[pToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (!marketsAccountMembership[pToken][redeemer]) {    
            return uint(Error.NO_ERROR);
        }

        (Error err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(redeemer, PToken(pToken), redeemTokens, 0);
        if (err != Error.NO_ERROR) {
            return uint(err);
        }
        if (shortfall > 0) {
            return uint(Error.INSUFFICIENT_LIQUIDITY);
        }

        return uint(Error.NO_ERROR);
    }

    function redeemVerify(address pToken, address redeemer, uint redeemAmount, uint redeemTokens) external pure override {
        pToken;
        redeemer;

        if (redeemTokens == 0 && redeemAmount > 0) {
            revert("redeemTokens zero");
        }
    }

    function borrowAllowed(address pToken, address borrower, uint borrowAmount) external override returns (uint) {
        require(!borrowGuardianPaused[pToken], "borrow is paused");

        if (!markets[pToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (!marketsAccountMembership[pToken][borrower]) {    
            require(msg.sender == pToken, "sender must be pToken");

            Error err = addToMarketInternal(PToken(msg.sender), borrower);
            if (err != Error.NO_ERROR) {
                return uint(err);
            }

            assert(marketsAccountMembership[pToken][borrower]);
        }

        if (oracle.getUnderlyingPrice(PToken(pToken)) == 0) {
            return uint(Error.PRICE_ERROR);
        }


        uint borrowCap = borrowCaps[pToken];
        if (borrowCap != 0) {
            uint totalBorrows = PToken(pToken).totalBorrows();
            uint nextTotalBorrows = totalBorrows.add(borrowAmount);
            require(nextTotalBorrows < borrowCap, "market borrow cap reached");
        }

        (Error err2, , uint shortfall) = getHypotheticalAccountLiquidityInternal(borrower, PToken(pToken), 0, borrowAmount);
        if (err2 != Error.NO_ERROR) {
            return uint(err2);
        }
        if (shortfall > 0) {
            return uint(Error.INSUFFICIENT_LIQUIDITY);
        }

        updatePbBorrowIndex(pToken);

        return uint(Error.NO_ERROR);
    }

    function repayBorrowAllowed(
        address pToken,
        address payer,
        address borrower,
        uint repayAmount) external override returns (uint) {

        payer;
        borrower;
        repayAmount;

        if (!markets[pToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        updatePbBorrowIndex(pToken);

        return uint(Error.NO_ERROR);
    }

    function liquidateBorrowAllowed(
        address pTokenBorrowed,
        address pTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount) external view override returns (uint) {

        liquidator;

        if (!markets[pTokenBorrowed].isListed || !markets[pTokenCollateral].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        uint borrowBalance = PToken(pTokenBorrowed).borrowBalanceStored(borrower);

        if (isDeprecated(PToken(pTokenBorrowed))) {
            require(borrowBalance >= repayAmount, "Can not repay more than the total borrow");
        } else {
            (Error err, , uint shortfall) = getAccountLiquidityInternal(borrower);
            if (err != Error.NO_ERROR) {
                return uint(err);
            }

            if (shortfall == 0) {
                return uint(Error.INSUFFICIENT_SHORTFALL);
            }

            uint maxClose = mulExpUnitTrunc(Exp({mantissa: closeFactorMantissa}), borrowBalance);
            if (repayAmount > maxClose) {
                return uint(Error.TOO_MUCH_REPAY);
            }
        }
        return uint(Error.NO_ERROR);
    }

    function seizeAllowed(
        address pTokenCollateral,
        address pTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) external override returns (uint) {

        require(!seizeGuardianPaused, "seize is paused");

        seizeTokens;

        if (!markets[pTokenCollateral].isListed || !markets[pTokenBorrowed].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (PToken(pTokenCollateral).pbAdmin() != PToken(pTokenBorrowed).pbAdmin()) {
            return uint(Error.PB_ADMIN_MISMATCH);
        }

        updatePbSupplyIndex(pTokenCollateral);
        distributeSupplierPb(pTokenCollateral, borrower);
        distributeSupplierPb(pTokenCollateral, liquidator);

        return uint(Error.NO_ERROR);
    }

    function transferAllowed(address pToken, address src, address dst, uint transferTokens) external override returns (uint) {
        require(!transferGuardianPaused, "transfer is paused");

        uint allowed = redeemAllowedInternal(pToken, src, transferTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        updatePbSupplyIndex(pToken);
        distributeSupplierPb(pToken, src);
        distributeSupplierPb(pToken, dst);

        return uint(Error.NO_ERROR);
    }

    struct AccountLiquidityLocalVars {
        uint sumCollateral;
        uint sumBorrowPlusEffects;
        uint pTokenBalance;
        uint borrowBalance;
        uint exchangeRateMantissa;
        uint oraclePriceMantissa;
        Exp collateralFactor;
        Exp exchangeRate;
        Exp oraclePrice;
        Exp tokensToDenom;
    }

    function getAccountLiquidity(address account) public view returns (uint, uint, uint) {
        (Error err, uint liquidity, uint shortfall) = getHypotheticalAccountLiquidityInternal(account, PToken(address(0)), 0, 0);
        return (uint(err), liquidity, shortfall);
    }

    function getAccountLiquidityInternal(address account) internal view returns (Error, uint, uint) {
        return getHypotheticalAccountLiquidityInternal(account, PToken(address(0)), 0, 0);
    }

    function getHypotheticalAccountLiquidity(
        address account,
        address pTokenModify,
        uint redeemTokens,
        uint borrowAmount) public view returns (uint, uint, uint) {
        (Error err, uint liquidity, uint shortfall) = getHypotheticalAccountLiquidityInternal(account, PToken(pTokenModify), redeemTokens, borrowAmount);
        return (uint(err), liquidity, shortfall);
    }

    function getHypotheticalAccountLiquidityInternal(
        address account,
        PToken pTokenModify,
        uint redeemTokens,
        uint borrowAmount) internal view returns (Error, uint, uint) {

        AccountLiquidityLocalVars memory vars; // Holds all our calculation results
        uint oErr;

        PToken[] memory assets = accountAssets[account];
        for (uint i = 0; i < assets.length; i++) {
            PToken asset = assets[i];
  
            (oErr, vars.pTokenBalance, vars.borrowBalance, vars.exchangeRateMantissa) = asset.getAccountSnapshot(account);
            if (oErr != 0) { 
                return (Error.SNAPSHOT_ERROR, 0, 0);
            }
            vars.collateralFactor = Exp({mantissa: markets[address(asset)].collateralFactorMantissa});
            vars.exchangeRate = Exp({mantissa: vars.exchangeRateMantissa});

            vars.oraclePriceMantissa = oracle.getUnderlyingPrice(asset);
            if (vars.oraclePriceMantissa == 0) {
                return (Error.PRICE_ERROR, 0, 0);
            }
            vars.oraclePrice = Exp({mantissa: vars.oraclePriceMantissa});
            vars.tokensToDenom = mulExp(mulExp(vars.collateralFactor, vars.exchangeRate), vars.oraclePrice);
            vars.sumCollateral = mulExpUintTruncAddUint(vars.tokensToDenom, vars.pTokenBalance, vars.sumCollateral);
            vars.sumBorrowPlusEffects = mulExpUintTruncAddUint(vars.oraclePrice, vars.borrowBalance, vars.sumBorrowPlusEffects);

            if (asset == pTokenModify) {
                vars.sumBorrowPlusEffects = mulExpUintTruncAddUint(vars.tokensToDenom, redeemTokens, vars.sumBorrowPlusEffects);
                vars.sumBorrowPlusEffects = mulExpUintTruncAddUint(vars.oraclePrice, borrowAmount, vars.sumBorrowPlusEffects);
            }           
        }

        if (vars.sumCollateral > vars.sumBorrowPlusEffects) {
            return (Error.NO_ERROR, vars.sumCollateral - vars.sumBorrowPlusEffects, 0);
        } else {
            return (Error.NO_ERROR, 0, vars.sumBorrowPlusEffects - vars.sumCollateral);
        }
    }

    function liquidateCalculateSeizeTokens(address pTokenBorrowed, address pTokenCollateral, uint actualRepayAmount) external view override returns (uint, uint) {
        uint priceBorrowedMantissa = oracle.getUnderlyingPrice(PToken(pTokenBorrowed));
        uint priceCollateralMantissa = oracle.getUnderlyingPrice(PToken(pTokenCollateral));
        if (priceBorrowedMantissa == 0 || priceCollateralMantissa == 0) {
            return (uint(Error.PRICE_ERROR), 0);
        }

        uint exchangeRateMantissa = PToken(pTokenCollateral).exchangeRateStored(); // Note: reverts on error
        uint seizeTokens;
        Exp memory numerator;
        Exp memory denominator;
        Exp memory ratio;

        numerator = mulExp(Exp({mantissa: liquidationIncentiveMantissa}), Exp({mantissa: priceBorrowedMantissa}));
        denominator = mulExp(Exp({mantissa: priceCollateralMantissa}), Exp({mantissa: exchangeRateMantissa}));
        ratio = divExp(numerator, denominator);

        seizeTokens = mulUintExp(actualRepayAmount, ratio);

        return (uint(Error.NO_ERROR), seizeTokens);
    }

    function _setPriceOracle(PriceOracle newOracle) public returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PRICE_ORACLE_OWNER_CHECK);
        }

        PriceOracle oldOracle = oracle;

        oracle = newOracle;

        emit NewPriceOracle(oldOracle, newOracle);

        return uint(Error.NO_ERROR);
    }

    function _setCloseFactor(uint newCloseFactorMantissa) external returns (uint) {
    	require(msg.sender == admin, "only admin can set close factor");

        uint oldCloseFactorMantissa = closeFactorMantissa;
        closeFactorMantissa = newCloseFactorMantissa;
        emit NewCloseFactor(oldCloseFactorMantissa, closeFactorMantissa);

        return uint(Error.NO_ERROR);
    }

    function _setCollateralFactor(PToken pToken, uint newCollateralFactorMantissa) external returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_COLLATERAL_FACTOR_OWNER_CHECK);
        }

        Market storage market = markets[address(pToken)];
        if (!market.isListed) {
            return fail(Error.MARKET_NOT_LISTED, FailureInfo.SET_COLLATERAL_FACTOR_NO_EXISTS);
        }

        Exp memory newCollateralFactorExp = Exp({mantissa: newCollateralFactorMantissa});

        Exp memory highLimit = Exp({mantissa: collateralFactorMaxMantissa});
        if (lessThanExp(highLimit, newCollateralFactorExp)) {
            return fail(Error.INVALID_COLLATERAL_FACTOR, FailureInfo.SET_COLLATERAL_FACTOR_VALIDATION);
        }

        if (newCollateralFactorMantissa != 0 && oracle.getUnderlyingPrice(pToken) == 0) {
            return fail(Error.PRICE_ERROR, FailureInfo.SET_COLLATERAL_FACTOR_WITHOUT_PRICE);
        }

        uint oldCollateralFactorMantissa = market.collateralFactorMantissa;
        market.collateralFactorMantissa = newCollateralFactorMantissa;

        emit NewCollateralFactor(pToken, oldCollateralFactorMantissa, newCollateralFactorMantissa);

        return uint(Error.NO_ERROR);
    }

    function _setLiquidationIncentive(uint newLiquidationIncentiveMantissa) external returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_LIQUIDATION_INCENTIVE_OWNER_CHECK);
        }

        uint oldLiquidationIncentiveMantissa = liquidationIncentiveMantissa;
        liquidationIncentiveMantissa = newLiquidationIncentiveMantissa;

        emit NewLiquidationIncentive(oldLiquidationIncentiveMantissa, newLiquidationIncentiveMantissa);

        return uint(Error.NO_ERROR);
    }

    function _supportMarket(PToken pToken) external returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SUPPORT_MARKET_OWNER_CHECK);
        }

        if (markets[address(pToken)].isListed) {
            return fail(Error.MARKET_ALREADY_LISTED, FailureInfo.SUPPORT_MARKET_EXISTS);
        }

        pToken.isPToken(); 

        markets[address(pToken)] = Market({isListed: true, isPbed: false, collateralFactorMantissa: 0});

        _addMarketInternal(address(pToken));
        _initializeMarket(address(pToken));

        emit MarketListed(pToken);

        return uint(Error.NO_ERROR);
    }

    function _addMarketInternal(address pToken) internal {
        for (uint i = 0; i < allMarkets.length; i ++) {
            require(allMarkets[i] != PToken(pToken), "market already added");
        }
        allMarkets.push(PToken(pToken));
    }

    function _initializeMarket(address pToken) internal {
        uint32 blockNumber = safe32(getBlockNumber());

        PBMarketState storage supplyState = pbSupplyState[pToken];
        PBMarketState storage borrowState = pbBorrowState[pToken];

        if (supplyState.index == 0) {
            supplyState.index = pbInitialIndex;
        }

        if (borrowState.index == 0) {
            borrowState.index = pbInitialIndex;
        }

         supplyState.block = borrowState.block = blockNumber;
    }

    function _setMarketBorrowCaps(PToken[] calldata pTokens, uint[] calldata newBorrowCaps) external {
    	require(msg.sender == admin || msg.sender == borrowCapGuardian, "only admin or borrow cap guardian can set borrow caps"); 

        uint numMarkets = pTokens.length;
        uint numBorrowCaps = newBorrowCaps.length;

        require(numMarkets != 0 && numMarkets == numBorrowCaps, "invalid input");

        for(uint i = 0; i < numMarkets; i++) {
            borrowCaps[address(pTokens[i])] = newBorrowCaps[i];
            emit NewBorrowCap(pTokens[i], newBorrowCaps[i]);
        }
    }

    function _setBorrowCapGuardian(address newBorrowCapGuardian) external {
        require(msg.sender == admin, "only admin can set borrow cap guardian");

        address oldBorrowCapGuardian = borrowCapGuardian;

        borrowCapGuardian = newBorrowCapGuardian;

        emit NewBorrowCapGuardian(oldBorrowCapGuardian, newBorrowCapGuardian);
    }

    function _setPauseGuardian(address newPauseGuardian) public returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PAUSE_GUARDIAN_OWNER_CHECK);
        }

        address oldPauseGuardian = pauseGuardian;
        pauseGuardian = newPauseGuardian;

        emit NewPauseGuardian(oldPauseGuardian, pauseGuardian);

        return uint(Error.NO_ERROR);
    }

    function _setMintPaused(PToken pToken, bool state) public returns (bool) {
        require(markets[address(pToken)].isListed, "cannot pause a market that is not listed");
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        mintGuardianPaused[address(pToken)] = state;
        emit ActionPaused(pToken, "Mint", state);
        return state;
    }

    function _setBorrowPaused(PToken pToken, bool state) public returns (bool) {
        require(markets[address(pToken)].isListed, "cannot pause a market that is not listed");
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        borrowGuardianPaused[address(pToken)] = state;
        emit ActionPaused(pToken, "Borrow", state);
        return state;
    }

    function _setTransferPaused(bool state) public returns (bool) {
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        transferGuardianPaused = state;
        emit ActionPaused("Transfer", state);
        return state;
    }

    function _setSeizePaused(bool state) public returns (bool) {
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        seizeGuardianPaused = state;
        emit ActionPaused("Seize", state);
        return state;
    }

    function _become(PbUniAdmin pbUniAdmin) public {
        require(msg.sender == pbUniAdmin.admin(), "only uniadmin admin can change brains");
        require(pbUniAdmin._acceptImplementation() == 0, "change not authorized");
    }

    function updatePbSupplyIndex(address pToken) internal {
        PBMarketState storage supplyState = pbSupplyState[pToken];
        uint32 blockNumber = safe32(getBlockNumber());
        uint deltaBlocks = uint(blockNumber).sub(uint(supplyState.block));
        if (deltaBlocks > 0) {
            supplyState.block = blockNumber;
        }
    }

    function updatePbBorrowIndex(address pToken) internal {    
        PBMarketState storage borrowState = pbBorrowState[pToken];
        uint32 blockNumber = safe32(getBlockNumber());
        uint deltaBlocks = uint(blockNumber).sub(uint(borrowState.block));
        if (deltaBlocks > 0) { 
            borrowState.block = blockNumber;
        }
    }

    function distributeSupplierPb(address pToken, address supplier) internal {
        PBMarketState storage supplyState = pbSupplyState[pToken];
        uint supplyIndex = supplyState.index;
        uint supplierIndex = pbSupplierIndex[pToken][supplier];

        pbSupplierIndex[pToken][supplier] = supplyIndex;

        if (supplierIndex == 0 && supplyIndex >= pbInitialIndex) {
            supplierIndex = pbInitialIndex;
        }

        Double memory deltaIndex = Double({mantissa: supplyIndex.sub(supplierIndex)});

        uint supplierTokens = PToken(pToken).balanceOf(supplier);

        uint supplierDelta = mulUintDouble(supplierTokens, deltaIndex);

        uint supplierAccrued = pbAccrued[supplier].add(supplierDelta);
        pbAccrued[supplier] = supplierAccrued;

        emit DistributedSupplierPb(PToken(pToken), supplier, supplierDelta, supplyIndex);
    }

    function claimClank(address holder) public {
        return claimClank(holder, allMarkets);
    }

    function claimClank(address holder, PToken[] memory pTokens) public {
        address[] memory holders = new address[](1);
        holders[0] = holder;
        claimClank(holders, pTokens, true, true);
    }

    function claimClank(address[] memory holders, PToken[] memory pTokens, bool borrowers, bool suppliers) public {
        borrowers;

        for (uint i = 0; i < pTokens.length; i++) {
            PToken pToken = pTokens[i];
            require(markets[address(pToken)].isListed, "market must be listed");
            if (suppliers == true) {
                updatePbSupplyIndex(address(pToken));
                for (uint j = 0; j < holders.length; j++) {
                    distributeSupplierPb(address(pToken), holders[j]);
                }
            }
        }
        for (uint j = 0; j < holders.length; j++) {
            pbAccrued[holders[j]] = grantClankInternal(holders[j], pbAccrued[holders[j]]);
        }
    }

    function grantClankInternal(address user, uint amount) internal returns (uint) {    
        Clank clank = Clank(getClankAddress());
        uint clankRemaining = clank.balanceOf(address(this));
        if (amount > 0 && amount <= clankRemaining) {
            clank.transfer(user, amount);
            return 0;
        }
        return amount;
    }

    function grantClank(address recipient, uint amount) public {    
        require(msg.sender == admin, "only admin can grant Clank");
        uint amountLeft = grantClankInternal(recipient, amount);
        require(amountLeft == 0, "insufficient Clank for grant");
        emit ClankGranted(recipient, amount);
    }

    function getAllMarkets() public view returns (PToken[] memory) {
        return allMarkets;
    }

    function isDeprecated(PToken pToken) public view returns (bool) {
        return
            markets[address(pToken)].collateralFactorMantissa == 0 && 
            borrowGuardianPaused[address(pToken)] == true && 
            pToken.reserveFactorMantissa() == 1e18
        ;
    }

    function getBlockNumber() public view returns (uint) {
        return block.number;
    }

    function getClankAddress() public view returns (address) {
        require(clankAddress != address(0), "clank address is not set yet");
        return clankAddress;
    }
}
