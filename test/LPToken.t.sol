// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {LPToken} from "../src/LPToken.sol";


contract LPTokenTest is Test {
    LPToken public Lptoken;
    
    address public amm = address(0x1);
    address public user = address (0x2);

    function setUp() public {
        Lptoken = new LPToken("Test Token", "TST", 18, address(amm));
    }

    function testMintBurn_basic() public {
        vm.startPrank(amm);
        Lptoken.mint(user, 1000);
    
        assertEq(Lptoken.balanceOf(user), 1000);

        Lptoken.burn(user, 500);
        vm.stopPrank();
        assertEq(Lptoken.balanceOf(user), 500);
    }

    function testMint_onlyAMM_revert() public {
        vm.startPrank(user);
        vm.expectRevert("Not the owner");
        Lptoken.mint(user, 1000);
    
    }
}