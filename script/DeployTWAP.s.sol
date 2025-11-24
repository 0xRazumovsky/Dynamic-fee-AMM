// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/TWAPOracle.sol";

/// @notice Deploy script for TWAPOracle. Use:
/// forge script script/DeployTWAP.s.sol:Deploy --rpc-url $RPC --private-key $PK --broadcast
contract Deploy is Script {
    function run() external {
        // read deploy key from env
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        // params: sampleInterval=60s, sampleCount=30, maxDeltaSeconds=3600, maxRelPrice=2x
        TWAPOracle oracle = new TWAPOracle(60, 30, 3600, 2e18);

        // Optionally seed an initial update from deployer account (would need an off-chain price)
        // oracle.update(1e18);

        console.log("TWAPOracle deployed at", address(oracle));

        vm.stopBroadcast();
    }
}
