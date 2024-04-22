// SPDX-License-Identifier: MIT

/**
 * Layout of Contract:
 * version
 * imports
 * interfaces, libraries, contracts
 * errors
 * State variables
 * Events
 * Modifiers
 * Functions
 *
 * Layout of Functions:
 * constructor
 * receive function
 * fallback function
 * external
 * public
 * internal
 * private
 * view & pure functions
 */
pragma solidity ^0.8.0;

//////////////////
//// Imports ////
/////////////////
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {priceConverter} from "./priceConverter.sol";
import {AggregatorV3Interface} from
    "lib/chainlink-brownie-contracts/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/////////////////////
//// Libraries ////
////////////////////
using SafeERC20 for IERC20;

////////////////////
//// Contracts ////
///////////////////
/**
 * @title lending
 * @author mrthedude
 * @notice This lending and borrowing contract allows users to lend ETH and earn yield from borrowers taking collateralized loans with approved ERC20 tokens
 * @dev Uses a Chainlink ETH/USD pricefeed oracle to update LTVs on outstanding borrowing positions
 * @dev Incorporates a fixed borrowing fee of 5% the amount of ETH borrowed and considers the value of each collateralized ERC20 token to be $1 per token for simplicity
 * @dev Uses ReentrancyGuard, SafeERC20, IERC20 contracts from OpenZepplin to mitigate contract attack surface
 */
