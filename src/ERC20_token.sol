// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

contract token is ERC20, Ownable {
    constructor(address owner) ERC20("Level5", "_LVL_5") Ownable(owner) {
        _mint(owner, 100000 * 10 ** decimals());
    }
}
