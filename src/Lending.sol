// SPDX-License-Identifier: MIT

/**
 * Layout of Contract:
 * version
 * imports
 * interfaces, libraries, contracts
 * errors
 * Type declarations
 * State variables
 * Events
 * Modifiers
 * Functions
 *
 * Layout of Functions:
 * constructor
 * receive function (if exists)
 * fallback function (if exists)
 * external
 * public
 * internal
 * private
 * view & pure functions
 */
pragma solidity ^0.8.19;

//////////////////
//// Imports ////
/////////////////
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {priceConverter} from "./priceConverter.sol";
import {AggregatorV3Interface} from
    "lib/chainlink-brownie-contracts/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/////////////////
//// Errors ////
////////////////
error unrecognizedFunctionCall();
error notEligibleAsCollateral();
error inputMustBeGreaterThanZero();
error notAuthorizedToCallThisFunction();
error cannotRemoveFromCollateralListWithOpenDebtPositions();
error cannotRepayMoreThanOpenDebtAndBorrowingFee();
error transferFailed();
error notEnoughEthInContract();
error notEnoughCollateralDepositedByUserToBorrowThisAmountOfEth();
error cannotWithdrawMoreCollateralThanWhatWasDeposited();
error userIsNotEligibleForLiquidation();
error entireDebtPositionMustBePaidToBeAbleToLiquidate();
error cannotCalculateHealthFactor();
error withdrawlRequestExceedsPayoutAmount();

/**
 * @title lending
 * @author mrthedude
 * @notice This is a lending and borrowing contract where lent ETH may be borrowed against approved ERC20 tokens
 * @dev Uses a Chainlink ETH/USD pricefeed oracle to update LTVs on outstanding borrowing positions
 * @dev This contract incorporates a fixed borrowing fee and considers the value of each ERC20 collateral to be $1 per token for simplicity
 * @dev Lenders do not receive any of the borrowing fees due to author's lack of smart contraact knowledge
 */
