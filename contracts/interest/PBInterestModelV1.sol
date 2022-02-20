// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./InterestModelInterface.sol";
import "../math/SafeMath.sol";

contract PBInterestModelV1 is InterestModelInterface {
    using SafeMath for uint256;

    event NewInterestParams(uint256 baseRatePerBlock, uint256 multiplierPerBlock, uint256 govDeptRatio, uint256 jumpMultiplierPerBlock, uint256 kink_);
    event ChangeInterestRate(uint256 baseRatePerBlock, uint256 multiplierPerBlock, uint256 jumpMultiplierPerBlock, uint256 kink_);
    event ChangeGovDeptRatio(uint256 govDeptRatio);

    address public admin;

    uint256 public constant blocksPerYear = 2102400;
    uint256 public multiplierPerBlock;
    uint256 public baseRatePerBlock;
    uint256 public govDeptRatio;

    uint256 public jumpMultiplierPerBlock;
    uint256 public kink;

    constructor(uint256 baseRatePerYear, uint256 multiplierPerYear, uint256 govDeptRatio_, uint256 jumpMultiplierPerYear, uint256 kink_) {
        admin = msg.sender;

        require(jumpMultiplierPerYear >= multiplierPerYear, "PBInterestModelV1 : jumpMultiplierPerYear must be gratter than multiplierPerYear");

        baseRatePerBlock = baseRatePerYear.div(blocksPerYear);
        multiplierPerBlock = multiplierPerYear.div(blocksPerYear);
        govDeptRatio = govDeptRatio_;
        jumpMultiplierPerBlock = jumpMultiplierPerYear.div(blocksPerYear);
        kink = kink_;

        emit NewInterestParams(baseRatePerBlock, multiplierPerBlock, govDeptRatio, jumpMultiplierPerBlock, kink);
    }

    function changeRateRatio(uint256 baseRatePerYear, uint256 multiplierPerYear, uint256 jumpMultiplierPerYear, uint256 kink_) public {
        require(msg.sender == admin, "PBInterestModelV1 : only admin can change interest ratio");
        require(jumpMultiplierPerYear >= multiplierPerYear, "PBInterestModelV1 : jumpMultiplierPerYear must be gratter than multiplierPerYear");

        baseRatePerBlock = baseRatePerYear.div(blocksPerYear);
        multiplierPerBlock = multiplierPerYear.div(blocksPerYear);
        jumpMultiplierPerBlock = jumpMultiplierPerYear.div(blocksPerYear);
        kink = kink_;
        emit ChangeInterestRate(baseRatePerBlock, multiplierPerBlock, jumpMultiplierPerBlock, kink);
    }

    function changeGovDeptRatio(uint govDeptRatio_) public {
        require(msg.sender == admin, "PBInterestModelV1 : only admin can change Governace Dept Ratio");
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
        if (ur <= kink) {
            return ur.mul(multiplierPerBlock).div(1e18).add(baseRatePerBlock);
        } 
        else {
            uint normalRate = kink.mul(multiplierPerBlock).div(1e18).add(baseRatePerBlock);
            uint excessUr = ur.sub(kink);
            return excessUr.mul(jumpMultiplierPerBlock).div(1e18).add(normalRate);
        }        
    }

    function getSupplyRate(uint256 cash, uint256 borrows, uint256 reserves) public view override returns (uint256) {
        uint256 borrowRate = getBorrowRate(cash, borrows, reserves);
        return borrowRate.mul(govDeptRatio).div(1e18);
    }

    function getBorrowAPR(uint256 cash, uint256 borrows, uint256 reserves) external view override returns (uint256) {
        return getBorrowRate(cash, borrows, reserves).mul(blocksPerYear);
    }

    function getSupplyAPR(uint256 cash, uint256 borrows, uint256 reserves) external view override returns (uint256) {
        return getSupplyRate(cash, borrows, reserves).mul(blocksPerYear);
    }    
}
