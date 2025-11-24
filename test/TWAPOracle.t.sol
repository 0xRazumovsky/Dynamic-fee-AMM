// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/TWAPOracle.sol";

contract TWAPOracleTest is Test {
    TWAPOracle oracle;

    uint32 constant SAMPLE_INTERVAL = 60;
    uint16 constant SAMPLE_COUNT = 30;

    function setUp() public {
        oracle = new TWAPOracle(SAMPLE_INTERVAL, SAMPLE_COUNT, 3600, 2e18);
    }

    function testUpdate_increasesCumulative() public {
        uint256 price = 2e18; // 2.0
        vm.warp(1_000_000);
        oracle.update(price);

    uint256 beforeC = oracle.priceCumulativeLast();

        // advance 10 seconds
        vm.warp(block.timestamp + 10);
        oracle.update(price);

    uint256 afterC = oracle.priceCumulativeLast();
    assertEq(afterC - beforeC, price * 10);
    }

    function testGetTWAP_constantPrice() public {
        uint256 price = 3e18; // 3.0
        vm.warp(2_000_000);
        // initial update
        oracle.update(price);

        // write samples for 4 intervals (each 60s)
        for (uint32 i = 1; i <= 4; ++i) {
            vm.warp(2_000_000 + i * SAMPLE_INTERVAL);
            oracle.update(price);
        }

        // TWAP for 120s should equal price
        uint256 twap = oracle.getTWAP(120);
        assertEq(twap, price);
    }

    function testGetTWAP_period_must_be_multipleOfInterval_or_interp() public {
        uint256 price = 1e18;
        vm.warp(3_000_000);
        oracle.update(price);

        // advance one interval and store sample
        vm.warp(3_000_000 + SAMPLE_INTERVAL);
        oracle.update(price);

        vm.expectRevert();
        oracle.getTWAP(45); // not multiple of 60
    }

    function testVolatility_avgAbsoluteReturns() public {
        // simulate price path: 1.0, 1.1, 0.9, 1.2 over consecutive intervals
        uint256[4] memory prices = [uint256(1e18), 11e17, 9e17, 12e17];
        uint32 base = 4_000_000;
        vm.warp(base);
        oracle.update(prices[0]);
        for (uint32 i = 1; i < 4; ++i) {
            vm.warp(base + i * SAMPLE_INTERVAL);
            oracle.update(prices[i]);
        }
        // add one more interval to ensure 4 stored samples exist
        vm.warp(base + 4 * SAMPLE_INTERVAL);
        oracle.update(prices[3]);

    // get volatility and ensure it's positive and within reasonable bounds (< 100% daily)
    uint256 vol = oracle.getVolatilityOnchain(4);
    assertTrue(vol > 0);
    assertTrue(vol < 1e18);
    }

    function testGuards_preventMassivePriceSpike() public {
        // initial low price
        vm.warp(5_000_000);
        oracle.update(1e18);

    // create at least two samples so the implied price can be computed
    vm.warp(block.timestamp + SAMPLE_INTERVAL);
    oracle.update(1e18);
    vm.warp(block.timestamp + SAMPLE_INTERVAL);
    oracle.update(1e18);

    // fast forward small delta
    vm.warp(block.timestamp + 10);
    // price spike to 5x (maxRelativePriceChangeWAD=2e18 -> 2x allowed) should revert
    vm.expectRevert();
    oracle.update(5e18);
    }
}
