// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../asset/PToken.sol";
import "../oracle/PriceOracle.sol";

contract PBUniAdminStorage {
    address public nowAdminAddr;
    address public readyAdminAddr;
    address public pbAdminImpl;
    address public readyPBAdminImpl;
}

contract PBAdminStorage {
    struct Market {
        bool isListed;
        uint256 collateralFactorMantissa;
    }

    struct PBMarketState {
        uint224 index;
        uint32 block;
    }

    address public admin;
    address public pendingAdmin;
    address public pbAdminImplementation;
    address public pendingPBAdminImplementation;

    PriceOracle public oracle;

    uint256 public closeFactorMantissa;
    uint256 public liquidationIncentiveMantissa;

    mapping(address => PToken[]) public accountAssets;

    mapping(address => Market) public markets;
    mapping(address => mapping(address => bool)) public marketsAccountMembership;

    address public pauseGuardian;
    bool public transferGuardianPaused;
    bool public seizeGuardianPaused;
    mapping(address => bool) public mintGuardianPaused;
    mapping(address => bool) public borrowGuardianPaused;

    PToken[] public allMarkets;

    mapping(address => PBMarketState) public clankSupplyState;
    mapping(address => mapping(address => uint256)) public clankSupplierIndex;
    mapping(address => mapping(address => uint256)) public pTokenClankAccrued;

    address public borrowCapGuardian;
    mapping(address => uint256) public borrowCaps;

    mapping(address => uint) public clankSupplySpeeds;
}
