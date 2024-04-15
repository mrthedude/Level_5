// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, console} from "forge-std/Test.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {lendingDeployer} from "../../script/Deploy_Lending.s.sol";
import {lending} from "../../src/Lending.sol";
import {token} from "../../src/ERC20_token.sol";

contract Lending_Test is Test, lendingDeployer {
    lending public lendingContract;
    token public myToken;
    HelperConfig public helperConfig;
    address public contractOwner;
    uint256 public STARTING_USER_BALANCE = 10 ether;
    address USER1 = address(1);
    uint256 ethDecimals = 10 ** 18;
    uint256 MAX_TOKEN_SUPPLY = 100000e18;
    uint256 MOCK_ETH_PRICE = 2000;

    function setUp() external {
        lendingDeployer deployer = new lendingDeployer();
        contractOwner = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
        vm.deal(USER1, STARTING_USER_BALANCE);
        vm.deal(contractOwner, STARTING_USER_BALANCE);
        (lendingContract, myToken) = deployer.run();
    }
}
