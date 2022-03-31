// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

abstract contract InterestModelInterface {
    bool public constant isInterestModel = true;

    function getBorrowRate(uint256 cash, uint256 borrows, uint256 reserves) external view virtual returns (uint256);
    function getBorrowRateGDR(uint256 cash, uint256 borrows, uint256 reserves) external view virtual returns (uint256);
    function getSupplyRate(uint256 cash, uint256 borrows, uint256 reserves, uint reserveFactorMantissa) external view virtual returns (uint256);
}