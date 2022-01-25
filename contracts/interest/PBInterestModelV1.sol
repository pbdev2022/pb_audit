// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "./InterestModelInterface.sol";
import "../math/SafeMath.sol";

contract PBInterestModelV1 is InterestModelInterface {
    using SafeMath for uint256;

    event NewInterestParams(uint256 baseRatePerBlock, uint256 multiplierPerBlock, uint256 govDeptRatio);
    event ChangeInterestRate(uint256 baseRatePerBlock, uint256 multiplierPerBlock);
    event ChangeGovDeptRatio(uint256 govDeptRatio);

    address public admin;

    uint256 public constant blocksPerYear = 2102400;
    uint256 public multiplierPerBlock;
    uint256 public baseRatePerBlock;
    uint256 public govDeptRatio;

    constructor(uint256 baseRatePerYear, uint256 multiplierPerYear, uint govDeptRatio_) {
        admin = msg.sender;

        baseRatePerBlock = baseRatePerYear.div(blocksPerYear);
        multiplierPerBlock = multiplierPerYear.div(blocksPerYear);
        govDeptRatio = govDeptRatio_;

        emit NewInterestParams(baseRatePerBlock, multiplierPerBlock, govDeptRatio);
    }

    function changeRateRatio(uint256 baseRatePerYear, uint256 multiplierPerYear) public {
        require(msg.sender == admin, "only admin can change interest ratio");
        baseRatePerBlock = baseRatePerYear.div(blocksPerYear);
        multiplierPerBlock = multiplierPerYear.div(blocksPerYear);
        emit ChangeInterestRate(baseRatePerBlock, multiplierPerBlock);
    }

    function changeGovDeptRatio(uint govDeptRatio_) public {
        require(msg.sender == admin, "only admin can change Governace Dept Ratio");
        govDeptRatio = govDeptRatio_;
        emit ChangeGovDeptRatio(govDeptRatio);
    }    

    function utilizationRate(uint256 cash, uint256 borrows, uint256 reserves) public pure returns (uint256) {
        if (borrows == 0) {
            return 0;
        }

        uint256 ret = borrows.mul(1e18).div(cash.add(borrows).sub(reserves));
        return ret;
    }

    function getBorrowRate(uint256 cash, uint256 borrows, uint256 reserves) public view override returns (uint256) {
        uint256 ur = utilizationRate(cash, borrows, reserves);
        return ur.mul(multiplierPerBlock).div(1e18).add(baseRatePerBlock);
    }

    function getSupplyRate(uint256 cash, uint256 borrows, uint256 reserves, uint256 reserveFactorMantissa) public view override returns (uint256) {
        reserveFactorMantissa;  // not using 

        uint256 borrowRate = getBorrowRate(cash, borrows, reserves);
        return borrowRate.mul(govDeptRatio).div(1e18);
    }
}
