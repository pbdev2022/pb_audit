// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

abstract contract PBAdminInterface {
    bool public constant isPBAdmin = true;

    function enterMarkets(address[] calldata pTokenAddrs) external virtual returns (uint[] memory);
    function exitMarket(address pTokenAddr) external virtual returns (uint);

    function mintAllowed(address pTokenAddr, address minter, uint mintAmount) external virtual returns (uint);

    function redeemAllowed(address pTokenAddr, address redeemer, uint redeemTokens) external virtual returns (uint);
    function redeemVerify(address pTokenAddr, address redeemer, uint redeemAmount, uint redeemTokens) external virtual;

    function borrowAllowed(address pTokenAddr, address borrower, uint borrowAmount) external virtual returns (uint);
    function repayBorrowAllowed(address pTokenAddr, address payer, address borrower, uint repayAmount) external virtual returns (uint);
    function liquidateBorrowAllowed(address pTokenAddrBorrowed, address pTokenAddrCollateral, address liquidator, address borrower, uint repayAmount) external virtual returns (uint);
    function seizeAllowed(address pTokenAddrCollateral, address pTokenAddrBorrowed, address liquidator, address borrower, uint seizeTokens) external virtual returns (uint);
    function transferAllowed(address pTokenAddr, address src, address dst, uint transferTokens) external virtual returns (uint);

    function liquidateCalculateSeizeTokens(address pTokenAddrBorrowed, address pTokenAddrCollateral, uint repayAmount) external view virtual returns (uint, uint);

    function getAccruedTokens(address pTokenAddr, address holder) external view virtual returns (uint);
    function getClankBalance(address holder) external view virtual returns (uint);
    function clankTransferIn(address pTokenAddr, address payer, uint interestAmount) external virtual returns (bool);
}
