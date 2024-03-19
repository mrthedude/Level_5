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
    event ERC20Deposit(address indexed depositer, IERC20 indexed tokensDeposited, uint256 indexed amountDeposited);
    event EthDeposit(address indexed depositer, uint256 indexed amount);
    event Borrow(address indexed borrower, uint256 indexed ethAmountBorrowed, uint256 indexed totalUserEthDebt);
    event Withdraw(address indexed user, IERC20 indexed tokenWithdrawn, uint256 indexed amountWithdrawn);
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
     * @dev Used in the following functions: deposit(), withdraw(), borrow(), repay() liquidate()
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
     * @dev Used in the following functions: deposit(), withdraw(), borrow(), repay(), liquidate()
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
     * @notice The constructor function sets the i_owner of the lending contract upon deployment
     * @param _owner Sets address that will have with special function call privileges
     * @param priceFeed Sets the ETH/USD price feed that will be used to determine the LTV of open debt positions
     */
    constructor(address _owner, address priceFeed) {
        i_owner = _owner;
        i_priceFeed = AggregatorV3Interface(priceFeed);
    }

    /**
     * @notice Allows the lending contract to receive deposits of Ether
     * @dev Records who deposited and how much was deposited in the lentEthAmount mapping, then emits the EthDeposit event
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
     * @notice Adds an ERC20 token contract address to the list of eligible collateral that can be used to borrow deposited Eth against, and sets the tokens minimumCollateralizationRatio (borrowing limits)
     * @param tokenAddress The ERC20 token contract address that is being added to the eligible collateral list
     * @dev Only the i_owner is able to call this function
     * @dev Emits the AllowedTokenSet event
     */
    function allowTokenAsCollateral(IERC20 tokenAddress, uint256 minimumCollateralRatio) external onlyOwner {
        minimumCollateralizationRatio[tokenAddress] = minimumCollateralRatio;
        allowedTokens.push(tokenAddress);
        emit AllowedTokenSet(tokenAddress, minimumCollateralRatio);
    }

    /**
     * @notice Removes an ERC20 token contract address from the list of eligible collateral that can be used to borrow deposited Eth against
     * @param tokenAddress The ERC20 token contract address that is being removed from the eligible collateral list
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
     * @param amount The number of tokens being deposited
     * @dev Only approved tokens may be deposited and the amount deposited must be greater than zero
     */
    function deposit(IERC20 tokenAddress, uint256 amount) external isAllowedToken(tokenAddress) moreThanZero(amount) {
        depositIndexByToken[msg.sender][tokenAddress] += amount;
        tokenAddress.safeTransferFrom(address(msg.sender), address(this), amount);
        emit ERC20Deposit(msg.sender, tokenAddress, amount);
    }

    function withdraw(uint256 amount, IERC20 tokenAddress) external moreThanZero(amount) {
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

    function borrow(uint256 ethBorrowAmount, IERC20 tokenCollateral) external moreThanZero(ethBorrowAmount) {
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

        (bool success,) = msg.sender.call{value: ethBorrowAmount}("");
        if (!success) {
            revert transferFailed();
        }

        emit Borrow(msg.sender, ethBorrowAmount, borrowedEthAmount[msg.sender]);
    }

    /**
     * @notice Allows users to repay the Eth they borrowed from the lending contract
     * @param amount The amount of Eth the user is repaying
     * @dev The repay amount must be greater than zero
     * @dev The user's borrowedEthAmount[] adjusts accordingly to the amount repaid, then the Repay event is emitted
     */
    function repay(uint256 amount) external moreThanZero(amount) {
        uint256 totalUserDebt = borrowedEthAmount[msg.sender] + totalBorrowFee[msg.sender];
        if (totalUserDebt < amount) {
            revert cannotRepayMoreThanOpenDebtAndBorrowingFee();
        }
        if (amount >= totalBorrowFee[msg.sender]) {
            uint256 interestExpense = totalBorrowFee[msg.sender];
            totalBorrowFee[msg.sender] = 0;
            amount -= interestExpense;
        }

        (bool success,) = address(this).call{value: amount}("");
        if (!success) {
            revert transferFailed();
        }
        borrowedEthAmount[msg.sender] -= amount;
        emit Repay(msg.sender, amount, totalUserDebt);
    }

    function liquidate(address debtor, IERC20 tokenAddress) external payable {
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

    function getUserHealthFactorByToken(address user, IERC20 tokenAddress)
        public
        view
        moreThanZero(borrowedEthAmount[user])
        returns (uint256 healthFactor)
    {
        uint256 totalEthDebtInUSD =
            priceConverter.getEthConversionRate((borrowedEthAmount[user] + totalBorrowFee[user]), i_priceFeed);
        healthFactor = depositIndexByToken[user][tokenAddress] * 1e18 / totalEthDebtInUSD * 100;
    }
}
