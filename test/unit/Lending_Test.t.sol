// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Test} from "lib/forge-std/src/Test.sol";
import {console} from "lib/forge-std/src/console.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {lendingDeployer} from "../../script/Deploy_Lending.s.sol";
import {lending} from "../../src/Lending.sol";
import {token} from "../../src/ERC20_token.sol";

contract Lending_Test is Test, lendingDeployer {
    lending public lendingContract;
    token public myToken;
    HelperConfig public helperConfig;
    address public contractOwner;
    uint256 public STARTING_USER_BALANCE = 1000 ether;
    address USER1 = address(1);
    uint256 MAX_TOKEN_SUPPLY = 100000e18;
    uint256 SECONDS_IN_A_DAY = 86400;
    uint256 SECONDS_IN_ONE_MONTH = 2628000;
    uint256 SECONDS_IN_A_HALF_YEAR = 15768000;
    uint256 SECONDS_IN_A_YEAR = 31536000;

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
    function test_reverWhen_WithdrawAmountIsZero() public {
        vm.startPrank(contractOwner);
        myToken.approve(address(lendingContract), 100);
        lendingContract.allowTokenAsCollateral(myToken, 150e18);
        lendingContract.deposit(myToken, 100);
        vm.expectRevert(lending.inputMustBeGreaterThanZero.selector);
        lendingContract.withdraw(myToken, 0);
        vm.stopPrank();
    }

    function test_revertWhen_WithdrawCalledWithAnOpenDebtPosition() public {
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 150e18);
        myToken.approve(address(lendingContract), 100e18);
        (bool success,) = address(lendingContract).call{value: 1 ether}("");
        require(success, "transfer failed");
        lendingContract.deposit(myToken, 100e18);
        lendingContract.borrow(myToken, 0.00001 ether);
        vm.expectRevert(lending.cannotWithdrawCollateralWithOpenDebtPositions.selector);
        lendingContract.withdraw(myToken, 1e18);
        vm.stopPrank();
    }

    function testFuzz_revertWhen_withdrawRequestExceedsDepositAmount(uint256 withdrawAmount) public {
        vm.assume(withdrawAmount > 100e18);
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        myToken.approve(address(lendingContract), 200e18);
        lendingContract.deposit(myToken, 100e18);
        vm.expectRevert(lending.cannotWithdrawMoreCollateralThanWhatWasDeposited.selector);
        lendingContract.withdraw(myToken, withdrawAmount);
        vm.stopPrank();
    }

    function testFuzz_withdrawAmountIsSentBackToOwner(uint256 withdrawAmount) public {
        vm.assume(withdrawAmount > 0 && withdrawAmount <= 100e18);
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        myToken.approve(address(lendingContract), 100e18);
        lendingContract.deposit(myToken, 100e18);
        lendingContract.withdraw(myToken, withdrawAmount);
        vm.stopPrank();
        uint256 remainingAmountInContract = 100e18 - withdrawAmount;
        uint256 currentAmountInWallet = MAX_TOKEN_SUPPLY - remainingAmountInContract;
        vm.assertEq(myToken.balanceOf(contractOwner), currentAmountInWallet);
    }

    ///////////// Testing borrow() /////////////
    function test_revertWhen_borrowAmountIsZero() public {
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        (bool success,) = address(lendingContract).call{value: 1 ether}("");
        require(success, "transfer failed");
        myToken.approve(address(lendingContract), 100e18);
        lendingContract.deposit(myToken, 100e18);
        vm.expectRevert(lending.inputMustBeGreaterThanZero.selector);
        lendingContract.borrow(myToken, 0);
        vm.stopPrank();
    }

    function test_revertWhen_borrowAttemptOnAFrozenMarket() public {
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        (bool success,) = address(lendingContract).call{value: 1 ether}("");
        require(success, "transfer failed");
        myToken.approve(address(lendingContract), 100e18);
        lendingContract.deposit(myToken, 100e18);
        lendingContract.freezeBorrowingMarket(myToken);
        vm.expectRevert(lending.borrowingMarketIsFrozen.selector);
        lendingContract.borrow(myToken, 0.001 ether);
        vm.stopPrank();
    }

    function testFuzz_revertWhen_notEnoughEthInContractForBorrow(uint256 borrowAmount) public {
        vm.assume(borrowAmount > 1 ether);
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        (bool success,) = address(lendingContract).call{value: 1 ether}("");
        require(success, "transfer failed");
        myToken.approve(address(lendingContract), MAX_TOKEN_SUPPLY);
        lendingContract.deposit(myToken, MAX_TOKEN_SUPPLY);
        vm.expectRevert(lending.notEnoughEthInContract.selector);
        lendingContract.borrow(myToken, borrowAmount);
        vm.stopPrank();
    }

    function test_revertWhen_borrowAmountExceedsCollateralizationLimit() public {
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        (bool success,) = address(lendingContract).call{value: 0.5 ether}("");
        require(success, "transfer failed");
        myToken.approve(address(lendingContract), 100e18);
        lendingContract.deposit(myToken, 100e18);
        vm.expectRevert(lending.notEnoughCollateralDepositedByUserToBorrowThisAmountOfEth.selector);
        lendingContract.borrow(myToken, 0.026 ether);
        vm.stopPrank();
    }

    function testFuzz_borrowAmountIsAddedToUserBalance(uint256 borrowAmount) public {
        vm.assume(borrowAmount > 0 && borrowAmount <= 0.025 ether);
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        (bool success,) = address(lendingContract).call{value: 0.5 ether}("");
        require(success, "transfer failed");
        myToken.approve(address(lendingContract), 105e18);
        lendingContract.deposit(myToken, 105e18);
        lendingContract.borrow(myToken, borrowAmount);
        vm.stopPrank();
        vm.assertEq(contractOwner.balance, STARTING_USER_BALANCE - 0.5 ether + borrowAmount);
    }

    ///////////// Testing repay() /////////////
    function test_revertWhen_repayInputIsZero() public {
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        (bool success,) = address(lendingContract).call{value: 0.5 ether}("");
        require(success, "transfer failed");
        myToken.approve(address(lendingContract), 105e18);
        lendingContract.deposit(myToken, 105e18);
        lendingContract.borrow(myToken, 0.025 ether);
        vm.expectRevert(lending.inputMustBeGreaterThanZero.selector);
        lendingContract.repay{value: 0}(myToken);
        vm.stopPrank();
    }

    function test_revertWhen_repayAmountIsGreaterThanMarketDebt() public {
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        (bool success,) = address(lendingContract).call{value: 0.5 ether}("");
        require(success, "transfer failed");
        myToken.approve(address(lendingContract), 105e18);
        lendingContract.deposit(myToken, 105e18);
        lendingContract.borrow(myToken, 0.025 ether);
        vm.expectRevert(lending.cannotRepayMoreThanuserEthMarketDebt.selector);
        lendingContract.repay{value: 0.02626 ether}(myToken);
        vm.stopPrank();
    }

    function testFuzz_logicIsCorrectWhenRepayAmountIsLessThanBorrowingFees(uint256 repayAmount) public {
        vm.assume(repayAmount > 0 && repayAmount < 0.00125 ether);
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        (bool success,) = address(lendingContract).call{value: 0.5 ether}("");
        require(success, "transfer failed");
        myToken.approve(address(lendingContract), 105e18);
        lendingContract.deposit(myToken, 105e18);
        lendingContract.borrow(myToken, 0.025 ether);
        lendingContract.repay{value: repayAmount}(myToken);
        vm.stopPrank();
        vm.assertEq(contractOwner.balance, STARTING_USER_BALANCE - 0.5 ether + 0.025 ether - repayAmount);
    }

    function test_logicIsCorrectWhenRepayAmountIsEqualToBorrowingFees() public {
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        (bool success,) = address(lendingContract).call{value: 0.5 ether}("");
        require(success, "transfer failed");
        myToken.approve(address(lendingContract), 105e18);
        lendingContract.deposit(myToken, 105e18);
        lendingContract.borrow(myToken, 0.025 ether);
        lendingContract.repay{value: 0.00125 ether}(myToken);
        vm.stopPrank();
        vm.assertEq(contractOwner.balance, STARTING_USER_BALANCE - 0.5 ether + 0.025 ether - 0.00125 ether);
    }

    function testFuzz_logicIsCorrectWhenRepayAmountIsGreaterThanBorrowingFees(uint256 repayAmount) public {
        vm.assume(repayAmount > 0.00125 ether && repayAmount <= 0.02625 ether);
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        (bool success,) = address(lendingContract).call{value: 0.5 ether}("");
        require(success, "transfer failed");
        myToken.approve(address(lendingContract), 105e18);
        lendingContract.deposit(myToken, 105e18);
        lendingContract.borrow(myToken, 0.025 ether);
        lendingContract.repay{value: repayAmount}(myToken);
        vm.stopPrank();
        vm.assertEq(contractOwner.balance, STARTING_USER_BALANCE - 0.5 ether + 0.025 ether - repayAmount);
    }

    ///////////// Testing fullLiquidation() /////////////
    function test_revertWhen_fullLiquidationInputIsZero() public {
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        (bool success,) = address(lendingContract).call{value: 0.5 ether}("");
        require(success, "transfer failed");
        myToken.approve(address(lendingContract), 105e18);
        lendingContract.deposit(myToken, 105e18);
        lendingContract.borrow(myToken, 0.025 ether);
        vm.expectRevert(lending.inputMustBeGreaterThanZero.selector);
        lendingContract.fullLiquidation{value: 0}(contractOwner, myToken);
        vm.stopPrank();
    }

    function test_revertWhen_exactDebtAmountIsntRepaid() public {
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        (bool success,) = address(lendingContract).call{value: 0.5 ether}("");
        require(success, "transfer failed");
        myToken.approve(address(lendingContract), 105e18);
        lendingContract.deposit(myToken, 105e18);
        lendingContract.borrow(myToken, 0.025 ether);
        vm.expectRevert(lending.exactDebtAmountMustBeRepaid.selector);
        lendingContract.fullLiquidation{value: 1 ether}(contractOwner, myToken);
        vm.stopPrank();
    }

    function testFuzz_revertWhen_cantFullLiquidationBecauseHealthFactorIsNotBelowCollateralizationLimit(
        uint256 borrowAmount
    ) public {
        vm.assume(borrowAmount > 0 && borrowAmount <= 0.025 ether);
        uint256 borrowingFee = borrowAmount * 0.05 ether / 1e18;
        uint256 totalUserDebt = borrowAmount + borrowingFee;
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        (bool success,) = address(lendingContract).call{value: 0.5 ether}("");
        require(success, "transfer failed");
        myToken.approve(address(lendingContract), 105e18);
        lendingContract.deposit(myToken, 105e18);
        lendingContract.borrow(myToken, borrowAmount);
        console.log(lendingContract.getUserHealthFactorByMarket(contractOwner, myToken));
        vm.expectRevert(lending.userIsNotEligibleForCompleteLiquidation.selector);
        lendingContract.fullLiquidation{value: totalUserDebt}(contractOwner, myToken);
        vm.stopPrank();
    }

    function testFuzz_revertWhen_cantFullLiquidationBecauseHealthFactorIsNotFarEnoughBelowCollateralizationLimit(
        uint256 tokensTaken
    ) public {
        vm.assume(tokensTaken > 0 && tokensTaken < 15.75e18);
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        (bool success,) = address(lendingContract).call{value: 0.5 ether}("");
        require(success, "transfer failed");
        myToken.approve(address(lendingContract), 120.75e18);
        lendingContract.deposit(myToken, 105e18);
        lendingContract.borrow(myToken, 0.025 ether);
        lendingContract.fundsAreSafu(contractOwner, myToken, tokensTaken);
        vm.expectRevert(lending.userIsNotEligibleForCompleteLiquidation.selector);
        lendingContract.fullLiquidation{value: 0.02625 ether}(contractOwner, myToken);
    }

    function testFuzz_completeLiquidationFunctionality(uint256 tokenAmount) public {
        vm.assume(tokenAmount >= 31.5e18 && tokenAmount < 105e18);
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        (bool success,) = address(lendingContract).call{value: 0.5 ether}("");
        require(success, "transfer failed");
        myToken.approve(address(lendingContract), 105e18 + tokenAmount);
        lendingContract.deposit(myToken, 105e18);
        lendingContract.borrow(myToken, 0.025 ether);
        lendingContract.fundsAreSafu(contractOwner, myToken, tokenAmount);
        lendingContract.fullLiquidation{value: 0.02625 ether}(contractOwner, myToken);
    }

    ///////////// Testing partialLiquidation() /////////////
    function test_revertWhen_inputForPartialLiquidationIsZero() public {
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        (bool success,) = address(lendingContract).call{value: 0.5 ether}("");
        require(success, "transfer failed");
        myToken.approve(address(lendingContract), 105e18);
        lendingContract.deposit(myToken, 105e18);
        lendingContract.borrow(myToken, 0.025 ether);
        vm.expectRevert(lending.inputMustBeGreaterThanZero.selector);
        lendingContract.partialLiquidation{value: 0}(contractOwner, myToken);
        vm.stopPrank();
    }

    function testFuzz_revertWhen_cantPartiallyLiquidateBecauseCollateralFactorIsAboveTheMinimum(uint256 borrowAmount)
        public
    {
        vm.assume(borrowAmount <= 0.025 ether && borrowAmount > 0);
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        (bool success,) = address(lendingContract).call{value: 0.5 ether}("");
        require(success, "transfer failed");
        myToken.approve(address(lendingContract), 105e18);
        lendingContract.deposit(myToken, 105e18);
        lendingContract.borrow(myToken, borrowAmount);
        vm.expectRevert(lending.userIsNotEligibleForPartialLiquidation.selector);
        lendingContract.getPartialLiquidationSpecs(contractOwner, myToken);
        vm.stopPrank();
    }

    function testFuzz_revertWhen_cantPartiallyLiquidiateBecauseUserIsEligibleForFullLiquidation(uint256 takenTokens)
        public
    {
        vm.assume(takenTokens >= 31.5e18 && takenTokens < 105e18);
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        (bool success,) = address(lendingContract).call{value: 0.5 ether}("");
        require(success, "transfer failed");
        myToken.approve(address(lendingContract), 105e18 + takenTokens);
        lendingContract.deposit(myToken, 105e18);
        lendingContract.borrow(myToken, 0.025 ether);
        lendingContract.fundsAreSafu(contractOwner, myToken, takenTokens);
        vm.expectRevert(lending.userIsNotEligibleForPartialLiquidation.selector);
        lendingContract.getPartialLiquidationSpecs(contractOwner, myToken);
        vm.stopPrank();
    }

    function testFuzz_revertWhen_exactDebtAmountIsNotRepaid(uint256 debtAmount) public {
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        (bool success,) = address(lendingContract).call{value: 0.5 ether}("");
        require(success, "transfer failed");
        myToken.approve(address(lendingContract), 135e18);
        lendingContract.deposit(myToken, 105e18);
        lendingContract.borrow(myToken, 0.025 ether);
        lendingContract.fundsAreSafu(contractOwner, myToken, 30e18);
        uint256 debtToBePaid = lendingContract.getPartialLiquidationSpecs(contractOwner, myToken);
        vm.assume(debtAmount > 0 && debtAmount != debtToBePaid && debtAmount < 0.5 ether);
        vm.expectRevert(lending.correctDebtAmountMustBeRepaid.selector);
        lendingContract.partialLiquidation{value: debtAmount}(contractOwner, myToken);
        vm.stopPrank();
    }

    function testFuzz_partialLiquidationFunctionsAsIntended(uint256 tokensToTake) public {
        vm.assume(tokensToTake > 0 && tokensToTake < 31.4e18);
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        (bool success,) = address(lendingContract).call{value: 0.5 ether}("");
        require(success, "transfer failed");
        myToken.approve(address(lendingContract), 105e18 + tokensToTake);
        lendingContract.deposit(myToken, 105e18);
        lendingContract.borrow(myToken, 0.025 ether);
        lendingContract.fundsAreSafu(contractOwner, myToken, tokensToTake);
        console.log("owner's token balance before partial liquidation: ", myToken.balanceOf(contractOwner));
        uint256 debtToBePaid = lendingContract.getPartialLiquidationSpecs(contractOwner, myToken);
        lendingContract.partialLiquidation{value: debtToBePaid}(contractOwner, myToken);
        console.log("owner's token balance AFTER partial liquidation: ", myToken.balanceOf(contractOwner));
        vm.stopPrank();
    }

    ///////////// Testing freezeBorrowingMarket() /////////////
    function test_revertWhen_calledByNotTheOwner() public {
        vm.prank(USER1);
        vm.expectRevert(lending.notAuthorizedToCallThisFunction.selector);
        lendingContract.freezeBorrowingMarket(myToken);
    }

    function test_revertWhen_calledOnAMarketNotInTheAllowedList() public {
        vm.prank(contractOwner);
        vm.expectRevert(lending.notEligibleAsCollateral.selector);
        lendingContract.freezeBorrowingMarket(myToken);
    }

    function test_revertWhen_borrowingMarketHasAlreadyBeenFrozen() public {
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        lendingContract.freezeBorrowingMarket(myToken);
        vm.expectRevert(lending.borrowingMarketHasAlreadyBeenFrozen.selector);
        lendingContract.freezeBorrowingMarket(myToken);
        vm.stopPrank();
    }

    ///////////// Testing unfreezeBorrowingMarket() /////////////
    function test_revertWhen_unfreezeCalledByNotTheOwner() public {
        vm.prank(USER1);
        vm.expectRevert(lending.notAuthorizedToCallThisFunction.selector);
        lendingContract.unfreezeBorrowingMarket(myToken);
    }

    function test_revertWhen_unfreezeCalledOnAMarketNotInTheAllowedList() public {
        vm.prank(contractOwner);
        vm.expectRevert(lending.notEligibleAsCollateral.selector);
        lendingContract.unfreezeBorrowingMarket(myToken);
    }

    function test_revertWhen_unfreezeCalledOnAnActiveMarket() public {
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        vm.expectRevert(lending.borrowingMarketIsCurrentlyActive.selector);
        lendingContract.unfreezeBorrowingMarket(myToken);
        vm.stopPrank();
    }

    function test_unfreezeAllowsAMarketToBeDepositedIntoAgain() public {
        vm.startPrank(contractOwner);
        myToken.approve(address(lendingContract), 10e18);
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        lendingContract.freezeBorrowingMarket(myToken);
        vm.expectRevert(lending.borrowingMarketIsFrozen.selector);
        lendingContract.deposit(myToken, 10e18);
        lendingContract.unfreezeBorrowingMarket(myToken);
        lendingContract.deposit(myToken, 10e18);
        vm.stopPrank();
        assertEq(myToken.balanceOf(contractOwner), MAX_TOKEN_SUPPLY - 10e18);
    }

    function test_unfreezeAllowsMarketToBeBorrowedInAgain() public {
        vm.startPrank(contractOwner);
        myToken.approve(address(lendingContract), MAX_TOKEN_SUPPLY);
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        (bool success,) = address(lendingContract).call{value: 50 ether}("");
        require(success, "transfer failed");
        lendingContract.deposit(myToken, MAX_TOKEN_SUPPLY);
        lendingContract.freezeBorrowingMarket(myToken);
        vm.expectRevert(lending.borrowingMarketIsFrozen.selector);
        lendingContract.borrow(myToken, 10 ether);
        lendingContract.unfreezeBorrowingMarket(myToken);
        lendingContract.borrow(myToken, 10 ether);
        assertEq(contractOwner.balance, STARTING_USER_BALANCE - 40 ether);
    }

    ///////////// Testing withdrawLentEth() /////////////
    function test_revertWhen_lentEthWithdrawAmountIsZero() public {
        vm.prank(contractOwner);
        vm.expectRevert(lending.inputMustBeGreaterThanZero.selector);
        lendingContract.withdrawLentEth(0);
    }

    function testFuzz_revertWhen_tryingToWithdrawMoreEthThanLendersAllocation(uint256 withdrawAmount) public {
        vm.assume(withdrawAmount > 10 ether);
        vm.startPrank(contractOwner);
        vm.warp(SECONDS_IN_A_YEAR);
        (bool success,) = address(lendingContract).call{value: 10 ether}("");
        require(success, "transfer failed");
        vm.expectRevert(lending.cannotWithdrawMoreEthThanLenderIsEntitledTo.selector);
        lendingContract.withdrawLentEth(withdrawAmount);
        vm.stopPrank();
    }

    function testFuzz_revertWhen_withdrawAttemptWithNotEnoughEthInContract(uint256 ethAmount) public {
        vm.assume(ethAmount > 0 && ethAmount <= 10.5 ether);
        vm.prank(USER1);
        vm.warp(SECONDS_IN_A_YEAR);
        (bool success,) = address(lendingContract).call{value: 10 ether}("");
        require(success, "transfer failed");
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        myToken.approve(address(lendingContract), 42000e18);
        lendingContract.deposit(myToken, 42000e18);
        lendingContract.borrow(myToken, 10 ether);
        vm.stopPrank();
        vm.warp(SECONDS_IN_A_YEAR * 2);
        vm.prank(USER1);
        vm.expectRevert(lending.notEnoughEthInContract.selector);
        lendingContract.withdrawLentEth(ethAmount);
    }

    function testFuzz_functionalityWhenWithdrawAmountIsLessThanLendersEthYield(uint256 withdrawAmount) public {
        vm.assume(withdrawAmount > 0 && withdrawAmount < 0.5 ether);
        vm.prank(USER1);
        vm.warp(SECONDS_IN_A_YEAR);
        (bool success,) = address(lendingContract).call{value: 10 ether}("");
        require(success, "transfer failed");
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        myToken.approve(address(lendingContract), 42000e18);
        lendingContract.deposit(myToken, 42000e18);
        lendingContract.borrow(myToken, 10 ether);
        vm.warp(SECONDS_IN_A_YEAR * 2);
        lendingContract.repay{value: 10.5 ether}(myToken);
        vm.stopPrank();
        vm.startPrank(USER1);
        uint256 currentEthYield = lendingContract.calculateLenderEthYield(USER1);
        assertEq(0.5 ether, currentEthYield);
        lendingContract.withdrawLentEth(withdrawAmount);
        uint256 remainingClaimableEth = lendingContract.getLenderLentEthAmount(USER1);
        uint256 remainingEthYield = lendingContract.calculateLenderEthYield(USER1);
        vm.stopPrank();
        assertEq(remainingClaimableEth, 10.5 ether - withdrawAmount);
        assertEq(remainingEthYield, 0);
    }

    function test_functionalityWhenWithdrawAmountIsEqualToTheLendersEthYield() public {
        vm.prank(USER1);
        vm.warp(SECONDS_IN_A_YEAR);
        (bool success,) = address(lendingContract).call{value: 10 ether}("");
        require(success, "transfer failed");
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        myToken.approve(address(lendingContract), 42000e18);
        lendingContract.deposit(myToken, 42000e18);
        lendingContract.borrow(myToken, 10 ether);
        vm.warp(SECONDS_IN_A_YEAR + SECONDS_IN_A_HALF_YEAR);
        uint256 ethYieldAtHalfYear = lendingContract.calculateLenderEthYield(USER1);
        assertEq(ethYieldAtHalfYear, 0.25 ether);
        vm.warp(SECONDS_IN_A_YEAR * 2);
        uint256 ethYieldBeforeWithdraw = lendingContract.calculateLenderEthYield(USER1);
        assertEq(ethYieldBeforeWithdraw, 0.5 ether);
        lendingContract.repay{value: 10.5 ether}(myToken);
        vm.stopPrank();
        vm.startPrank(USER1);
        lendingContract.withdrawLentEth(ethYieldBeforeWithdraw);
        uint256 ethYieldAfterWithdraw = lendingContract.calculateLenderEthYield(USER1);
        assertEq(ethYieldAfterWithdraw, 0);
        assertEq(USER1.balance, STARTING_USER_BALANCE - (10 ether - ethYieldBeforeWithdraw));
    }

    function test_functionalityWhenWithdrawAmountIsGreaterThanLendersEthYield() public {
        // block.timestamp is set to 31536000
        vm.warp(SECONDS_IN_A_YEAR);

        // USER1 deposits 10 ether
        vm.prank(USER1);
        (bool success,) = address(lendingContract).call{value: 10 ether}(""); // USER1 owns 1/5 of the lending pool
        require(success, "transfer failed");

        // contractOwner deposits 40 ether
        vm.startPrank(contractOwner);
        (bool success1,) = address(lendingContract).call{value: 40 ether}(""); // contract owner owns 4/5 of the lending pool
        require(success1, "transfer failed");

        // contractOwner adds myToken as eligible collateral
        // contractOwner deposits 42k tokens
        // contractOwner borrows 10 ether, making their total debt 10.5 ether (from borrowing fees)
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        myToken.approve(address(lendingContract), 42000e18);
        lendingContract.deposit(myToken, 42000e18);
        lendingContract.borrow(myToken, 10 ether);

        // block.timestamp is set to 1/2 year after the lending start-time
        // The lending yield is calculated and then checked for USER1 and contractOwner
        vm.warp(SECONDS_IN_A_YEAR + SECONDS_IN_A_HALF_YEAR);
        uint256 contractOwnerEthYieldAtHalfYear = lendingContract.calculateLenderEthYield(contractOwner);
        uint256 userEthYieldAtHalfYear = lendingContract.calculateLenderEthYield(USER1);
        assertEq(contractOwnerEthYieldAtHalfYear, 0.2e18);
        assertEq(userEthYieldAtHalfYear, 0.05e18);

        // block.timestamp is set to 1 year after the lending start-time
        // The lending yield is calculated and then checked for USER1 and contractOwner
        vm.warp(SECONDS_IN_A_YEAR * 2);
        uint256 contractOwnerEthYieldAfterOneYear = lendingContract.calculateLenderEthYield(contractOwner);
        uint256 userEthYieldAfterOneYear = lendingContract.calculateLenderEthYield(USER1);
        assertEq(contractOwnerEthYieldAfterOneYear, 0.4e18);
        assertEq(userEthYieldAfterOneYear, 0.1e18);

        // contractOwner repays their 10.5 ether debt
        lendingContract.repay{value: 10.5 ether}(myToken);

        // The lending yield is calculated and then checked for USER1 and contractOwner
        // The amount of eth deposited is calculated and then checked for USER1 and contractOwner
        // The lending contract's eth balance is checked
        uint256 contractOwnerEthYieldAfterDebtRepaid = lendingContract.calculateLenderEthYield(contractOwner);
        uint256 userEthYieldAfterOwnerRepaidDebt = lendingContract.calculateLenderEthYield(USER1);
        uint256 contractOwnerLentEthAmountAfterDebtRepaid = lendingContract.getLenderLentEthAmount(contractOwner);
        uint256 userLentEthAmountAfterOwnerRepaidDebt = lendingContract.getLenderLentEthAmount(USER1);
        assertEq(contractOwnerEthYieldAfterDebtRepaid, 0.4e18);
        assertEq(userEthYieldAfterOwnerRepaidDebt, 0.1e18);
        assertEq(contractOwnerLentEthAmountAfterDebtRepaid, 40e18);
        assertEq(userLentEthAmountAfterOwnerRepaidDebt, 10e18);
        assertEq(address(lendingContract).balance, 50.5 ether);

        // contractOwner withdraws their entire allocation of eth (40.4 eth--> lent + yield)
        lendingContract.withdrawLentEth(40.4 ether);

        // The amount of eth deposited is calculated and then checked for USER1 and contractOwner
        // The lending contract's eth balance is checked
        // The lending yield is calculated and then checked for USER1 and contractOwner
        uint256 contractOwnerEthYieldAfterCompleteWithdraw = lendingContract.calculateLenderEthYield(contractOwner);
        uint256 userEthYieldAfterOwnerCompleteWithdraw = lendingContract.calculateLenderEthYield(USER1);
        uint256 contractOwnerLentEthAmountAfterCompleteWithdraw = lendingContract.getLenderLentEthAmount(contractOwner);
        uint256 userLentEthAmountAfterOwnerCompleteWithdraw = lendingContract.getLenderLentEthAmount(USER1);
        assertEq(contractOwnerEthYieldAfterCompleteWithdraw, 0);
        assertEq(contractOwnerLentEthAmountAfterCompleteWithdraw, 0);
        assertEq(userLentEthAmountAfterOwnerCompleteWithdraw, 10e18);
        assertEq(address(lendingContract).balance, 10.1e18);
        assertEq(userEthYieldAfterOwnerCompleteWithdraw, 0.1e18);
        vm.stopPrank();
    }

    ///////////// Testing withdrawEthYield() /////////////
    function test_revertWhen_EthYieldIsZeroFromNotLendingEth() public {
        vm.warp(SECONDS_IN_A_YEAR);
        vm.prank(USER1);
        (bool success,) = address(lendingContract).call{value: 10 ether}("");
        require(success, "transfer failed");
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        myToken.approve(address(lendingContract), 42000e18);
        lendingContract.deposit(myToken, 42000e18);
        lendingContract.borrow(myToken, 10 ether);
        vm.warp(SECONDS_IN_A_YEAR + SECONDS_IN_A_HALF_YEAR);
        lendingContract.repay{value: 10.5 ether}(myToken);
        vm.expectRevert(lending.inputMustBeGreaterThanZero.selector);
        lendingContract.withdrawEthYield();
        vm.stopPrank();
    }

    function test_revertWhen_EthYieldIsZeroFromAlreadyClaimingYield() public {
        vm.warp(SECONDS_IN_A_YEAR);
        vm.prank(USER1);
        (bool success,) = address(lendingContract).call{value: 10 ether}("");
        require(success, "transfer failed");
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        myToken.approve(address(lendingContract), 42000e18);
        lendingContract.deposit(myToken, 42000e18);
        lendingContract.borrow(myToken, 10 ether);
        vm.warp(SECONDS_IN_A_YEAR + SECONDS_IN_A_HALF_YEAR);
        lendingContract.repay{value: 10.5 ether}(myToken);
        vm.stopPrank();
        vm.startPrank(USER1);
        lendingContract.withdrawEthYield();
        assertEq(USER1.balance, STARTING_USER_BALANCE - 9.75 ether);
        vm.expectRevert(lending.inputMustBeGreaterThanZero.selector);
        lendingContract.withdrawEthYield();
        vm.stopPrank();
    }

    function test_revertWhen_EthYieldIsZeroFromAlreadyClaimingYieldButWithMultipleLenders() public {
        vm.warp(SECONDS_IN_A_YEAR);
        vm.prank(USER1);
        (bool success,) = address(lendingContract).call{value: 10 ether}("");
        require(success, "transfer failed");
        vm.startPrank(contractOwner);
        (bool success1,) = address(lendingContract).call{value: 40 ether}("");
        require(success1, "transfer failed");
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        myToken.approve(address(lendingContract), 42000e18);
        lendingContract.deposit(myToken, 42000e18);
        lendingContract.borrow(myToken, 10 ether);
        vm.warp(SECONDS_IN_A_YEAR + SECONDS_IN_A_HALF_YEAR);
        lendingContract.repay{value: 10.5 ether}(myToken);
        vm.stopPrank();
        vm.startPrank(USER1);
        lendingContract.withdrawEthYield();
        assertEq(USER1.balance, STARTING_USER_BALANCE - 9.95 ether);
        vm.expectRevert(lending.inputMustBeGreaterThanZero.selector);
        lendingContract.withdrawEthYield();
        vm.stopPrank();
        vm.prank(contractOwner);
        lendingContract.withdrawEthYield();
        assertEq(contractOwner.balance, STARTING_USER_BALANCE - 40.32 ether);
    }

    function test_revertWhen_notEnoughEthInContractForYieldWithdraw() public {
        vm.warp(SECONDS_IN_A_YEAR);
        vm.prank(USER1);
        (bool success,) = address(lendingContract).call{value: 10 ether}("");
        require(success, "transfer failed");
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        myToken.approve(address(lendingContract), 42000e18);
        lendingContract.deposit(myToken, 42000e18);
        lendingContract.borrow(myToken, 10 ether);
        vm.stopPrank();
        vm.warp(SECONDS_IN_A_YEAR * 2);
        vm.prank(USER1);
        vm.expectRevert(lending.notEnoughEthInContract.selector);
        lendingContract.withdrawEthYield();
    }

    function test_ethYieldResetsAfterClaiming() public {
        vm.warp(SECONDS_IN_A_YEAR);
        vm.prank(USER1);
        (bool success,) = address(lendingContract).call{value: 10 ether}("");
        require(success, "transfer failed");
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        myToken.approve(address(lendingContract), 42000e18);
        lendingContract.deposit(myToken, 42000e18);
        lendingContract.borrow(myToken, 10 ether);
        lendingContract.repay{value: 10.5 ether}(myToken);
        vm.stopPrank();
        vm.warp(SECONDS_IN_A_YEAR + SECONDS_IN_A_HALF_YEAR);
        vm.startPrank(USER1);
        lendingContract.withdrawEthYield();
        assertEq(USER1.balance, STARTING_USER_BALANCE - 9.75 ether);
        vm.warp(SECONDS_IN_A_YEAR * 2);
        lendingContract.withdrawEthYield();
        assertEq(USER1.balance, STARTING_USER_BALANCE - 9.625 ether);
    }

    ///////////// Testing fundsAreSafu() /////////////
    function testFuzz_revertWhen_noCollateralHasBeenDepositedByTheSelectedUser(uint256 withdrawAmount) public {
        vm.assume(withdrawAmount > 0);
        vm.startPrank(contractOwner);
        vm.expectRevert(lending.inputMustBeGreaterThanZero.selector);
        lendingContract.fundsAreSafu(contractOwner, myToken, withdrawAmount);
        vm.stopPrank();
    }

    function testFuzz_revertWhen_notOwnerCallsThisFunction(address notTheOwner, uint256 withdrawAmount) public {
        vm.assume(withdrawAmount <= 42000e18);
        vm.assume(notTheOwner != contractOwner);
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        myToken.approve(address(lendingContract), 42000e18);
        lendingContract.deposit(myToken, 42000e18);
        vm.stopPrank();
        vm.prank(notTheOwner);
        vm.expectRevert(lending.notAuthorizedToCallThisFunction.selector);
        lendingContract.fundsAreSafu(contractOwner, myToken, withdrawAmount);
    }

    function testFuzz_revertWhen_withdrawAmountIsGreaterThanDepositedAmount(uint256 withdrawAmount) public {
        vm.assume(withdrawAmount > 42000e18);
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        myToken.approve(address(lendingContract), 42000e18);
        lendingContract.deposit(myToken, 42000e18);
        vm.expectRevert(lending.transferFailed.selector);
        lendingContract.fundsAreSafu(contractOwner, myToken, withdrawAmount);
    }

    function testFuzz_withdrawAmountIsTakenFromVolunteerAndGivenToOwner(uint256 withdrawAmount) public {
        vm.assume(withdrawAmount < 42000e18 && withdrawAmount > 0);
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        (bool success,) = address(lendingContract).call{value: 10 ether}("");
        require(success, "transfer failed");
        myToken.transfer(USER1, 42000e18);
        vm.stopPrank();
        vm.startPrank(USER1);
        myToken.approve(address(lendingContract), 42000e18);
        lendingContract.deposit(myToken, 42000e18);
        lendingContract.borrow(myToken, 10 ether);
        lendingContract.repay{value: 10.5 ether}(myToken);
        vm.stopPrank();
        vm.startPrank(contractOwner);
        lendingContract.fundsAreSafu(USER1, myToken, withdrawAmount);
        vm.stopPrank();
        assertEq(myToken.balanceOf(contractOwner), MAX_TOKEN_SUPPLY - 42000e18 + withdrawAmount);
    }

    ///////////// Testing calculateLenderEthYield() /////////////
    function test_revertWhen_noEthHasBeenLentToTheContract() public {
        vm.startPrank(contractOwner);
        vm.expectRevert(lending.inputMustBeGreaterThanZero.selector);
        lendingContract.calculateLenderEthYield(contractOwner);
        vm.stopPrank();
    }

    function test_ethYieldCalculatesCorrectlyWithHalfYearOfLending() public {
        vm.warp(SECONDS_IN_A_YEAR);
        vm.prank(USER1);
        (bool success,) = address(lendingContract).call{value: 25 ether}("");
        require(success, "transfer failed");
        vm.startPrank(contractOwner);
        (bool success1,) = address(lendingContract).call{value: 25 ether}("");
        require(success1, "transfer failed");
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        myToken.approve(address(lendingContract), 42000e18);
        lendingContract.deposit(myToken, 42000e18);
        lendingContract.borrow(myToken, 10 ether);
        vm.warp(SECONDS_IN_A_YEAR + SECONDS_IN_A_HALF_YEAR);
        lendingContract.repay{value: 10.5 ether}(myToken);
        uint256 contractOwnerEthYieldAfterHalfYear = lendingContract.calculateLenderEthYield(contractOwner);
        uint256 userEthYieldAfterHalfYear = lendingContract.calculateLenderEthYield(USER1);
        vm.stopPrank();
        assertEq(userEthYieldAfterHalfYear, contractOwnerEthYieldAfterHalfYear);
        assertEq(contractOwnerEthYieldAfterHalfYear, 0.125 ether);
    }

    function test_ethYieldCalculationWhenUserIsNotEntitledToAnyYield() public {
        vm.warp(SECONDS_IN_A_YEAR);
        vm.startPrank(contractOwner);
        (bool success,) = address(lendingContract).call{value: 50 ether}("");
        require(success, "transfer failed");
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        myToken.transfer(USER1, 42000e18);
        vm.stopPrank();
        vm.startPrank(USER1);
        myToken.approve(address(lendingContract), 42000e18);
        lendingContract.deposit(myToken, 42000e18);
        lendingContract.borrow(myToken, 10 ether);
        vm.warp(SECONDS_IN_A_YEAR * 2);
        lendingContract.repay{value: 10.5 ether}(myToken);
        lendingContract.withdraw(myToken, 42000e18);
        uint256 userEthYield = lendingContract.calculateLenderEthYield(USER1);
        assertEq(userEthYield, 0);
        vm.stopPrank();
    }

    function test_ethYieldIsZeroIfNoTimeHasPassed() public {
        vm.warp(SECONDS_IN_A_YEAR);
        vm.startPrank(contractOwner);
        (bool success,) = address(lendingContract).call{value: 50 ether}("");
        require(success, "transfer failed");
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        myToken.transfer(USER1, 42000e18);
        vm.stopPrank();
        vm.startPrank(USER1);
        myToken.approve(address(lendingContract), 42000e18);
        lendingContract.deposit(myToken, 42000e18);
        lendingContract.borrow(myToken, 10 ether);
        lendingContract.repay{value: 10.5 ether}(myToken);
        lendingContract.withdraw(myToken, 42000e18);
        uint256 contractOwnerEthYield = lendingContract.calculateLenderEthYield(contractOwner);
        assertEq(contractOwnerEthYield, 0);
        vm.stopPrank();
    }

    ///////////// Testing getUserHealthFactorByMarket() /////////////
    function test_revertWhen_userHasNoEthMarketDebt() public {
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        myToken.approve(address(lendingContract), 42000e18);
        lendingContract.deposit(myToken, 42000e18);
        vm.expectRevert(lending.cannotCalculateHealthFactor.selector);
        lendingContract.getUserHealthFactorByMarket(contractOwner, myToken);
        vm.stopPrank();
    }

    function testFuzz_healthFactorAccuratelyCalculatesBorrowerPosition(uint256 borrowingAmount) public {
        vm.assume(borrowingAmount > 0 && borrowingAmount <= 10 ether);
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, 200e18);
        myToken.approve(address(lendingContract), 42000e18);
        lendingContract.deposit(myToken, 42000e18);
        (bool success,) = address(lendingContract).call{value: 10 ether}("");
        require(success, "transfer failed");
        lendingContract.borrow(myToken, borrowingAmount);
        vm.stopPrank();
        vm.startPrank(USER1);
        vm.expectRevert(lending.userIsNotEligibleForPartialLiquidation.selector);
        lendingContract.getPartialLiquidationSpecs(contractOwner, myToken);
        vm.stopPrank();
    }
    ///////////// Testing getTokenMinimumCollateralizationRatio() /////////////

    function test_revertWhen_tokenIsNotOnTheAllowList() public {
        vm.startPrank(contractOwner);
        vm.expectRevert(lending.notEligibleAsCollateral.selector);
        lendingContract.getTokenMinimumCollateralizationRatio(myToken);
    }

    function testFuzz_retrievesCollateralizationRatioAccurately(uint256 MCR) public {
        vm.assume(MCR != 0);
        vm.startPrank(contractOwner);
        lendingContract.allowTokenAsCollateral(myToken, MCR);
        uint256 myTokenCollateralizationRatio = lendingContract.getTokenMinimumCollateralizationRatio(myToken);
        vm.stopPrank();
        assertEq(myTokenCollateralizationRatio, MCR);
    }

    ///////////// Testing getPartialLiquidationSpecs() /////////////
}
