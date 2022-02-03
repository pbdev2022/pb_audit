// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "../errrpt/ErrorReporter.sol";
import "../asset/PToken.sol";
import "../_govtoken/Clank.sol";
import "../oracle/PriceOracle.sol";
import "../math/DoubleMath.sol";
import "../math/UintSafeConvert.sol";
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
    event DistributedSupplierPB(PToken indexed pToken, address indexed supplier, uint pbDelta, uint pbSupplyIndex);
    event NewBorrowCap(PToken indexed pToken, uint newBorrowCap);
    event NewBorrowCapGuardian(address oldBorrowCapGuardian, address newBorrowCapGuardian);
    event ClankGranted(address recipient, uint amount);

    uint224 public constant pbInitialIndex = 1e36;
    uint internal constant collateralFactorMaxMantissa = 0.9e18; // 0.9

    address clankAddress;

    constructor() {
        admin = msg.sender;
    }

    function uint2str(uint _i) internal pure returns (string memory _uintAsString) {
        if (_i == 0) {
            return "0";
        }
        uint j = _i;
        uint len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint k = len;
        while (_i != 0) {
            k = k-1;
            uint8 temp = (48 + uint8(_i - _i / 10 * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }
        return string(bstr);
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

    function enterMarkets(address[] memory pTokenAddrs) public override returns (uint[] memory) {
        uint len = pTokenAddrs.length;
        uint[] memory results = new uint[](len);
        for (uint i = 0; i < len; i++) {
            PToken pToken = PToken(pTokenAddrs[i]);
            results[i] = uint(_addToMarketInternal(pToken, msg.sender));
        }

        return results;
    }    

    function _addToMarketInternal(PToken pToken, address borrower) internal returns (Error) {
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

    function exitMarket(address pTokenAddr) external override returns (uint) {
        PToken pToken = PToken(pTokenAddr);

        (uint oErr, uint tokensHeld, uint amountOwed, ) = pToken.getAccountSnapshot(msg.sender);

        require(oErr == 0, "exitMarket: getAccountSnapshot failed"); 
        require(amountOwed == 0, "nonzero borrow balance");

        uint allowed = _redeemAllowedInternal(pTokenAddr, msg.sender, tokensHeld);
        require(allowed == 0, uint2str(allowed));

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

        _updatePbSupplyIndex(pToken);
        _distributeSupplierPb(pToken, minter);

        return uint(Error.NO_ERROR);
    }

    function redeemAllowed(address pToken, address redeemer, uint redeemTokens) external override returns (uint) {
        uint allowed = _redeemAllowedInternal(pToken, redeemer, redeemTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        _updatePbSupplyIndex(pToken);
        _distributeSupplierPb(pToken, redeemer);

        return uint(Error.NO_ERROR);
    }

    function _redeemAllowedInternal(address pTokenAddr, address redeemer, uint redeemTokens) internal view returns (uint) {
        if (!markets[pTokenAddr].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (!marketsAccountMembership[pTokenAddr][redeemer]) {    
            return uint(Error.NO_ERROR);
        }

        (Error err, , uint shortfall) = _getHypotheticalAccountLiquidityInternal(redeemer, PToken(pTokenAddr), redeemTokens, 0);
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

            Error err = _addToMarketInternal(PToken(msg.sender), borrower);
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

        (Error err2, , uint shortfall) = _getHypotheticalAccountLiquidityInternal(borrower, PToken(pToken), 0, borrowAmount);
        if (err2 != Error.NO_ERROR) {
            return uint(err2);
        }
        if (shortfall > 0) {
            return uint(Error.INSUFFICIENT_LIQUIDITY);
        }

        _updatePbBorrowIndex(pToken);

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

        _updatePbBorrowIndex(pToken);

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
            (Error err, , uint shortfall) = _getAccountLiquidityInternal(borrower);
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

        _updatePbSupplyIndex(pTokenCollateral);
        _distributeSupplierPb(pTokenCollateral, borrower);
        _distributeSupplierPb(pTokenCollateral, liquidator);

        return uint(Error.NO_ERROR);
    }

    function transferAllowed(address pToken, address src, address dst, uint transferTokens) external override returns (uint) {
        require(!transferGuardianPaused, "transfer is paused");

        uint allowed = _redeemAllowedInternal(pToken, src, transferTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        _updatePbSupplyIndex(pToken);
        _distributeSupplierPb(pToken, src);
        _distributeSupplierPb(pToken, dst);

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
        (Error err, uint liquidity, uint shortfall) = _getHypotheticalAccountLiquidityInternal(account, PToken(address(0)), 0, 0);
        return (uint(err), liquidity, shortfall);
    }

    function _getAccountLiquidityInternal(address account) internal view returns (Error, uint, uint) {
        return _getHypotheticalAccountLiquidityInternal(account, PToken(address(0)), 0, 0);
    }

    function getHypotheticalAccountLiquidity(
        address account,
        address pTokenAddrModify,
        uint redeemTokens,
        uint borrowAmount) public view returns (uint, uint, uint) {
        (Error err, uint liquidity, uint shortfall) = _getHypotheticalAccountLiquidityInternal(account, PToken(pTokenAddrModify), redeemTokens, borrowAmount);
        return (uint(err), liquidity, shortfall);
    }

    function _getHypotheticalAccountLiquidityInternal(
        address account,
        PToken pTokenModify,
        uint redeemTokens,
        uint borrowAmount) internal view returns (Error, uint, uint) {

        if (address(oracle) == address(0)) {
            return (Error.PRICE_ERROR, 0, 0);            
        }

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

    function liquidateCalculateSeizeTokens(address pTokenAddrBorrowed, address pTokenAddrCollateral, uint actualRepayAmount) external view override returns (uint, uint) {
        uint priceBorrowedMantissa = oracle.getUnderlyingPrice(PToken(pTokenAddrBorrowed));
        uint priceCollateralMantissa = oracle.getUnderlyingPrice(PToken(pTokenAddrCollateral));
        if (priceBorrowedMantissa == 0 || priceCollateralMantissa == 0) {
            return (uint(Error.PRICE_ERROR), 0);
        }

        uint exchangeRateMantissa = PToken(pTokenAddrCollateral).exchangeRateStored(); // Note: reverts on error
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

    function setPriceOracle(PriceOracle newOracle) public returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PRICE_ORACLE_OWNER_CHECK);
        }

        PriceOracle oldOracle = oracle;

        oracle = newOracle;

        emit NewPriceOracle(oldOracle, newOracle);

        return uint(Error.NO_ERROR);
    }

    function setCloseFactor(uint newCloseFactorMantissa) external {
    	require(msg.sender == admin, "only admin can set close factor");

        uint oldCloseFactorMantissa = closeFactorMantissa;
        closeFactorMantissa = newCloseFactorMantissa;

        emit NewCloseFactor(oldCloseFactorMantissa, closeFactorMantissa);
    }

    function setCollateralFactor(PToken pToken, uint newCollateralFactorMantissa) external {
    	require(msg.sender == admin, "only admin can set collateral factor");

        Market storage market = markets[address(pToken)];
    	require(market.isListed, "market not listed");

        Exp memory newCollateralFactorExp = Exp({mantissa: newCollateralFactorMantissa});
        Exp memory highLimit = Exp({mantissa: collateralFactorMaxMantissa});

        require(!lessThanExp(highLimit, newCollateralFactorExp), "invalid collateral factor");
        require(address(oracle) != address(0), "price oracle not set yet");
        require (!(newCollateralFactorMantissa != 0 && oracle.getUnderlyingPrice(pToken) == 0) , "collateral factor price error");

        uint oldCollateralFactorMantissa = market.collateralFactorMantissa;
        market.collateralFactorMantissa = newCollateralFactorMantissa;

        emit NewCollateralFactor(pToken, oldCollateralFactorMantissa, newCollateralFactorMantissa);
    }

    function setLiquidationIncentive(uint newLiquidationIncentiveMantissa) external {
    	require(msg.sender == admin, "unauthorized");

        uint oldLiquidationIncentiveMantissa = liquidationIncentiveMantissa;
        liquidationIncentiveMantissa = newLiquidationIncentiveMantissa;

        emit NewLiquidationIncentive(oldLiquidationIncentiveMantissa, newLiquidationIncentiveMantissa);
    }

    function supportMarket(PToken pToken) external {
    	require(msg.sender == admin, "unauthorized");
    	require(markets[address(pToken)].isListed == false, "market already listed");

        pToken.isPToken(); 

        markets[address(pToken)] = Market({isListed: true, collateralFactorMantissa: 0});

        _addMarketInternal(address(pToken));
        _initializeMarket(address(pToken));

        emit MarketListed(pToken);
    }

    function unlistMarket(PToken pToken) public {
    	require(msg.sender == admin, "unauthorized");
    	require(markets[address(pToken)].isListed == true, "market note listed");

        markets[address(pToken)].isListed = false;
        _removeMarketInternal(address(pToken));
    }    

    function _addMarketInternal(address pTokenAddr) internal {
        for (uint i = 0; i < allMarkets.length; i ++) {
            require(allMarkets[i] != PToken(pTokenAddr), "market already added");
        }
        allMarkets.push(PToken(pTokenAddr));
    }

    function _removeMarketInternal(address pTokenAddr) internal {
        for (uint i = 0; i < allMarkets.length; i ++) {
            if (allMarkets[i] == PToken(pTokenAddr)) {
                delete allMarkets[i];
                break;
            }
        }
    }

    function _initializeMarket(address pTokenAddr) internal {
        uint32 blockNumber = safe32(getBlockNumber());

        PBMarketState storage supplyState = pbSupplyState[pTokenAddr];
        PBMarketState storage borrowState = pbBorrowState[pTokenAddr];

        if (supplyState.index == 0) {
            supplyState.index = pbInitialIndex;
        }

        if (borrowState.index == 0) {
            borrowState.index = pbInitialIndex;
        }

         supplyState.block = borrowState.block = blockNumber;
    }

    function setMarketBorrowCaps(PToken[] calldata pTokens, uint[] calldata newBorrowCaps) external {
    	require(msg.sender == admin || msg.sender == borrowCapGuardian, "only admin or borrow cap guardian can set borrow caps"); 

        uint numMarkets = pTokens.length;
        uint numBorrowCaps = newBorrowCaps.length;

        require(numMarkets != 0 && numMarkets == numBorrowCaps, "invalid input");

        for(uint i = 0; i < numMarkets; i++) {
            borrowCaps[address(pTokens[i])] = newBorrowCaps[i];
            emit NewBorrowCap(pTokens[i], newBorrowCaps[i]);
        }
    }

    function setBorrowCapGuardian(address newBorrowCapGuardian) external {
        require(msg.sender == admin, "only admin can set borrow cap guardian");

        address oldBorrowCapGuardian = borrowCapGuardian;

        borrowCapGuardian = newBorrowCapGuardian;

        emit NewBorrowCapGuardian(oldBorrowCapGuardian, newBorrowCapGuardian);
    }

    function setPauseGuardian(address newPauseGuardian) public {
    	require(msg.sender == admin, "unauthorized");        

        address oldPauseGuardian = pauseGuardian;
        pauseGuardian = newPauseGuardian;

        emit NewPauseGuardian(oldPauseGuardian, pauseGuardian);
    }

    function setMintPaused(PToken pToken, bool state) public returns (bool) {
        require(markets[address(pToken)].isListed, "cannot pause a market that is not listed");
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        mintGuardianPaused[address(pToken)] = state;
        emit ActionPaused(pToken, "Mint", state);
        return state;
    }

    function setBorrowPaused(PToken pToken, bool state) public returns (bool) {
        require(markets[address(pToken)].isListed, "cannot pause a market that is not listed");
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        borrowGuardianPaused[address(pToken)] = state;
        emit ActionPaused(pToken, "Borrow", state);
        return state;
    }

    function setTransferPaused(bool state) public returns (bool) {
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        transferGuardianPaused = state;
        emit ActionPaused("Transfer", state);
        return state;
    }

    function setSeizePaused(bool state) public returns (bool) {
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        seizeGuardianPaused = state;
        emit ActionPaused("Seize", state);
        return state;
    }

    function _updatePbSupplyIndex(address pToken) internal {
        PBMarketState storage supplyState = pbSupplyState[pToken];
        uint32 blockNumber = safe32(getBlockNumber());
        uint deltaBlocks = uint(blockNumber).sub(uint(supplyState.block));
        if (deltaBlocks > 0) {
            supplyState.block = blockNumber;
        }
    }

    function _updatePbBorrowIndex(address pToken) internal {    
        PBMarketState storage borrowState = pbBorrowState[pToken];
        uint32 blockNumber = safe32(getBlockNumber());
        uint deltaBlocks = uint(blockNumber).sub(uint(borrowState.block));
        if (deltaBlocks > 0) { 
            borrowState.block = blockNumber;
        }
    }

    function _distributeSupplierPb(address pTokenAddr, address supplier) internal {
        PBMarketState storage supplyState = pbSupplyState[pTokenAddr];
        uint supplyIndex = supplyState.index;
        uint supplierIndex = pbSupplierIndex[pTokenAddr][supplier];

        pbSupplierIndex[pTokenAddr][supplier] = supplyIndex;

        if (supplierIndex == 0 && supplyIndex >= pbInitialIndex) {
            supplierIndex = pbInitialIndex;
        }

        Double memory deltaIndex = Double({mantissa: supplyIndex.sub(supplierIndex)});

        uint supplierTokens = PToken(pTokenAddr).balanceOf(supplier);

        uint supplierDelta = mulUintDouble(supplierTokens, deltaIndex);

        uint supplierAccrued = pbAccrued[supplier].add(supplierDelta);
        pbAccrued[supplier] = supplierAccrued;

        emit DistributedSupplierPB(PToken(pTokenAddr), supplier, supplierDelta, supplyIndex);
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
                _updatePbSupplyIndex(address(pToken));
                for (uint j = 0; j < holders.length; j++) {
                    _distributeSupplierPb(address(pToken), holders[j]);
                }
            }
        }
        for (uint j = 0; j < holders.length; j++) {
            pbAccrued[holders[j]] = _grantClankInternal(holders[j], pbAccrued[holders[j]]);
        }
    }

    function _grantClankInternal(address user, uint amount) internal returns (uint) {    
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
        uint amountLeft = _grantClankInternal(recipient, amount);
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