contract lending {
    using SafeERC20 for IERC20;
    //////////////////////////
    //// State Variables ////
    /////////////////////////

    /// @notice Address with special function privileges
    address public immutable i_owner;
    /// @dev Chainlink ETH/USD price feed
    AggregatorV3Interface private immutable i_priceFeed;
    /// @notice Fixed borrow fee to be paid in ETH before the deposited collateral can be withdrawn
    uint256 public constant BORROW_FEE = 5e17; // 5% borrowing fee
    /// @notice Dynamic array of ERC20 token addresses that are eligible to be deposited as collateral
    IERC20[] public allowedTokens;
    /// @notice The total amount of interest that lenders can claim on a pro-rata basis. Updated with every borrow() function call
    /// @notice Used in conjuction with the getLenderPayoutAmount() function to calculate a specific lender's payout
    uint256 public lendersInterestPaymentPot;

    /// @notice Tracks the deposit balance of the tokens a user has supplied to the contract as borrowing collateral
    mapping(address user => mapping(IERC20 tokenAddress => uint256 amountDeposited)) public depositIndexByToken;
    /// @notice Tracks the amount of ETH a user has borrowed from the contract
    mapping(address borrower => uint256 amount) public borrowedEthAmount;
    /// @notice Tracks a user's total borrowing fee which must be paid to the contract in order to withdraw the deposited collateral
    mapping(address borrower => uint256 totalBorrowFee) public totalBorrowFee;
    /// @notice Tracks the amount of ETH a user has lent to the contract
    mapping(address lender => uint256 ethAmount) public lentEthAmount;
    /// @notice Tracks users' health factors
    mapping(address borrower => uint256 healthFactor) public userHealthFactor;
    /// @notice Tracks the minimum collateralization ratio for an approved ERC20 token
    mapping(IERC20 token => uint256 collateralFactor) public minimumCollateralizationRatio;

    //////////////////
    //// Events /////
    /////////////////
    event AllowedTokenSet(IERC20 indexed tokenAddress, uint256 indexed minimumCollateralizationRatio);
    event RemovedTokenSet(IERC20 indexed tokenAddress);
    event ERC20Deposit(
        address indexed depositer, IERC20 indexed depositedTokenAddress, uint256 indexed amountDeposited
    );
    event EthDeposit(address indexed depositer, uint256 indexed amount);
    event EthWithdrawl(address indexed user, uint256 indexed amount);
    event Borrow(address indexed borrower, uint256 indexed ethAmountBorrowed, uint256 indexed totalUserEthDebt);
    event Withdraw(address indexed user, IERC20 indexed withdrawnTokenAddress, uint256 indexed amountWithdrawn);
    event Repay(address indexed user, uint256 indexed amountRepaid, uint256 indexed totalUserEthDebt);
    event Liquidate(
        address indexed debtor, IERC20 indexed tokenCollateralAddress, uint256 indexed tokenAmountLiquidated
    );

    ////////////////////
    //// Modifiers ////
    ///////////////////

    /**
     * @notice Modifier to restrict which ERC20 tokens are eligible to be used as collateral for borrowing Eth
     * @param tokenAddress The address of the ERC20 token being checked for eligibility
     * @dev Used in the following functions: deposit(), withdraw(), borrow(), liquidate()
     */
    modifier isAllowedToken(IERC20 tokenAddress) {
        bool included = false;
        for (uint256 i = 0; i < allowedTokens.length; i++) {
            if (allowedTokens[i] == tokenAddress) {
                included = true;
            }
        }
        if (included == false) {
            revert notEligibleAsCollateral();
        }
        _;
    }

    /**
     * @notice Modifier to ensure the function call parameter is more than zero
     * @param amount The input amount being checked in the function call
     * @dev Used in the following functions: deposit(), withdraw(), borrow(), repay(), liquidate(), withdrawLentEth(), getLenderPayoutAmount()
     */
    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert inputMustBeGreaterThanZero();
        }
        _;
    }

    /**
     *
     * @notice Modifier that restricts access to certain functions to only i_owner
     * @dev Used in the following functions: allowTokenAsCollateral(), removeTokenAsCollateral()
     */
    modifier onlyOwner() {
        if (msg.sender != i_owner) {
            revert notAuthorizedToCallThisFunction();
        }
        _;
    }

    ////////////////////
    //// Functions ////
    ///////////////////
    /**
     * @notice Sets the i_owner and i_priceFeed of the lending contract upon deployment
     * @param _owner Sets the address that will have special prvileges for certain function calls
     * @param priceFeed Sets the ETH/USD price feed that will be used to determine the LTV of open debt positions
     */
    constructor(address _owner, address priceFeed) {
        i_owner = _owner;
        i_priceFeed = AggregatorV3Interface(priceFeed);
    }

    /**
     * @notice Allows the lending contract to receive deposits of Ether
     * @dev Updates the msg.sender's lentEthAmount
     * @dev Emits the EthDeposit event
     */
    receive() external payable {
        lentEthAmount[msg.sender] += msg.value;
        emit EthDeposit(msg.sender, msg.value);
    }

    /**
     * @notice A fallback function for error catching any incompatible function calls to the lending contract
     */
    fallback() external {
        revert unrecognizedFunctionCall();
    }

    /**
     * @notice Adds an ERC20 token to the list of eligible collateral that can be used to borrow deposited Eth against
     * @notice Sets the tokens minimumCollateralizationRatio (borrowing limits) for the ERC20 token
     * @param tokenAddress The ERC20 token that is being added to the eligible collateral list
     * @param minimumCollateralRatio The minimum ratio allowed for collateral borrowing (Maximum borrowing limit)
     * @dev Only the i_owner is able to call this function
     * @dev Adds tokenAddress to the allowedTokens[] array
     * @dev Adds the minimumCollateralRatio to the minimumCollaterizationRatio[] array
     * @dev Emits the AllowedTokenSet event
     */
    function allowTokenAsCollateral(IERC20 tokenAddress, uint256 minimumCollateralRatio) external onlyOwner {
        minimumCollateralizationRatio[tokenAddress] = minimumCollateralRatio;
        allowedTokens.push(tokenAddress);
        emit AllowedTokenSet(tokenAddress, minimumCollateralRatio);
    }

    /**
     * @notice Removes an ERC20 token from the list of eligible collateral that can be used to borrow deposited Eth against
     * @param tokenAddress The ERC20 token that is being removed from the eligible collateral list
     * @dev Only the i_owner is able to call this function
     * @dev Reverts with the cannotRemoveFromCollateralListWithOpenDebtPositions error if the collateral being removed has open debt positions in the lending contract
     * @dev Emits the RemovedTokenSet event
     */
    function removeTokenAsCollateral(IERC20 tokenAddress) external onlyOwner {
        if (tokenAddress.balanceOf(address(this)) != 0) {
            revert cannotRemoveFromCollateralListWithOpenDebtPositions();
        }
        IERC20[] memory newTokenAllowList;
        for (uint256 i = 0; i < allowedTokens.length; i++) {
            if (allowedTokens[i] != tokenAddress) {
                newTokenAllowList[i] = allowedTokens[i];
            }
        }
        allowedTokens = newTokenAllowList;
        emit RemovedTokenSet(tokenAddress);
    }

    /**
     * @notice Allows users to deposit approved ERC20 tokens into the lending contract
     * @param tokenAddress The ERC20 token that is being deposited into the lending contract
     * @param amount The number of ERC20 tokens being deposited
     * @dev Only approved tokens may be deposited and the amount deposited must be greater than zero
     * @dev Records what ERC20 token was deposited and the number of tokens deposited in the depositIndexByToken mapping
     * @dev Emits the ERC20Deposit event
     */
    function deposit(IERC20 tokenAddress, uint256 amount) external isAllowedToken(tokenAddress) moreThanZero(amount) {
        depositIndexByToken[msg.sender][tokenAddress] += amount;
        tokenAddress.safeTransferFrom(address(msg.sender), address(this), amount);
        emit ERC20Deposit(msg.sender, tokenAddress, amount);
    }

    /**
     * @notice Allows users to withdraw deposited ERC20 collateral if their loan and borrowing fees are completely paid off
     * @param amount The amount of user-deposited ERC20 tokens being withdrawn
     * @param tokenAddress Specifies which ERC20 token will be selected for the user to withdraw
     * @dev Only approved tokens may be withdrawm, and the amount to withdraw must be greater than zero and no greater than the amount the user deposited
     * @dev Updates the depositIndexByToken mapping in accordance with the amount of tokens withdrawn
     * @dev Emits the Withdraw event
     */
    function withdraw(uint256 amount, IERC20 tokenAddress) external moreThanZero(amount) isAllowedToken(tokenAddress) {
        uint256 totalUserEthDebt = borrowedEthAmount[msg.sender] + totalBorrowFee[msg.sender];
        if (totalUserEthDebt > 0) {
            revert cannotRemoveFromCollateralListWithOpenDebtPositions();
        }
        if (depositIndexByToken[msg.sender][tokenAddress] < amount) {
            revert cannotWithdrawMoreCollateralThanWhatWasDeposited();
        }
        depositIndexByToken[msg.sender][tokenAddress] -= amount;
        tokenAddress.safeTransferFrom(address(this), msg.sender, amount);
        emit Withdraw(msg.sender, tokenAddress, amount);
    }

    /**
     * @notice Allows users to borrow ETH held in the contract against approved collateral, up to a certain collateralization ratio (borrowing limit)
     * @notice Every successful borrow() function call will incure a borrowing fee of 5% of the ETH borrowed during this function call, recorded in the totalBorrowFee mapping
     * @param ethBorrowAmount The amount of ETH the user specifies to borrow
     * @param tokenCollateral The ERC20 token collateral that the ETH is being borrowed against
     * @dev Only approved, user-deposited ERC20 token collateral may be borrowed against, and the amount to borrow must be greater than zero
     * @dev Reverts with the notEnoughEthInContract error if the ethBorrowAmount exceeds the amount of ETH held in the contract
     * @dev Reverts with the notEnoughCollateralDepositedByUserToBorrowThisAmountOfEth error if the borrow request will cause the user's health factor to fall below the minimum collateralization ratio for that ERC20 token collateral market
     * @dev Updates the user's ethBorrowAmount mapping
     * @dev Updates the user's totalBorrowFee mapping
     * @dev Updates the lendersInterestPaymentPot to allow ETH lenders to claim a yield on their lent ETH
     * @dev Emits the Borrow event
     */
    function borrow(uint256 ethBorrowAmount, IERC20 tokenCollateral)
        external
        moreThanZero(ethBorrowAmount)
        isAllowedToken(tokenCollateral)
    {
        if (address(this).balance < ethBorrowAmount) {
            revert notEnoughEthInContract();
        }
        if (
            depositIndexByToken[msg.sender][tokenCollateral] * 1e18 / (ethBorrowAmount + borrowedEthAmount[msg.sender])
                * 100 < minimumCollateralizationRatio[tokenCollateral]
        ) {
            revert notEnoughCollateralDepositedByUserToBorrowThisAmountOfEth();
        }

        borrowedEthAmount[msg.sender] += ethBorrowAmount;
        totalBorrowFee[msg.sender] += ethBorrowAmount * BORROW_FEE;
        lendersInterestPaymentPot += totalBorrowFee[msg.sender];

        (bool success,) = msg.sender.call{value: ethBorrowAmount}("");
        if (!success) {
            revert transferFailed();
        }

        emit Borrow(msg.sender, ethBorrowAmount, borrowedEthAmount[msg.sender]);
    }

    /**
     * @notice Allows users to repay the ETH they borrowed from the lending contract
     * @param amount The amount of ETH the user is repaying
     * @dev Reverts with the cannotRepayMoreThanOpenDebtAndBorrowingFee error if the amount parameter is greater than the user's total debt (borrowing amount + borrowing fee)
     * @dev The repay amount must be greater than zero
     * @dev If amount <= user's totalBorrowFee: User's totalBorrowFee -= amount && amount = 0
     * @dev If amount >= user's totalBorrowFee: User's totalBorrowFee = 0 (paid off) && the remaining amount is subtracted from the user's borrowedEthAmount
     * @dev Updates the user's borrowedEthAmount mapping with any remaining amount
     * @dev Emits the Repay event
     */
    function repay(uint256 amount) external moreThanZero(amount) {
        uint256 totalUserDebt = borrowedEthAmount[msg.sender] + totalBorrowFee[msg.sender];
        if (totalUserDebt < amount) {
            revert cannotRepayMoreThanOpenDebtAndBorrowingFee();
        }
        if (amount <= totalBorrowFee[msg.sender]) {
            totalBorrowFee[msg.sender] -= amount;
            amount = 0;
        }
        if (amount >= totalBorrowFee[msg.sender]) {
            uint256 interestExpense = totalBorrowFee[msg.sender];
            totalBorrowFee[msg.sender] = 0;
            amount -= interestExpense;
        }
        borrowedEthAmount[msg.sender] -= amount;

        (bool success,) = address(this).call{value: amount}("");
        if (!success) {
            revert transferFailed();
        }
        emit Repay(msg.sender, amount, totalUserDebt);
    }

    /**
     * @notice Allows users to liquidate the deposited collateral of other users who's loans have fallen below the collateral market's minimum collateralization ratio
     * @param debtor The address of the user who is eligible to have their collateral liquidated
     * @param tokenAddress The token address of the ERC20 token collateral being liquidated
     * @dev Only approved ERC20 token collateral may be liquidated
     * @dev Reverts with the userIsNotEligibleForLiquidation error if the debtor's loan is not below the minimum collateralization ratio
     * @dev Reverts with the entireDebtPositionMustBePaidToBeAbleToLiquidate error if the liquidator calls the function without sending the debtor's exact ETH debt with the function call
     * @dev Updates the debtor's depositIndexByToken to 0 for that collateral market
     * @dev Updates the debtor's totalBorrowFee to 0
     * @dev Emits the Liquidate event
     *
     */
    function liquidate(address debtor, IERC20 tokenAddress) external payable isAllowedToken(tokenAddress) {
        uint256 totalUserDebt = borrowedEthAmount[debtor] + totalBorrowFee[debtor];
        if (getUserHealthFactorByToken(debtor, tokenAddress) > minimumCollateralizationRatio[tokenAddress]) {
            revert userIsNotEligibleForLiquidation();
        }
        if (msg.value != totalUserDebt) {
            revert entireDebtPositionMustBePaidToBeAbleToLiquidate();
        }

        (bool success,) = address(this).call{value: totalUserDebt}("");
        if (!success) {
            revert transferFailed();
        }
        uint256 collateralAmount = depositIndexByToken[debtor][tokenAddress];
        depositIndexByToken[debtor][tokenAddress] = 0;
        borrowedEthAmount[debtor] = 0;
        totalBorrowFee[debtor] = 0;
        tokenAddress.safeTransferFrom(address(this), msg.sender, collateralAmount);
        emit Liquidate(debtor, tokenAddress, collateralAmount);
    }

    /**
     * @notice Allows users to withdraw their lent ETH
     * @param amountOfEth The amount of ETH the user is withdrawing
     * @dev The withdrawl request must be greater than zero
     * @dev Reverts with the withdrawlRequestExceedsLentAmount error if the amountOfEth is greater than the amount of ETH the user deposited into the contract
     * @dev Reverts with the notEnoughEthInContract error if the amountOfEth is greater than the current amount of ETH stored in the contract
     * @dev updates the user's lentEthAmount mapping
     * @dev Emits the EthWithdrawl event
     */
    /**
     * User wants to withdraw more lent ETH than their lending yield
     * 1. The total lending yield pot must be reduced by the amount of yield the user has accrued
     * 2. The yield amount must be sent to the user
     * 3. The yield amount must be subtracted from the amountOfEth requested for withdrawl
     * 4. The updated amountOfEth must be sent to the user
     * 5. The lentEthAmount must subtracted by the amountOfEth
     *
     */
    function withdrawLentEth(uint256 amountOfEth) external moreThanZero(amountOfEth) {
        if (amountOfEth > lentEthAmount[msg.sender]) {
            revert withdrawlRequestExceedsPayoutAmount();
        }
        if (amountOfEth > address(this).balance) {
            revert notEnoughEthInContract();
        }
        lentEthAmount[msg.sender] -= amountOfEth;
        (bool success,) = msg.sender.call{value: amountOfEth}("");
        if (!success) {
            revert transferFailed();
        }
        emit EthWithdrawl(msg.sender, amountOfEth);
    }

    /**
     * @notice Allows lenders to withdraw their lending yield, based off of borrowing activity and the lender's percentage of the contract's ETH balance
     * @dev Entire yield amount is withdraw for the lender, smaller amounts cannot be specified
     * @dev Updates the lendersInterestPaymentPot
     * @dev Emits the EthWithdrawl event
     */
    function withdrawEthYield() external {
        uint256 ethYield = getLenderPayoutAmount(msg.sender) - lentEthAmount[msg.sender];
        if (ethYield > address(this).balance) {
            revert notEnoughEthInContract();
        }

        lendersInterestPaymentPot -= ethYield;

        (bool success,) = msg.sender.call{value: ethYield}("");
        if (!success) {
            revert transferFailed();
        }
        emit EthWithdrawl(msg.sender, ethYield);
    }

    function withdrawEntireLendingPosition() external {
        if (lentEthAmount[msg.sender] > address(this).balance) {
            revert notEnoughEthInContract();
        }
        uint256 lendingPosition = lentEthAmount[msg.sender];
        lentEthAmount[msg.sender] = 0;
        (bool success,) = msg.sender.call{value: lendingPosition}("");
        if (!success) {
            revert transferFailed();
        }
        emit EthWithdrawl(msg.sender, lendingPosition);
    }

    /**
     * @notice Calculates a user's health factor based on the amount of ETH borrowed and the borrowing fees a user has in a specifc collateral market
     * @param user The address of the user who's health factor is being queried
     * @param tokenAddress The ERC20 token collateral whose borrowing market is being queried to calculate the user's health factor
     * @dev Reverts with the cannotCalculateHealthFactor error if the user does not have an open debt position or any borrowing fees
     */
    function getUserHealthFactorByToken(address user, IERC20 tokenAddress) public view returns (uint256 healthFactor) {
        if (borrowedEthAmount[user] + totalBorrowFee[user] == 0) {
            revert cannotCalculateHealthFactor();
        }
        uint256 totalEthDebtInUSD =
            priceConverter.getEthConversionRate((borrowedEthAmount[user] + totalBorrowFee[user]), i_priceFeed);
        healthFactor = depositIndexByToken[user][tokenAddress] * 1e18 / totalEthDebtInUSD * 100;
    }

    /**
     * @notice Calculates the amount of ETH yield a lender is entitled to based on borrowing activity and the lender's share of the total ETH pool less borrowing fees
     * @param lender The address of the ETH lender whose lending payout is being calculated
     * @dev Reverts with the inputMustBeGreaterThanZero error if there is no ETH in the contract
     */
    function getLenderPayoutAmount(address lender)
        internal
        view
        moreThanZero(address(this).balance)
        returns (uint256 lenderPayout)
    {
        uint256 totalContractEth = address(this).balance;
        uint256 contractEthLessBorrowingFee = totalContractEth - lendersInterestPaymentPot;
        uint256 amountOfEthFromLender = lentEthAmount[lender];
        uint256 lenderPercentageOfEthPool = amountOfEthFromLender / contractEthLessBorrowingFee;
        uint256 lenderProRataShareOfBorrowingFees = lenderPercentageOfEthPool * lendersInterestPaymentPot;
        lenderPayout = amountOfEthFromLender + lenderProRataShareOfBorrowingFees;
    }
}
