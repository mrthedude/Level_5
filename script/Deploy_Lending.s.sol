// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "lib/forge-std/src/Test.sol";
import {token} from "../src/ERC20_token.sol";
import {lending} from "../src/Lending.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract lendingDeployer is Script, HelperConfig {
    function run() public returns (lending, token) {
        HelperConfig helperConfig = new HelperConfig();
        address owner = helperConfig.getOwnerAddress();
        address ethUsdPriceFeed = helperConfig.activeNetworkConfig();
        vm.startBroadcast();
        token myToken = new token(owner);
        lending LendingContract = new lending(owner, ethUsdPriceFeed);
        vm.stopBroadcast();
        return (LendingContract, myToken);
    }
}
