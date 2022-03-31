// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../admin/PBAdminInterface.sol";
import "../interest/InterestModelInterface.sol";
import "./EIP20Interface.sol";

contract PTokenStorage {
    bool internal _notEntered;

    string public name;
    string public symbol;
    uint8 public decimals;

    uint256 internal constant borrowRateMaxMantissa = 0.0005e16;
    uint256 internal constant supplyRateMaxMantissa = 0.0005e16;    
    uint256 internal constant borrowRateGDRMaxMantissa = 0.0005e16;    
    uint256 internal constant reserveFactorMaxMantissa = 1e18;

    address public admin;
    address public pendingAdmin;

    PBAdminInterface public pbAdmin;

    InterestModelInterface public interestModel;

    uint256 public reserveFactorMantissa;
    
    uint256 public accrualBorrowBlockNumber;    

    uint256 public borrowIndex;
    uint256 public totalBorrows;
    uint256 public totalReserves;
    uint256 public totalSupply;

    uint256 public borrowGDRIndex;    

    uint256 public supplyIndex;

    uint256 public initalBlockNumber;

    mapping (address => uint256) internal accountTokens;
    mapping (address => mapping (address => uint256)) internal transferAllowances;

    struct BorrowSnapshot {
        uint256 principal;
        uint256 interestIndex;
        uint256 interestGDRIndex;        
    }

    mapping(address => BorrowSnapshot) internal accountBorrows;

    uint256 public accrualSupplyBlockNumber;

    struct SupplySnapshot {
        uint256 interestIndex;
    }

    mapping(address => SupplySnapshot) internal accountSupplys;

    uint256 public constant protocolSeizeShareMantissa = 2.8e16; //2.8%
    uint256 public constant blocksPerDay = 5760;
}

abstract contract PTokenInterface is PTokenStorage {
    bool public constant isPToken = true;

    event AccrueBorrowInterest(uint256 cashPrior, uint256 interestAccumulated, uint256 borrowIndex, uint256 borrowGDRIndex, uint256 totalBorrows);
    event AccrueSupplyInterest(uint256 cashPrior, uint256 interestAccumulated, uint256 supplyIndex, uint256 totalSupply);
    event Mint(address minter, uint256 mintAmount, uint256 mintTokens);
    event Redeem(address redeemer, uint256 redeemAmount, uint256 redeemTokens);
    event Borrow(address borrower, uint256 borrowAmount, uint256 accountBorrows, uint256 totalBorrows);
    event RepayBorrow(address payer, address borrower, uint256 repayAmount, uint256 accountBorrows, uint256 totalBorrows);
    event LiquidateBorrow(address liquidator, address borrower, uint256 repayAmount, address pTokenCollateral, uint256 seizeTokens);

    event NewPendingAdmin(address oldPendingAdmin, address newPendingAdmin);
    event NewAdmin(address oldAdmin, address newAdmin);
    event NewPBAdmin(PBAdminInterface oldPBAdmin, PBAdminInterface newPbAdmin);
    event NewMarketInterestModel(InterestModelInterface oldInterestModel, InterestModelInterface newInterestModel);
    event NewReserveFactor(uint256 oldReserveFactorMantissa, uint256 newReserveFactorMantissa);
    event ReservesAdded(address benefactor, uint256 addAmount, uint256 newTotalReserves);
    event ReservesReduced(address admin, uint256 reduceAmount, uint256 newTotalReserves);
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    function transfer(address dst, uint256 amount) external virtual returns (bool);
    function transferFrom(address src, address dst, uint256 amount) external virtual returns (bool);
    function approve(address spender, uint256 amount) external virtual returns (bool);
    function allowance(address owner, address spender) external view virtual returns (uint256);
    function balanceOf(address owner) external view virtual returns (uint256);
    function balanceOfUnderlying(address owner) external view virtual returns (uint256);
    function getAccountSnapshot(address account) external view virtual returns (uint256, uint256, uint256, uint256);
    function borrowRatePerBlock() public view virtual returns (uint256);
    function supplyRatePerBlock() public view virtual returns (uint256);
    function totalBorrowsCurrent() external virtual returns (uint256);
    function borrowBalanceCurrent(address account) external virtual returns (uint256);
    function borrowBalanceStored(address account) public view virtual returns (uint256);
    function borrowGDRBalanceStored(address account) public view virtual returns (uint256);
    function supplyBalanceStored(address account) public view virtual returns (uint256);
    function getCash() external view virtual returns (uint256);
    function accrueInterest() public virtual returns (uint256);    
    function seize(address liquidator, address borrower, uint256 seizeTokens) external virtual returns (uint256);
    function getAccruedTokens() external view virtual returns (uint256);

    function _setPendingAdmin(address payable newPendingAdmin) external virtual returns (uint256);
    function _acceptAdmin() external virtual returns (uint256);
    function _setPBAdmin(PBAdminInterface newPBAdmin) public virtual returns (uint256);
    function _setReserveFactor(uint256 newReserveFactorMantissa) external virtual returns (uint256);
    function _reduceReserves(uint256 reduceAmount) external virtual returns (uint256);
    function _setInterestModel(InterestModelInterface newInterestModel) public virtual returns (uint256);
}

contract PErc20Storage {
    address public underlying;
}

abstract contract PErc20Interface is PErc20Storage {

    function mint(uint256 mintAmount) external virtual returns (uint256);
    function redeem(uint256 redeemTokens) external virtual returns (uint256);
    function borrow(uint256 borrowAmount) external virtual returns (uint256);
    function repayBorrow(uint256 repayAmount) external virtual returns (uint256);
    function repayBorrowBehalf(address borrower, uint256 repayAmount) external virtual returns (uint256);
    function liquidateBorrow(address borrower, uint256 repayAmount, PTokenInterface pTokenCollateral) external virtual returns (uint256);
    function sweepToken(EIP20Interface token) external virtual;

    function _addReserves(uint256 addAmount) external virtual returns (uint256);
}

contract PDelegationStorage {
    address public implementation;
}

abstract contract PDelegatorInterface is PDelegationStorage {
    event NewImplementation(address oldImplementation, address newImplementation);

    function _setImplementation(address implementation_, bool allowResign, bytes memory becomeImplementationData) public virtual;
}

abstract contract PDelegateInterface is PDelegationStorage {
    function _becomeImplementation(bytes memory data) public virtual;
    function _resignImplementation() public virtual;
}