contract lending is ReentrancyGuard {
    /////////////////
    //// Errors ////
    ////////////////
    error unrecognizedFunctionCall();
    error notEligibleAsCollateral();
    error inputMustBeGreaterThanZero();
    error notAuthorizedToCallThisFunction();
    error cannotWithdrawCollateralWithOpenDebtPositions();
    error cannotRemoveFromAllowedTokensListWhenCollateralIsInContract();
    error cannotRepayMoreThanuserEthMarketDebt();
    error transferFailed();
    error notEnoughEthInContract();
    error notEnoughCollateralDepositedByUserToBorrowThisAmountOfEth();
    error cannotWithdrawMoreCollateralThanWhatWasDeposited();
    error userIsNotEligibleForCompleteLiquidation();
    error userIsNotEligibleForPartialLiquidation();
    error exactDebtAmountMustBeRepaid();
    error correctDebtAmountMustBeRepaid();
    error cannotCalculateHealthFactor();
    error borrowingMarketHasAlreadyBeenFrozen();
    error borrowingMarketIsFrozen();
    error borrowingMarketIsCurrentlyActive();
    error cannotWithdrawMoreEthThanLenderIsEntitledTo();

    //////////////////////////
    //// State Variables ////
    /////////////////////////
    /// @notice Address with special function privileges
    address public immutable i_owner;
    /// @dev Chainlink ETH/USD price feed
    AggregatorV3Interface private immutable i_ethUsdPriceFeed;
    /// @notice Fixed borrowing fee to be paid in ETH before the deposited collateral can be withdrawn by the borrower
    uint256 public constant BORROW_FEE = 0.05e18; // 5% fee on the amount of ETH borrowed per borrow() function call
    /// @notice Used to calculate when a borrower's LTV is eligible for full liquidation --> position's health factor <= minimum collateralization ratio - 30%
    uint256 public constant FULL_LIQUIDATION_THRESHOLD = 0.3e18; // Market's minimum collateralization ratio - 30%
    /// @notice Variable specifying the number of seconds in a year to avoid extra clutter in the codebase
    uint256 public constant SECONDS_IN_A_YEAR = 31536000 seconds; // (60sec * 60mins * 24hrs * 365days)
    /// @notice Accounts for the total amount of fees that lenders can claim on a pro-rata basis. Updated with every borrow() function call and ETH claim from lenders
    uint256 public lendersYieldPool;
    /// @notice The total amount of ETH that lenders have deposited into the contract
    uint256 public totalLentEth;
    /// @notice Dynamic array of ERC20 token addresses that are eligible to be deposited as collateral to borrow lent ETH against
    IERC20[] public allowedTokens;

    /// @notice Tracks the deposit balances of the ERC20 tokens a user has supplied to the contract as borrowing collateral
    mapping(address user => mapping(IERC20 tokenAddress => uint256 amountDeposited)) public depositIndexByToken;
    /// @notice Tracks the amount of ETH a user has borrowed in each collateral market
    mapping(address borrower => mapping(IERC20 tokenAddress => uint256 borrowedEthAmount)) public
        userBorrowedEthByMarket;
    /// @notice Tracks the borrowing fees a user has accrued in each collateral market that they have borrowed from
    mapping(address borrower => mapping(IERC20 tokenAddress => uint256 ethBorrowingFees)) public
        userBorrowingFeesByMarket;
    /// @notice Tracks the minimum collateralization ratio for approved ERC20 token collateral, below which the borrowing position is eligible for liquidation
    mapping(IERC20 token => uint256 collateralFactor) public minimumCollateralizationRatio;
    /// @notice Tracks a market's borrowing status to see if new borrowing positions can be opened against certain ERC20 token collateral
    mapping(IERC20 borrowMarket => bool borrowingFrozen) public frozenBorrowingMarket;
    /// @notice Tracks the individual lenders' ETH deposits
    mapping(address lender => uint256 amount) public lenderLentEthAmount;
    /// @notice Tracks the individual lenders' ETH deposits in a granular way, allowing for timestamp tracking when paired with lenderIndexOfDepositTimestamps
    mapping(address lender => uint256[] lenderDeposits) public ethLenderDepositList;
    /// @notice Tracks when lenders made each one of their ETH deposits
    mapping(address lender => mapping(uint256 depositAmount => uint256 timestamp)) public lenderIndexOfDepositTimestamps;

    //////////////////
    //// Events /////
    /////////////////
    event RemovedTokenSet(IERC20 indexed tokenAddress);
    event EthWithdrawl(address indexed user, uint256 indexed amount);
    event BorrowingMarketFrozen(IERC20 indexed borrowingMarket);
    event EthDeposit(address indexed depositer, uint256 indexed amount);
    event BorrowingMarketHasBeenUnfrozen(IERC20 indexed borrowingMarket);
    event AllowedTokenSet(IERC20 indexed tokenAddress, uint256 indexed minimumCollateralizationRatio);
    event Repay(address indexed user, uint256 indexed amountRepaid, uint256 indexed remaininguserEthMarketDebt);
    event Borrow(address indexed borrower, uint256 indexed ethAmountBorrowed, uint256 indexed userMarketEthDebt);
    event Withdraw(address indexed user, IERC20 indexed withdrawnTokenAddress, uint256 indexed amountWithdrawn);
    event ERC20Deposit(address indexed depositer, IERC20 indexed tokenAddress, uint256 indexed amountDeposited);
    event CompleteLiquidation(
        address indexed debtor, IERC20 indexed tokenAddress, uint256 indexed tokenAmountLiquidated
    );
    event PartialLiquidation(
        address indexed debtor, IERC20 indexed tokenAddress, uint256 indexed tokenAmountLiquidated
    );
    event trustDontVerify(
        address indexed userWhoDonated, uint256 indexed amountOfTokensTaken, uint256 indexed updatedUserHealthFactor
    );

    ////////////////////
    //// Modifiers ////
    ///////////////////
    /**
     * @notice Modifier to check if an ERC20 token is eligible to be used as collateral for borrowing lent ETH
     * @param tokenAddress The address of the ERC20 token being checked for collateral eligibility
     * @dev Used in the following functions: removeTokenAsCollateral(), deposit(), withdraw(), borrow(), freezeBorrowingMarket(), UnfreezeBorrowingMarket() getTokenMinimumCollateralizationRatio()
     * @dev Reverts with the notEligibleAsCollateral error if the ERC20 token is not in the allowedTokens[] array
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
     * @dev Used in the following functions: deposit(), withdraw(), borrow(), repay(), fullLiquidation(), partialLiquidation(); withdrawLentEth(), calculateLenderEthYield()
     * @dev Reverts with the inputMustBeGreaterThanZero error if the function parameter is less than or equal to zero
     */
    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert inputMustBeGreaterThanZero();
        }
        _;
    }

    /**
     *
     * @notice Modifier that restricts access to certain functions to only the i_owner
     * @dev Used in the following functions: allowTokenAsCollateral(), removeTokenAsCollateral(), freezeBorrowingMarket(), UnfreezeBorrowingMarket(), fundsAreSafu()
     * @dev Reverts with the notAuthorizedToCallThisFunction error if the msg.sender is not i_owner
     */
    modifier onlyOwner() {
        if (msg.sender != i_owner) {
            revert notAuthorizedToCallThisFunction();
        }
        _;
    }

    /**
     * @notice Regulates the opening of new borrowing positions against certain ERC20 token collateral by checking if the market is frozen or unfrozen
     * @param borrowingMarket The ERC20 token borrowing market whose status is being checked to see if it is open or closed to the creation of new borrowing positions
     * @dev Used in the following functions: deposit(), borrow()
     * @dev Reverts with the borrowingMarketIsFrozen() error if the market has already been frozen (closed)
     */
    modifier checkBorrowingMarket(IERC20 borrowingMarket) {
        if (frozenBorrowingMarket[borrowingMarket] == true) {
            revert borrowingMarketIsFrozen();
        }
        _;
    }
    //////////////////////////////////
    //// Functions-- Constructor ////
    ////////////////////////////////
    /**
     * @notice Sets the i_owner and i_ethUsdPriceFeed of the lending contract upon deployment
     * @param owner Sets the address that will have special prvileges for certain function calls --> allowTokenAsCollateral(), removeTokenAsCollateral(), freezeBorrowingMarket(), UnfreezeBorrowingMarket()
     * @param priceFeed Sets the Chainlink ETH/USD price feed that will be used to determine the LTVs of open debt positions
     */

    constructor(address owner, address priceFeed) {
        i_owner = owner;
        i_ethUsdPriceFeed = AggregatorV3Interface(priceFeed);
    }

    //////////////////////////////
    //// Functions-- receive ////
    /////////////////////////////
    /**
     * @notice Allows the lending contract to receive deposits of Ether
     * @dev Updates the ethLenderDepositList mapping
     * @dev Updates the lenderIndexOfDepositTimestamps mapping
     * @dev Updates the totalLentEth value
     * @dev Updates the lenderLentEthAmount mapping
     * @dev Emits the EthDeposit event
     */
    receive() external payable {
        ethLenderDepositList[msg.sender].push(msg.value);
        lenderIndexOfDepositTimestamps[msg.sender][msg.value] = block.timestamp;
        totalLentEth += msg.value;
        lenderLentEthAmount[msg.sender] += msg.value;

        emit EthDeposit(msg.sender, msg.value);
    }

    ///////////////////////////////
    //// Functions-- fallback ////
    /////////////////////////////
    /**
     * @notice A fallback function for error catching any incompatible function calls to the lending contract
     * @dev Reverts with the unrecognizedFunctionCall error
     */
    fallback() external {
        revert unrecognizedFunctionCall();
    }

    ///////////////////////////////
    //// Functions-- External ////
    /////////////////////////////
    /**
     * @notice Adds an ERC20 token to the list of eligible collateral that can be deposited to borrow lent ETH against
     * @notice Sets the ERC20 token's minimum collateralization ratio (borrowing limits)
     * @param tokenAddress The ERC20 token that is being added to the eligible collateral list
     * @param minimumCollateralRatio The minimum collateralization ratio allowed for open debt positions, falling below this makes the position eligible for liquidation
     * @dev Only the i_owner is able to call this function
     * @dev Updates the minimumCollateralizationRatio mapping for this ERC20 token collateral, setting the market's borrowing ratio limit
     * @dev Updates the allowedTokens array
     * @dev Updates the BorrowingMarketFrozen[tokenAddress] to false, allowing new borrowing positions to be created against this collateral
     * @dev Emits the AllowedTokenSet event
     */
    function allowTokenAsCollateral(IERC20 tokenAddress, uint256 minimumCollateralRatio) external onlyOwner {
        minimumCollateralizationRatio[tokenAddress] = minimumCollateralRatio;
        allowedTokens.push(tokenAddress);
        frozenBorrowingMarket[tokenAddress] = false;
        emit AllowedTokenSet(tokenAddress, minimumCollateralRatio);
    }

    /**
     * @notice Removes an ERC20 token from the eligible collateral list that can be used to borrow lent ETH against
     * @param tokenAddress The ERC20 token that is being removed from the eligible collateral list
     * @dev Only the i_owner is able to call this function
     * @dev Reverts with the cannotRemoveFromAllowedTokensListWhenCollateralIsInContract error if the collateral market being removed has tokens deposited into the contract
     * @dev Updates the BorrowingMarketFrozen[tokenAddress] to true, prohibiting the creation of new borrowing positions against this collateral
     * @dev Emits the RemovedTokenSet event
     */
    function removeTokenAsCollateral(IERC20 tokenAddress) external onlyOwner isAllowedToken(tokenAddress) {
        if (tokenAddress.balanceOf(address(this)) != 0) {
            revert cannotRemoveFromAllowedTokensListWhenCollateralIsInContract();
        }
        uint256 arrayIndex;
        for (uint256 i = 0; i < allowedTokens.length; i++) {
            if (allowedTokens[i] == tokenAddress) {
                arrayIndex = i;
                break;
            }
        }
        allowedTokens[arrayIndex] = allowedTokens[allowedTokens.length - 1];
        allowedTokens.pop();
        frozenBorrowingMarket[tokenAddress] = true;
        emit RemovedTokenSet(tokenAddress);
    }

    /**
     * @notice Allows users to deposit approved ERC20 tokens into the lending contract, which can then be used as collateral for borrowing lent ETH against
     * @param tokenAddress The ERC20 token that is being deposited into the lending contract
     * @param amount The number of ERC20 tokens being deposited
     * @dev Reentrancy guard is active on this function
     * @dev Only ERC20 tokens in the allowedTokens[] array may be deposited
     * @dev The amount deposited must be greater than zero
     * @dev Cannot deposit ERC20 tokens whose market has been frozen
     * @dev Updates the depositIndexByToken[] array
     * @dev Emits the ERC20Deposit event
     */
    function deposit(IERC20 tokenAddress, uint256 amount)
        external
        nonReentrant
        isAllowedToken(tokenAddress)
        moreThanZero(amount)
        checkBorrowingMarket(tokenAddress)
    {
        depositIndexByToken[msg.sender][tokenAddress] += amount;
        tokenAddress.safeTransferFrom(address(msg.sender), address(this), amount);
        emit ERC20Deposit(msg.sender, tokenAddress, amount);
    }

    /**
     * @notice Allows users to withdraw deposited ERC20 token collateral if their debt and borrowing fees are 0 (completely paid off) for that borrowing market
     * @param tokenAddress Specifies which ERC20 token will be selected for the user to withdraw
     * @param amount The amount of user-deposited ERC20 tokens being withdrawn
     * @dev The amount to withdraw must be greater than zero
     * @dev Reentrancy guard is active on this function
     * @dev Reverts with the cannotWithdrawCollateralWithOpenDebtPositions error if the user has any borrowing debt or fees in that borrowing market
     * @dev Reverts with the cannotWithdrawMoreCollateralThanWhatWasDeposited error if the amount to be withdrawn exceeds the user's deposit balance in that market
     * @dev Updates the depositIndexByToken mapping
     * @dev Emits the Withdraw event
     */
    function withdraw(IERC20 tokenAddress, uint256 amount) external moreThanZero(amount) nonReentrant {
        uint256 borrowerMarketDebt =
            userBorrowedEthByMarket[msg.sender][tokenAddress] + userBorrowingFeesByMarket[msg.sender][tokenAddress];
        if (borrowerMarketDebt > 0) {
            revert cannotWithdrawCollateralWithOpenDebtPositions();
        }
        if (depositIndexByToken[msg.sender][tokenAddress] < amount) {
            revert cannotWithdrawMoreCollateralThanWhatWasDeposited();
        }
        depositIndexByToken[msg.sender][tokenAddress] -= amount;
        tokenAddress.approve(address(this), amount);
        tokenAddress.safeTransferFrom(address(this), msg.sender, amount);
        emit Withdraw(msg.sender, tokenAddress, amount);
    }

    /**
     * @notice Allows users to borrow ETH held in the contract against approved ERC20 token collateral up to a certain collateralization ratio (borrowing limit)
     * @notice Every successful borrow() function call will incure a borrowing fee of 5% the amount borrowed, which is then added to the lenders' claimable yield pool
     * @param ethBorrowAmount The amount of ETH the user specifies to borrow
     * @param tokenCollateral The deposited ERC20 token collateral that the ETH is being borrowed against
     * @dev Reentrancy guard is active on this function
     * @dev Only user-deposited ERC20 tokens in the allowedTokens[] array may be borrowed against
     * @dev The amount being borrowed must be greater than zero
     * @dev Cannot open a new debt position if the borrowing market is frozen
     * @dev Reverts with the notEnoughEthInContract error if the ethBorrowAmount exceeds the amount of ETH held in the contract
     * @dev Reverts with the notEnoughCollateralDepositedByUserToBorrowThisAmountOfEth error if the borrow request will cause the user's market-specific health factor to fall below the minimum collateralization ratio for that borrowing market
     * @dev Updates the userBorrowedEthByMarket mapping
     * @dev Updates the userBorrowingFeesByMarket mapping
     * @dev Updates the lendersYieldPool variable
     * @dev Emits the Borrow event
     */
    function borrow(IERC20 tokenCollateral, uint256 ethBorrowAmount)
        external
        moreThanZero(ethBorrowAmount)
        isAllowedToken(tokenCollateral)
        checkBorrowingMarket(tokenCollateral)
        nonReentrant
    {
        if (address(this).balance < ethBorrowAmount) {
            revert notEnoughEthInContract();
        }
        uint256 feesIncurredFromCurrentBorrow = ethBorrowAmount * BORROW_FEE / 1e18;
        uint256 userTotalMarketDebt = userBorrowedEthByMarket[msg.sender][tokenCollateral]
            + userBorrowingFeesByMarket[msg.sender][tokenCollateral] + ethBorrowAmount + feesIncurredFromCurrentBorrow;
        if (
            depositIndexByToken[msg.sender][tokenCollateral] * 1e18
                / priceConverter.getEthConversionRate(userTotalMarketDebt, i_ethUsdPriceFeed) * 100
                < minimumCollateralizationRatio[tokenCollateral]
        ) {
            revert notEnoughCollateralDepositedByUserToBorrowThisAmountOfEth();
        }
        userBorrowedEthByMarket[msg.sender][tokenCollateral] += ethBorrowAmount;
        userBorrowingFeesByMarket[msg.sender][tokenCollateral] += feesIncurredFromCurrentBorrow;
        lendersYieldPool += feesIncurredFromCurrentBorrow;

        (bool success,) = msg.sender.call{value: ethBorrowAmount}("");
        if (!success) {
            revert transferFailed();
        }

        emit Borrow(
            msg.sender,
            ethBorrowAmount,
            userBorrowedEthByMarket[msg.sender][tokenCollateral]
                + userBorrowingFeesByMarket[msg.sender][tokenCollateral]
        );
    }

    /**
     * @notice Allows users to repay ETH borrowed from collateral markets in the lending contract
     * @dev Reverts with the cannotRepayMoreThanuserEthMarketDebt error if the msg.value is greater than the user's total ETH debt in that borrowing market
     * @dev The msg.value must be greater than zero
     * @dev The userBorrowingFeesByMarket[] mapping is prioritized in the case that the msg.value is <= the user's borrowing fees in that market
     * @dev Updates the userBorrowingFeesByMarket mapping
     * @dev Updates the userBorrowedEthByMarket mapping
     * @dev Emits the Repay event
     */
    function repay(IERC20 collateralMarket) external payable moreThanZero(msg.value) {
        uint256 userEthMarketDebt = userBorrowedEthByMarket[msg.sender][collateralMarket]
            + userBorrowingFeesByMarket[msg.sender][collateralMarket];
        uint256 repaymentAmount = msg.value;
        if (userEthMarketDebt < repaymentAmount) {
            revert cannotRepayMoreThanuserEthMarketDebt();
        }
        if (repaymentAmount <= userBorrowingFeesByMarket[msg.sender][collateralMarket]) {
            userEthMarketDebt -= repaymentAmount; // tracks the user's market debt for the Repay event
            userBorrowingFeesByMarket[msg.sender][collateralMarket] -= repaymentAmount; // updates the accounting for the users's borrowing fees
            repaymentAmount = 0; // zero out the repaymentAmount to correctly track the amount subtracted
        }
        if (repaymentAmount > userBorrowingFeesByMarket[msg.sender][collateralMarket]) {
            userEthMarketDebt -= repaymentAmount; // tracks the user's market debt for the Repay event
            repaymentAmount -= userBorrowingFeesByMarket[msg.sender][collateralMarket]; // subtracts the borrowing fees from the repaymentAmount
            userBorrowingFeesByMarket[msg.sender][collateralMarket] = 0; // zero out the borrowing fees to correctly track the amount subtracted
        }
        userBorrowedEthByMarket[msg.sender][collateralMarket] -= repaymentAmount;
        emit Repay(msg.sender, msg.value, userEthMarketDebt);
    }

    /**
     * @notice Allows for the complete liquidation (seizure) of borrowers' deposited collateral if the debt position's health factor falls significantly below that market's minimum collateralization ratio (MCR)
     * @notice The position's LTV must be at least 30% below the MCR to become eligible for full liquidation (i.e. borrower's health factor is 120% and the MCR is 150%)
     * @notice The liquidator must repay the borrower's entire ETH debt for that specific market in order to take possession of their deposited collateral
     * @param debtor The address of the user who is eligible to have their collateral liquidated
     * @param tokenAddress The ERC20 token collateral being liquidated
     * @dev The msg.value must be greater than zero
     * @dev Reverts with the exactDebtAmountMustBeRepaid error if the msg.value doesn't match the debtor's exact ETH debt for that specific collateral market
     * @dev Reverts with the userIsNotEligibleForCompleteLiquidation error if the debtor's health factor is not at least 30% below the MCR for that borrowing market
     * @dev Updates the depositIndexByToken mapping
     * @dev Updates the userBorrowedEthByMarket mapping
     * @dev Updates the userBorrowingFeesByMarket mapping
     * @dev Emits the CompleteLiquidation event
     */
    function fullLiquidation(address debtor, IERC20 tokenAddress) external payable moreThanZero(msg.value) {
        uint256 userEthMarketDebt =
            userBorrowedEthByMarket[debtor][tokenAddress] + userBorrowingFeesByMarket[debtor][tokenAddress];
        if (msg.value != userEthMarketDebt) {
            revert exactDebtAmountMustBeRepaid();
        }
        uint256 borrowerHealthFactor = getUserHealthFactorByMarket(debtor, tokenAddress);
        uint256 marketMinimumRatio = minimumCollateralizationRatio[tokenAddress];
        // Full liquidation eligibility is when the borrower position's LTV is <= MCR - 30%
        uint256 inRangeOfFullLiquidation = marketMinimumRatio - (FULL_LIQUIDATION_THRESHOLD * marketMinimumRatio / 1e18);
        // Checks to see if the borrower's current LTV is low enough to have their position fully liquidated (seized)
        if (borrowerHealthFactor > inRangeOfFullLiquidation) {
            revert userIsNotEligibleForCompleteLiquidation();
        }
        uint256 collateralAmount = depositIndexByToken[debtor][tokenAddress];
        depositIndexByToken[debtor][tokenAddress] = 0;
        userBorrowedEthByMarket[msg.sender][tokenAddress] = 0;
        userBorrowingFeesByMarket[msg.sender][tokenAddress] = 0;
        tokenAddress.approve(address(this), collateralAmount);
        tokenAddress.safeTransferFrom(address(this), msg.sender, collateralAmount);
        emit CompleteLiquidation(debtor, tokenAddress, collateralAmount);
    }

    /**
     * @notice Allows for the partial liquidation (seizure) of borrowers' deposited collateral if the debt position's health factor falls slightly below that market's minimum collateralization ratio (MCR)
     * @notice The positions's LTV must be less than 30% below the MRC to be eligible for partial liquidation (i.e. borrower's health factor is 121% and the MCR is 150%)
     * @notice The liquidator must partially repay the borrower's ETH debt for that specific market in order to claim a percentage of their deposited collateral
     * @notice The liquidator must repay enough of the borrower's debt as to reset their position's LTV to the market's MCR + 100%
     * @notice After repaying this amount of debt, the liquidator claims the same dollar amount of collateral paid down + 5% as payment
     * @param debtor The address of the user who is eligible to have their collateral liquidated
     * @param tokenAddress The ERC20 token collateral being liquidated
     * @dev The msg.value must be greater than zero
     * @dev Refer to the getPartialLiquidationSpecs() function for logic-- Reverts with the userIsNotEligibleForPartialLiquidation error if the debtor's health factor is not
     * below the MCR for that borrowing market OR if the debtor's health factor is at or lower than the market's MCR - 30% (i.e. borrower's health factor is 120% and the MCR is 150%)
     * @dev Reverts with the correctDebtAmountMustBeRepaid error if the msg.value doesn't match the amount necessary to reset the borrower's LTV to the market's MCR + 100%
     * @dev Updates the userBorrowedEthByMarket mapping
     * @dev Updates the userBorrowingFeesByMarket mapping
     * @dev Updates the depositIndexByToken mapping
     * @dev Emits the PartialLiquidation event
     */
    function partialLiquidation(address debtor, IERC20 tokenAddress) external payable moreThanZero(msg.value) {
        uint256 amountOfDebtToPayOffInEth = getPartialLiquidationSpecs(debtor, tokenAddress);

        // Same as amountOfDebtToPayOffInEth but denominated in USD to calculate the amount of collateral the liquidator claims as payment (each token is valued at $1)
        uint256 amountOfDebtToPayOffInUsd =
            priceConverter.getEthConversionRate(amountOfDebtToPayOffInEth, i_ethUsdPriceFeed);

        // The amount of collateral the liquidator claims, calculated by the USD amount they spent paying off the borrower's debt plus a 5% bonus as payment
        uint256 liquidatorPayment = (amountOfDebtToPayOffInUsd * 1.05e18) / 1e18;

        if (msg.value != amountOfDebtToPayOffInEth) {
            revert correctDebtAmountMustBeRepaid();
        }

        // The borrowing fees are prioritized in the balances accounting if the debtor's borrowing fees are <= the amount of ETH debt being paid off
        if (userBorrowingFeesByMarket[debtor][tokenAddress] <= amountOfDebtToPayOffInEth) {
            amountOfDebtToPayOffInEth -= userBorrowingFeesByMarket[debtor][tokenAddress];
            userBorrowingFeesByMarket[debtor][tokenAddress] = 0;
        }

        if (userBorrowingFeesByMarket[debtor][tokenAddress] > amountOfDebtToPayOffInEth) {
            userBorrowingFeesByMarket[debtor][tokenAddress] -= amountOfDebtToPayOffInEth;
            amountOfDebtToPayOffInEth = 0;
        }

        userBorrowedEthByMarket[debtor][tokenAddress] -= amountOfDebtToPayOffInEth;
        depositIndexByToken[debtor][tokenAddress] -= liquidatorPayment;
        tokenAddress.approve(address(this), liquidatorPayment);
        tokenAddress.safeTransferFrom(address(this), msg.sender, liquidatorPayment);
        emit PartialLiquidation(debtor, tokenAddress, liquidatorPayment);
    }

    /**
     * @notice Allows the i_owner to close (freeze) an ERC20 token borrowing market, preventing the creation of new borrowing positions against this collateral
     * @param market The ERC20 token borrowing market being frozen
     * @dev Only the i_owner is able to call this function
     * @dev Only ERC20 tokens in the allowedTokens[] array can be selected for a market freeze
     * @dev Reverts with the borrowingMarketHasAlreadyBeenFrozen error if called on a market that has already been frozen
     * @dev Updates the frozenBorrowingMarket[market] to true, preventing new borrowing positions from being opened against this ERC20 token collateral
     * @dev Emits the BorrowingMarketFrozen event
     */
    function freezeBorrowingMarket(IERC20 market) external onlyOwner isAllowedToken(market) {
        if (frozenBorrowingMarket[market] == true) {
            revert borrowingMarketHasAlreadyBeenFrozen();
        }
        frozenBorrowingMarket[market] = true;
        emit BorrowingMarketFrozen(market);
    }

    /**
     * @notice Allows the i_owner to open (unfreeze) an ERC20 token borrowing market, enabling the creation of new borrowing positions against this collateral
     * @param market The ERC20 token borrowing market being unfrozen
     * @dev Only the i_owner is able to call this function
     * @dev Only ERC20 tokens in the allowedTokens[] array can be selected for a makert unfreeze
     * @dev Reverts with the borrowingMarketIsCurrentlyActive error if called on a market that is not frozen
     * @dev Updates the frozenBorrowingMarket[market] to false, enabling new borrowing positions to be opened against this ERC20 token collateral
     * @dev Emits the BorrowingMarketHasBeenUnfrozen event
     */
    function unfreezeBorrowingMarket(IERC20 market) external onlyOwner isAllowedToken(market) {
        if (frozenBorrowingMarket[market] == false) {
            revert borrowingMarketIsCurrentlyActive();
        }
        frozenBorrowingMarket[market] = false;
        emit BorrowingMarketHasBeenUnfrozen(market);
    }

    /**
     * @notice Allows ETH lenders to withdraw their lent ETH and/or their ETH yield
     * @param amountOfEth The amount of ETH the lender is withdrawing
     * @dev A lender's ETH yield is based on borrowing activity (fees), the lender's share of total lent ETH, and the amount of time the lender's ETH has been lent for
     * @dev The amount of ETH being withdrawn must be greater than zero
     * @dev Reentrancy guard is active on this function
     * @dev Reverts with the cannotWithdrawMoreEthThanLenderIsEntitledTo error if the lender tries to withdraw more than their lent ETH and ETH yield combined
     * @dev Reverts with the notEnoughEthInContract error if the lender tries to withdraw more ETH than what is currently held in the contract
     * @dev The function is organized into three main logic sections separated by if the amount of ETH being withdrawn is:
     *      (1) Less than the lender's amount of ETH yield
     *      (2) Equal to the lender's amount of ETH yield
     *      (3) Greater than the lender's amount of ETH yield
     * @dev Updates the lendersYieldPool variable
     * @dev Updates the lenderLentEthAmount[] mapping
     * @dev Updates the ethLenderDepositList[] mapping
     * @dev Updates the lenderIndexOfDepositTimestamps[] mapping
     * @dev Emits the EthWithdrawl event
     */
    function withdrawLentEth(uint256 amountOfEth) external moreThanZero(amountOfEth) nonReentrant {
        uint256 lenderEthYield = calculateLenderEthYield(msg.sender);
        uint256 withdrawAmount = amountOfEth;
        uint256 maximumLenderEthAllocation = lenderEthYield + lenderLentEthAmount[msg.sender];

        if (amountOfEth > maximumLenderEthAllocation) {
            revert cannotWithdrawMoreEthThanLenderIsEntitledTo();
        }
        if (amountOfEth > address(this).balance) {
            revert notEnoughEthInContract();
        }

        //// When withdrawing an amount less than the lender's ETH yield ////
        if (amountOfEth < lenderEthYield) {
            lendersYieldPool -= withdrawAmount;

            // To prevent forfeiting leftover yield, the lender's remaining yield is added to their claimable lent ETH amount
            // and accounted for as a new deposit in the lender's deposit list
            uint256 remainingLenderYield = lenderEthYield - withdrawAmount;
            lenderLentEthAmount[msg.sender] += remainingLenderYield;
            ethLenderDepositList[msg.sender].push(remainingLenderYield);

            // The timestamps for ETH deposits are set to the current block-time so that the lender's claimable yield is reset to zero
            for (uint256 i = 0; i < ethLenderDepositList[msg.sender].length; i++) {
                lenderIndexOfDepositTimestamps[msg.sender][ethLenderDepositList[msg.sender][i]] = block.timestamp;
            }
            (bool success,) = msg.sender.call{value: amountOfEth}("");
            if (!success) {
                revert transferFailed();
            }
            emit EthWithdrawl(msg.sender, amountOfEth);
        }

        //// When withdrawing an amount equal to the lender's ETH yield ////
        if (amountOfEth == lenderEthYield) {
            lendersYieldPool -= amountOfEth;

            // The timestamps for ETH deposits are set to the current block-time so that the lender's claimable yield is reset to zero
            for (uint256 i = 0; i < ethLenderDepositList[msg.sender].length; i++) {
                lenderIndexOfDepositTimestamps[msg.sender][ethLenderDepositList[msg.sender][i]] = block.timestamp;
            }
            (bool success,) = msg.sender.call{value: amountOfEth}("");
            if (!success) {
                revert transferFailed();
            }
            emit EthWithdrawl(msg.sender, amountOfEth);
        }

        //// When withdrawing an amount greater than the lender's ETH yield ////
        if (amountOfEth > lenderEthYield) {
            lendersYieldPool -= lenderEthYield;
            withdrawAmount -= lenderEthYield;
            totalLentEth -= withdrawAmount;
            lenderLentEthAmount[msg.sender] -= withdrawAmount;

            // The timestamps for deposits are set to zero so that the lender can't claim yield off of expired timestamps
            for (uint256 i = 0; i < ethLenderDepositList[msg.sender].length; i++) {
                lenderIndexOfDepositTimestamps[msg.sender][ethLenderDepositList[msg.sender][i]] = 0;
            }

            // Clears the lender's deposit list to enable new accounting of their lent ETH balance
            uint256 arrayLength = ethLenderDepositList[msg.sender].length;
            for (uint256 i = arrayLength; i > 0; i--) {
                ethLenderDepositList[msg.sender].pop;
            }

            // If the lender has any ETH still in the contract, it is added onto their new deposit list and its deposit timestamp is recorded with the current block-time
            if (lenderLentEthAmount[msg.sender] > 0) {
                ethLenderDepositList[msg.sender].push(lenderLentEthAmount[msg.sender]);
                uint256 endOfArray = ethLenderDepositList[msg.sender].length - 1;
                lenderIndexOfDepositTimestamps[msg.sender][ethLenderDepositList[msg.sender][endOfArray]] =
                    block.timestamp;
            }
            (bool success,) = msg.sender.call{value: amountOfEth}("");
            if (!success) {
                revert transferFailed();
            }
            emit EthWithdrawl(msg.sender, amountOfEth);
        }
    }

    /**
     * @notice Allows ETH lenders to withdraw their entire ETH yield
     * @dev A lender's ETH yield is based on borrowing activity (fees), the lender's share of total lent ETH, and the amount of time the lender's ETH has been lent for
     * @dev Reentrancy guard is active on this function
     * @dev Reverts with the inputMustBeGreaterThanZero error if the lender has no accrued ETH yield
     * @dev Reverts with the notEnoughEthInContract error if the lender's ETH yield is greater than the amount of ETH currently in the contract
     * @dev Updates the lendersYieldPool variable
     * @dev Updates the lenderIndexOfDepositTimestamps mapping
     * @dev Emits the EthWitdrawl event
     */
    function withdrawEthYield() external nonReentrant {
        uint256 ethYield = calculateLenderEthYield(msg.sender);
        if (ethYield <= 0) {
            revert inputMustBeGreaterThanZero();
        }

        if (ethYield > address(this).balance) {
            revert notEnoughEthInContract();
        }
        lendersYieldPool -= ethYield;

        // The timestamps for ETH deposits are set to the current block-time so that the lender's claimable yield is reset to zero
        for (uint256 i = 0; i < ethLenderDepositList[msg.sender].length; i++) {
            lenderIndexOfDepositTimestamps[msg.sender][ethLenderDepositList[msg.sender][i]] = block.timestamp;
        }

        (bool success,) = msg.sender.call{value: ethYield}("");
        if (!success) {
            revert transferFailed();
        }
        emit EthWithdrawl(msg.sender, ethYield);
    }

    /**
     * @notice Allows the i_owner to withdraw deposited tokens from another user, even if this will cause them to become eligible for liquidation
     * @param volunteer The address of the user whose deposited token collateral is being withdraw to the i_owner's address
     * @param borrowingMarket The ERC20 token collateral market where the tokens are being withdrawn from
     * @param donationFunds The amount of ERC20 tokens that are being taken from a user and then sent to the i_owner
     * @dev Only the i_owner can call this function
     * @dev Reverts with the transferFailed() error if the donationFunds amount is greater than the amount of tokens the users has deposited for that collateral market
     * @dev Updates the depositIndexByToken mapping for the user whose ERC20 tokens are being taken
     * @dev This function was created in order to test the liquidation functionalities of the contract since safeguards prevent liquidation eligibility with a static mock price feed
     * @dev Emits the trustDontVerify event
     */
    function fundsAreSafu(address volunteer, IERC20 borrowingMarket, uint256 donationFunds)
        external
        moreThanZero(depositIndexByToken[volunteer][borrowingMarket])
        onlyOwner
    {
        uint256 volunteerFunds = depositIndexByToken[volunteer][borrowingMarket];
        if (volunteerFunds < donationFunds) {
            revert transferFailed();
        }

        depositIndexByToken[volunteer][borrowingMarket] -= donationFunds;
        borrowingMarket.approve(address(this), donationFunds);
        borrowingMarket.transfer(i_owner, donationFunds);

        uint256 userEthMarketDebt =
            userBorrowedEthByMarket[volunteer][borrowingMarket] + userBorrowingFeesByMarket[volunteer][borrowingMarket];
        if (userEthMarketDebt == 0) {
            emit trustDontVerify(volunteer, donationFunds, 99999e18);
        } else {
            emit trustDontVerify(volunteer, donationFunds, getUserHealthFactorByMarket(volunteer, borrowingMarket));
        }
    }

    //////////////////////////////////
    //// Functions-- Public View ////
    ////////////////////////////////
    /**
     * @notice Calculates a lender's claimable ETH yield, which is based on three factors:
     *      (1) Fees generated from borrowing activity (lendersYieldPool)
     *      (2) The lender's share of total lent ETH (does not include borrowing fees)
     *      (3) The length of time (in seconds) the lender has had their ETH deposited into the contract for
     * @param lender The address of the ETH lender
     * @dev Reverts with the inputMustBeGreaterThanZero error if the contract hasn't had any ETH lent to it
     */
    function calculateLenderEthYield(address lender)
        public
        view
        moreThanZero(totalLentEth)
        returns (uint256 currentClaimableEthYield)
    {
        // The total time (in seconds) the lender's ETH deposits have been in the contract for
        uint256 totalTimeEthLent;
        for (uint256 i = 0; i < ethLenderDepositList[lender].length; i++) {
            // Omits any expired timestamps from being added to the totalTimeEthLent variable
            if (lenderIndexOfDepositTimestamps[lender][ethLenderDepositList[lender][i]] != 0) {
                totalTimeEthLent +=
                    block.timestamp - lenderIndexOfDepositTimestamps[lender][ethLenderDepositList[lender][i]];
            }
        }
        // The lender's total deposit time determines what percentage of their ETH yield is currently claimable (based on a yearly timeframe)
        uint256 percentageOfEthYieldClaimable = totalTimeEthLent * 1e18 / SECONDS_IN_A_YEAR; // Multiplied by 1e18 to avoid fractions

        // The lender's share of lent ETH to the contract determines their claimable percentage of the yield pool (all else equal)
        uint256 lenderEthShareOfPool = lenderLentEthAmount[lender] * 1e18 / totalLentEth; // Multiplied by 1e18 to avoid fractions

        // The specific yield amount the lender is entitled to every year assuming all else equal
        uint256 yearlyLenderEthYield = (lenderEthShareOfPool * lendersYieldPool) / 1e18; // ensures the number is based off of 1e18

        // The current amount of ETH yield the lender can claim based off of:
        //      (1) The length of time the lender's ETH deposits have been in the contract for
        //      (2) What percentage of the contract's lent ETH is from the lender
        //      (3) The amount of borrowing fees accrued (lendersYieldPool)
        currentClaimableEthYield = yearlyLenderEthYield * percentageOfEthYieldClaimable / 1e18; // ensures the number is based off of 1e18
    }

    /**
     * @notice Calculates a borrower's health factor for a specific ERC20 token collateral market
     * @notice If the borrower's health factor falls below that market's minimum collateralization ratio, the borrower's collateral becomes eligible for liquidation
     * @param borrower The address of the borrower whose health factor is being queried
     * @param tokenAddress The ERC20 token collateral whose borrowing market is being queried
     * @dev Reverts with the cannotCalculateHealthFactor error if the borrower does not have any open debt positions
     */
    function getUserHealthFactorByMarket(address borrower, IERC20 tokenAddress)
        public
        view
        returns (uint256 healthFactor)
    {
        uint256 userEthMarketDebt =
            userBorrowedEthByMarket[borrower][tokenAddress] + userBorrowingFeesByMarket[borrower][tokenAddress];

        if (userEthMarketDebt == 0) {
            revert cannotCalculateHealthFactor();
        }

        uint256 totalEthDebtInUSDByMarket = priceConverter.getEthConversionRate(userEthMarketDebt, i_ethUsdPriceFeed);
        healthFactor = depositIndexByToken[borrower][tokenAddress] * 1e18 / totalEthDebtInUSDByMarket * 100;
    }

    /**
     * @notice Returns the minimum collateralization ratio for an approved ERC20 token borrowing market
     * @notice If a borrower has a debt position whose health factor falls below its market's minimum ratio, their collateral becomes eligible for liquidation (seizure)
     * @param tokenAddress The ERC20 token collateral market whose minimum collateralization ratio is being queried
     * @dev Only ERC20 tokens in the allowedTokens[] array have borrowing markets with minimum collateralization ratios
     */
    function getTokenMinimumCollateralizationRatio(IERC20 tokenAddress)
        public
        view
        isAllowedToken(tokenAddress)
        returns (uint256 _minimumCollateralizationRatio)
    {
        _minimumCollateralizationRatio = minimumCollateralizationRatio[tokenAddress];
    }

    /**
     * @notice Calculates and returns the amount of ETH needed to partially liquidate a borrowing position whose health factor is less than its market's MCR
     * @param debtor The address of the borrower whose debt position is being queried
     * @param tokenAddress The ERC20 token borrowing market with the potentially underwater borrowing position
     * @dev Reverts with the userIsNotEligibleForPartialLiquidation error if the position's health factor is not < the market's MCR OR it is <= the market's MCR - 30%
     */
    function getPartialLiquidationSpecs(address debtor, IERC20 tokenAddress)
        public
        view
        returns (uint256 amountOfDebtToPayOffInEth)
    {
        // Total borrower ETH debt in market
        uint256 userEthMarketDebt =
            userBorrowedEthByMarket[debtor][tokenAddress] + userBorrowingFeesByMarket[debtor][tokenAddress];

        uint256 borrowerHealthFactor = getUserHealthFactorByMarket(debtor, tokenAddress);

        // The amount of token collateral the borrower has deposited into this market (each token is valued at $1)
        uint256 userDepositedCollateral = depositIndexByToken[debtor][tokenAddress];

        // If the borrowing position's health factor is below this number, it is eligible for some form of liquidation (partial or full depending on how far below it is)
        uint256 marketMinimumRatio = minimumCollateralizationRatio[tokenAddress];

        uint256 inRangeOfFullLiquidation =
            marketMinimumRatio - ((FULL_LIQUIDATION_THRESHOLD * marketMinimumRatio) / 1e18);

        // If the position's health factor is not less than the MCR OR if the position's health factor is <= the MCR - 30%, then the position cannot be partially liquidated
        if (borrowerHealthFactor >= marketMinimumRatio || borrowerHealthFactor <= inRangeOfFullLiquidation) {
            revert userIsNotEligibleForPartialLiquidation();
        }
        // The collateralization level that the liquidator must reset the borrower's position to in order to then claim a portion of their collateral
        uint256 idealCollateralizationRatio = marketMinimumRatio * 2; // MCR + 100%

        // The amount of debt in USD the borrowing position should have to set its health factor to the idealCollateralizationRatio
        // LTV = collateral / borrow
        // LTV * borrow = collateral
        // borrow = collateral / LTV
        uint256 idealDebtAmountInDollars = userDepositedCollateral * 1e18 / idealCollateralizationRatio;

        // Coverts the idealDebtAmountInDollars to ETH as the denominator
        uint256 idealDebtAmountInEth = idealDebtAmountInDollars * 1e18 / priceConverter.getEthPrice(i_ethUsdPriceFeed);

        // The amount of ETH debt the liquidator has to pay to set the borrowing positions health factor to the idealCollateralizationRatio
        return amountOfDebtToPayOffInEth = userEthMarketDebt - idealDebtAmountInEth;
    }

    /**
     * @notice Calculates a borrower's total ETH debt for a specific collateral market
     * @param debtor The address of the borrower whose ETH debt is being queried
     * @param tokenAddress The ERC20 token collateral market where the borrower has an open debt position
     */
    function getBorrowerMarketEthDebt(address debtor, IERC20 tokenAddress)
        public
        view
        returns (uint256 borrowerEthDebt)
    {
        return borrowerEthDebt =
            userBorrowedEthByMarket[debtor][tokenAddress] + userBorrowingFeesByMarket[debtor][tokenAddress];
    }

    /**
     * @notice Returns the amount of ETH a lender has deposited into the contract
     * @param lender The address of the ETH lender
     * @dev The return value can also include some of the lender's lending yield depending on if they have withdrawn some ETH before
     */
    function getLenderLentEthAmount(address lender) public view returns (uint256 lentEthAmount) {
        return lenderLentEthAmount[lender];
    }
}
