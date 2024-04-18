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
    // between 140% and 200% collateralization ratios
    // LTV = collateral / borrow
    // 200% LTV = $105 / 0.02625ETH ($52.5)
    // 140% LTV = $73.5 / 0.02625ETH ($52.5)
    // collateral must be < $105
    // collateral must be > $73.5
    // tokensToTake > 0 && tokensToTake < $31.5 (0.01575 ETH)

    function testFuzz_partialLiquidationFunctionsAsIntended(uint256 tokensToTake) public {
        vm.assume(tokensToTake > 0 && tokensToTake < 31.5e18);
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
}
