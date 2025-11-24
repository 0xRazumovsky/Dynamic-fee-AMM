// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract LPToken is ERC20, Ownable {
    uint8 private _decimals;
    address private immutable amm;

    event Mint(address indexed to, uint256 amount);
    event Burn(address indexed to, uint256 amount);

    modifier onlyAMM {
        require(address(amm) != address(0), "AMM not initializied");
        require(address(msg.sender) == amm, "Not the owner");
        _;
    }
 
    constructor(string memory name, string memory symbol, uint8 decimals_, address amm_) ERC20(name,symbol) Ownable(msg.sender) {
        _decimals = decimals_;
        amm = amm_;
    }

    function mint(address to, uint256 amount) external onlyAMM {
        _mint(to, amount);

        emit Mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyAMM {
        _burn(from, amount);

        emit Burn(from, amount);
    }

}