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
        updateInterestModelInternal(baseRatePerYear, multiplierPerYear, govDeptRatio_, jumpMultiplierPerYear, kink_);
    }

    function updateInterestModel(uint256 baseRatePerYear, uint256 multiplierPerYear, uint256 govDeptRatio_, uint256 jumpMultiplierPerYear, uint256 kink_) public {
        require(msg.sender == admin, "only admin may call this function.");
        updateInterestModelInternal(baseRatePerYear, multiplierPerYear, govDeptRatio_, jumpMultiplierPerYear, kink_);
    }

    function updateInterestModelInternal(uint256 baseRatePerYear, uint256 multiplierPerYear, uint256 govDeptRatio_, uint256 jumpMultiplierPerYear, uint256 kink_) internal {
        baseRatePerBlock = baseRatePerYear.div(blocksPerYear);
        multiplierPerBlock = (multiplierPerYear.mul(1e18)).div(blocksPerYear.mul(kink_));
        govDeptRatio = govDeptRatio_;
        jumpMultiplierPerBlock = jumpMultiplierPerYear.div(blocksPerYear);
        kink = kink_;

        emit NewInterestParams(baseRatePerBlock, multiplierPerBlock, govDeptRatio, jumpMultiplierPerBlock, kink);
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

    function getBorrowRateGDR(uint256 cash, uint256 borrows, uint256 reserves) public view override returns (uint256) {
        if (govDeptRatio > 0) {
            uint256 br = getBorrowRate(cash, borrows, reserves);
            uint256 borrowRateGDR = (br.mul(govDeptRatio)).div(uint256(1e18).sub(govDeptRatio));
            return borrowRateGDR;
        }
        else {
            return 0;
        }
    }    

    function getSupplyRate(uint256 cash, uint256 borrows, uint256 reserves, uint reserveFactorMantissa) external view override returns (uint256) {
        uint256 oneMinusReserveFactor = uint(1e18).sub(reserveFactorMantissa);
        uint256 borrowRate = getBorrowRate(cash, borrows, reserves);
        uint256 rateToPool = borrowRate.mul(oneMinusReserveFactor).div(1e18);
        return utilizationRate(cash, borrows, reserves).mul(rateToPool).div(1e18);
    }
}
