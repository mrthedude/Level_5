// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
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
    uint256 MOCK_ETHUSD_PRICE = 2000;

    function setUp() external {
        lendingDeployer deployer = new lendingDeployer();
        contractOwner = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266; // default foundry testing address
        vm.deal(USER1, STARTING_USER_BALANCE);
        vm.deal(contractOwner, STARTING_USER_BALANCE);
        (lendingContract, myToken) = deployer.run();
    }

    ///////////// Testing receive() /////////////
    function testFuzz_receiveFunctionUpdatesContractEthBalance(uint256 amount) public {
        vm.assume(amount < STARTING_USER_BALANCE);
        vm.prank(USER1);
        (bool success,) = address(lendingContract).call{value: amount}("");
        require(success, "transfer failed");
        assertEq(address(lendingContract).balance, amount);
    }

    ///////////// Testing allowTokenAsCollateral() /////////////
    function testFuzz_revertWhen_allowTokenCallIsNotOwner(address notOwner) public {
        vm.assume(notOwner != contractOwner);
        vm.startPrank(notOwner);
        vm.deal(notOwner, 10 ether);
        vm.expectRevert(lending.notAuthorizedToCallThisFunction.selector);
        lendingContract.allowTokenAsCollateral(myToken, 150e18);
        vm.stopPrank();
    }

    function testFuzz_minimumCollateralizationRatioIsSetProperly(uint256 MCR) public {
        vm.prank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, MCR);
        assertEq(lendingContract.getTokenMinimumCollateralizationRatio(myToken), MCR);
    }

    ///////////// Testing removeTokenAsCollateral() /////////////
    function testFuzz_revertWhen_removeTokenCallIsNotOwner(address notOwner) public {
        vm.assume(notOwner != contractOwner);
        vm.startPrank(notOwner);
        vm.deal(notOwner, 10 ether);
        vm.expectRevert(lending.notAuthorizedToCallThisFunction.selector);
        lendingContract.removeTokenAsCollateral(myToken);
        vm.stopPrank();
    }

    function testFuzz_revertWhen_callingRemoveTokenOnSomethingNotInTheTokenList(IERC20 tokenNotOnTheList) public {
        vm.assume(tokenNotOnTheList != myToken);
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 150e18);
        vm.expectRevert(lending.notEligibleAsCollateral.selector);
        lendingContract.removeTokenAsCollateral(tokenNotOnTheList);
        vm.stopPrank();
    }

    function testFuzz_revertWhen_removingTokenFromListWithAnOpenDebtPosition(uint256 debtAmount) public {
        vm.assume(0 < debtAmount && debtAmount < MAX_TOKEN_SUPPLY);
        vm.startPrank(contractOwner);
        myToken.approve(address(lendingContract), debtAmount);
        lendingContract.allowTokenAsCollateral(myToken, 150e18);
        lendingContract.deposit(myToken, debtAmount);
        vm.expectRevert(lending.cannotRemoveFromAllowedTokensListWhenCollateralIsInContract.selector);
        lendingContract.removeTokenAsCollateral(myToken);
        vm.stopPrank();
    }

    function test_cannotDepositRemovedTokenAsCollateral() public {
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 150e18);
        lendingContract.removeTokenAsCollateral(myToken);
        vm.expectRevert(lending.notEligibleAsCollateral.selector);
        lendingContract.deposit(myToken, 1);
        vm.stopPrank();
    }

    ///////////// Testing deposit() /////////////
    function testFuzz_revertWhen_tokenIsNotOnAllowList(IERC20 notAllowedToken) public {
        vm.assume(notAllowedToken != myToken);
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 150e18);
        vm.expectRevert(lending.notEligibleAsCollateral.selector);
        lendingContract.deposit(notAllowedToken, 1);
        vm.stopPrank();
    }

    function test_revertWhen_depositAmountIsZero() public {
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 150e18);
        vm.expectRevert(lending.inputMustBeGreaterThanZero.selector);
        lendingContract.deposit(myToken, 0);
        vm.stopPrank();
    }

    function test_revertWhen_borrowingMarketIsFrozen() public {
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 150e18);
        lendingContract.freezeBorrowingMarket(myToken);
        vm.expectRevert(lending.borrowingMarketIsFrozen.selector);
        lendingContract.deposit(myToken, 1);
        vm.stopPrank();
    }

    function testFuzz_depositAmountIncreasesContractBalance(uint256 depositAmount) public {
        vm.assume(depositAmount > 0 && depositAmount <= MAX_TOKEN_SUPPLY);
        vm.startPrank(contractOwner);
        myToken.approve(address(lendingContract), depositAmount);
        lendingContract.allowTokenAsCollateral(myToken, 150e18);
        lendingContract.deposit(myToken, depositAmount);
        vm.stopPrank();
        assertEq(myToken.balanceOf(address(lendingContract)), depositAmount);
    }

    ///////////// Testing withdraw() /////////////
}
