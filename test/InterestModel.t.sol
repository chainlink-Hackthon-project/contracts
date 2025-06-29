// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "../src/PoolContract/InterestModel.sol";

contract InterestModelTest is Test {
    using InterestModel for uint256;

    function testUtilization_zeroBorrows() pure public {
        uint256 utr = InterestModel.utilizationRate({ cash: 1e18, borrows: 0 });
        // when there are no borrows, utilization is defined to be zero
        assertEq(utr, 0);
    }

    function testUtilization_zeroCashPositiveBorrows() pure public {
        uint256 utr = InterestModel.utilizationRate({ cash: 0, borrows: 1e18 });
        assertEq(utr, InterestModel.BPS);
    }

    function testUtilization_normal() pure  public {
        // cash = 50, borrows = 50 → U = 50%
        uint256 utr = InterestModel.utilizationRate({ cash: 50, borrows: 50 });
        assertEq(utr, InterestModel.BPS / 2);
    }

    function testGetBorrowRate_belowKink() pure  public {
        uint256 base = 200;      // 2%
        uint256 slope1 = 800;    // 8% per 100% utilization
        uint256 slope2 = 2000;   // irrelevant here
        uint256 kink = 50_00;    // 50%

        // U = 25% → (base + U * slope1 / BPS)
        uint256 utr = 25_00;
        uint256 br = InterestModel.getBorrowRate(
            utr,
            base,
            slope1,
            slope2,
            kink
        );
        // expected = 200 + 2500*800/10000 = 200 + 200 = 400
        assertEq(br, 200 + (utr * slope1) / InterestModel.BPS);
    }

    function testGetBorrowRate_aboveKink() pure public {
        uint256 base = 100;      
        uint256 slope1 = 1000;   
        uint256 slope2 = 5000;   
        uint256 kink = 40_00;    // 40%

        // U = 60%
        uint256 utr = 60_00;
        uint256 normalRate = base + (kink * slope1) / InterestModel.BPS;
        uint256 expected = normalRate + ((utr - kink) * slope2) / InterestModel.BPS;
        uint256 br = InterestModel.getBorrowRate(
            utr, base, slope1, slope2, kink
        );
        assertEq(br, expected);
    }

    function testGetSupplyRate() pure public {
        uint256 utr = 80_00;            // 80%
        uint256 borrowRate = 500;       // 5%
        uint256 reserveFactor = 1000;   // 10%

        // effectiveBorrow = 500 * (10000 - 1000) / 10000 = 450
        // supplyRate = 8000 * 450 / 10000 = 360
        uint256 sr = InterestModel.getSupplyRate(
            utr, borrowRate, reserveFactor
        );
        assertEq(sr, (utr * (borrowRate * (InterestModel.BPS - reserveFactor) / InterestModel.BPS)) / InterestModel.BPS);
    }
}
