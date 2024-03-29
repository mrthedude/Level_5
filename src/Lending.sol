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
 */
contract lending {
    /////////////////
    //// Errors ////
    ////////////////
    error unrecognizedFunctionCall();
    error notEligibleAsCollateral();
    error inputMustBeGreaterThanZero();
    error notAuthorizedToCallThisFunction();
    error cannotWithdrawCollateralWithOpenDebtPositions();
    error cannotRemoveFromCollateralListWithOpenDebtPositions();
    error cannotRepayMoreThanTotalUserDebt();
    error transferFailed();
    error notEnoughEthInContract();
    error notEnoughCollateralDepositedByUserToBorrowThisAmountOfEth();
    error cannotWithdrawMoreCollateralThanWhatWasDeposited();
    error userIsNotEligibleForLiquidation();
    error entireDebtPositionMustBePaidToBeAbleToLiquidate();
    error cannotCalculateHealthFactor();
    error borrowingMarketHasAlreadyBeenFrozen();
    error borrowingMarketIsCurrentlyActive();
    error cannotWithdrawMoreEthThanLenderIsEntitledTo();

    //////////////////////////
    //// State Variables ////
    /////////////////////////
    /// @notice Address with special function privileges
    address public immutable i_owner;
    /// @dev Chainlink ETH/USD price feed
    AggregatorV3Interface private immutable i_EthUsdPriceFeed;
    /// @notice Fixed borrow fee to be paid in ETH before the deposited collateral can be withdrawn by the borrower
    uint256 public constant BORROW_FEE = 5e16; // 5% fee on the amount of ETH borrowed per borrow() function call
    /// @notice Variable specifying the number of seconds in a year to avoid extra clutter in the codebase
    uint256 public constant SECONDS_IN_A_YEAR = 31536000 seconds; // (60sec * 60mins * 24hrs * 365days)
    /// @notice Accounts for the total amount of fees that lenders can claim on a pro-rata basis. Updated with every borrow() function call and ETH claim from lenders
    uint256 public lendersYieldPool;
    /// @notice The total amount of ETH lenders have deposited into the contract
    uint256 totalLentEth;
    /// @notice Dynamic array of ERC20 token addresses that are eligible to be deposited as collateral to borrow lent ETH against
    IERC20[] public allowedTokens;

    /// @notice Tracks the deposit balance of the ERC20 tokens a user has supplied to the contract as borrowing collateral
    mapping(address user => mapping(IERC20 tokenAddress => uint256 amountDeposited)) public depositIndexByToken;
    /// @notice Tracks the amount of ETH a user has borrowed from the contract
    mapping(address borrower => uint256 amount) public borrowedEthAmount;
    /// @notice Tracks a user's total borrowing fees which must be paid to the contract in order to withdraw the deposited collateral
    mapping(address borrower => uint256 userBorrowingFees) public userBorrowingFees;
    /// @notice Tracks the minimum collateralization ratio for approved ERC20 token collateral, below which the borrowing position is eligible for liquidation
    mapping(IERC20 token => uint256 collateralFactor) public minimumCollateralizationRatio;
    /// @notice Tracks a market's borrowing status to see if new borrowing positions can be opened against certain ERC20 token collateral
    mapping(IERC20 borrowMarket => bool borrowingFrozen) public frozenBorrowingMarket;
    /// @notice Tracks the individual lenders' ETH deposits
    mapping(address lender => uint256) public lenderLentEthAmount;
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
    event Repay(address indexed user, uint256 indexed amountRepaid, uint256 indexed totalUserEthDebt);
    event Borrow(address indexed borrower, uint256 indexed ethAmountBorrowed, uint256 indexed totalUserEthDebt);
    event Withdraw(address indexed user, IERC20 indexed withdrawnTokenAddress, uint256 indexed amountWithdrawn);
    event ERC20Deposit(address indexed depositer, IERC20 indexed tokenAddress, uint256 indexed amountDeposited);
    event Liquidate(address indexed debtor, IERC20 indexed tokenAddress, uint256 indexed tokenAmountLiquidated);

    ////////////////////
    //// Modifiers ////
    ///////////////////

    /**
     * @notice Modifier to check if an ERC20 token is eligible to be used as collateral for borrowing lent ETH
     * @param tokenAddress The address of the ERC20 token being checked for collateral eligibility
     * @dev Used in the following functions: removeTokenAsCollateral(), deposit(), withdraw(), borrow(), liquidate(), freezeBorrowingMarket(), UnfreezeBorrowingMarket() getTokenMinimumCollateralizationRatio()
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
     * @dev Used in the following functions: deposit(), withdraw(), borrow(), repay(), withdrawLentEth(), withdrawEthYield(), calculateLenderEthYield()
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
     * @dev Used in the following functions: allowTokenAsCollateral(), removeTokenAsCollateral(), freezeBorrowingMarket(), UnfreezeBorrowingMarket()
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
     * @dev Reverts with the borrowingMarketHasAlreadyBeenFrozen error if the market has already been frozen (closed)
     */
    modifier checkBorrowingMarket(IERC20 borrowingMarket) {
        if (frozenBorrowingMarket[borrowingMarket] == true) {
            revert borrowingMarketHasAlreadyBeenFrozen();
        }
        _;
    }

    ////////////////////
    //// Functions ////
    ///////////////////
    /**
     * @notice Sets the i_owner and i_EthUsdPriceFeed of the lending contract upon deployment
     * @param _owner Sets the address that will have special prvileges for certain function calls --> allowTokenAsCollateral(), removeTokenAsCollateral(), freezeBorrowingMarket(), UnfreezeBorrowingMarket()
     * @param priceFeed Sets the Chainlink ETH/USD price feed that will be used to determine the LTV of open debt positions
     */
    constructor(address _owner, address priceFeed) {
        i_owner = _owner;
        i_EthUsdPriceFeed = AggregatorV3Interface(priceFeed);
    }

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

    /**
     * @notice A fallback function for error catching any incompatible function calls to the lending contract
     * @dev Reverts with the unrecognizedFunctionCall error
     */
    fallback() external {
        revert unrecognizedFunctionCall();
    }

    /**
     * @notice Adds an ERC20 token to the list of eligible collateral that can be deposited to borrow lent ETH against
     * @notice Sets the ERC20 token's minimumCollateralizationRatio (borrowing limits)
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
     * @dev Reverts with the cannotRemoveFromCollateralListWithOpenDebtPositions error if the collateral being removed has open debt positions
     * @dev Updates the BorrowingMarketFrozen[tokenAddress] to true, prohibiting the creation of new borrowing positions against this collateral
     * @dev Emits the RemovedTokenSet event
     */
    function removeTokenAsCollateral(IERC20 tokenAddress) external onlyOwner isAllowedToken(tokenAddress) {
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
        frozenBorrowingMarket[tokenAddress] = true;
        emit RemovedTokenSet(tokenAddress);
    }

    /**
     * @notice Allows users to deposit approved ERC20 tokens into the lending contract
     * @param tokenAddress The ERC20 token that is being deposited into the lending contract
     * @param amount The number of ERC20 tokens being deposited
     * @dev Only ERC20 tokens in the allowedTokens[] array may be deposited
     * @dev The amount deposited must be greater than zero
     * @dev Cannot deposit ERC20 tokens whose market has been frozen
     * @dev Updates the depositIndexByToken[] array
     * @dev Emits the ERC20Deposit event
     */
    function deposit(IERC20 tokenAddress, uint256 amount)
        external
        isAllowedToken(tokenAddress)
        moreThanZero(amount)
        checkBorrowingMarket(tokenAddress)
    {
        depositIndexByToken[msg.sender][tokenAddress] += amount;
        tokenAddress.safeTransferFrom(address(msg.sender), address(this), amount);
        emit ERC20Deposit(msg.sender, tokenAddress, amount);
    }

    /**
     * @notice Allows users to withdraw deposited ERC20 token collateral if their debt and borrowing fees are 0 (completely paid off)
     * @param tokenAddress Specifies which ERC20 token will be selected for the user to withdraw
     * @param amount The amount of user-deposited ERC20 tokens being withdrawn
     * @dev Only ERC20 tokens in the allowedTokens[] array may be withdrawn
     * @dev The amount to withdraw must be greater than zero
     * @dev Reverts with the cannotWithdrawCollateralWithOpenDebtPositions error if the user has any borrowing debt or fees
     * @dev Reverts with the cannotWithdrawMoreCollateralThanWhatWasDeposited error if the amount to be withdrawn exceeds the user's deposit balance
     * @dev Updates the depositIndexByToken mapping
     * @dev Emits the Withdraw event
     */
    function withdraw(IERC20 tokenAddress, uint256 amount) external moreThanZero(amount) isAllowedToken(tokenAddress) {
        uint256 totalUserEthDebt = borrowedEthAmount[msg.sender] + userBorrowingFees[msg.sender];
        if (totalUserEthDebt > 0) {
            revert cannotWithdrawCollateralWithOpenDebtPositions();
        }
        if (depositIndexByToken[msg.sender][tokenAddress] < amount) {
            revert cannotWithdrawMoreCollateralThanWhatWasDeposited();
        }
        depositIndexByToken[msg.sender][tokenAddress] -= amount;
        tokenAddress.safeTransferFrom(address(this), msg.sender, amount);
        emit Withdraw(msg.sender, tokenAddress, amount);
    }

    /**
     * @notice Allows users to borrow ETH held in the contract against approved ERC20 token collateral up to a certain collateralization ratio (borrowing limit)
     * @notice Every successful borrow() function call will incure a borrowing fee of 5% the amount borrowed, which is then added to the lenders' claimable yield pool
     * @param ethBorrowAmount The amount of ETH the user specifies to borrow
     * @param tokenCollateral The deposited ERC20 token collateral that the ETH is being borrowed against
     * @dev Only approved, user-deposited ERC20 token collateral may be borrowed against
     * @dev The amount being borrowed must be greater than zero
     * @dev Reverts with the notEnoughEthInContract error if the ethBorrowAmount exceeds the amount of ETH held in the contract
     * @dev Reverts with the notEnoughCollateralDepositedByUserToBorrowThisAmountOfEth error if the borrow request will cause the user's health factor to fall below the minimum collateralization ratio for that ERC20 token borrowing market
     * @dev Updates the ethBorrowAmount mapping
     * @dev Updates the userBorrowingFees mapping
     * @dev Updates the lendersYieldPool
     * @dev Emits the Borrow event
     */
    function borrow(IERC20 tokenCollateral, uint256 ethBorrowAmount)
        external
        moreThanZero(ethBorrowAmount)
        isAllowedToken(tokenCollateral)
        checkBorrowingMarket(tokenCollateral)
    {
        uint256 feesIncurredFromCurrentBorrow = ethBorrowAmount * BORROW_FEE;
        uint256 totalUserEthDebt = borrowedEthAmount[msg.sender] + userBorrowingFees[msg.sender] + ethBorrowAmount
            + feesIncurredFromCurrentBorrow;
        if (address(this).balance < ethBorrowAmount) {
            revert notEnoughEthInContract();
        }
        if (
            depositIndexByToken[msg.sender][tokenCollateral] * 1e18
                / priceConverter.getEthConversionRate(totalUserEthDebt, i_EthUsdPriceFeed) * 100
                < minimumCollateralizationRatio[tokenCollateral]
        ) {
            revert notEnoughCollateralDepositedByUserToBorrowThisAmountOfEth();
        }

        borrowedEthAmount[msg.sender] += ethBorrowAmount;
        userBorrowingFees[msg.sender] += feesIncurredFromCurrentBorrow;
        lendersYieldPool += feesIncurredFromCurrentBorrow;

        (bool success,) = msg.sender.call{value: ethBorrowAmount}("");
        if (!success) {
            revert transferFailed();
        }

        emit Borrow(msg.sender, ethBorrowAmount, borrowedEthAmount[msg.sender]);
    }

    /**
     * @notice Allows users to repay the ETH they borrowed from the lending contract
     * @dev Reverts with the cannotRepayMoreThanTotalUserDebt error if the msg.value is greater than the user's total ETH debt
     * @dev The msg.value must be greater than zero
     * @dev The userBorrowingFees[] mapping is prioritized in the case that the msg.value is <= the user's borrowing fees
     * @dev Updates the user's borrowedEthAmount[] mapping
     * @dev Updates the user's userBorrowingFees[] mapping
     * @dev Emits the Repay event
     */
    function repay() external payable moreThanZero(msg.value) {
        uint256 totalUserDebt = borrowedEthAmount[msg.sender] + userBorrowingFees[msg.sender];
        uint256 repaymentAmount = msg.value;
        if (totalUserDebt < repaymentAmount) {
            revert cannotRepayMoreThanTotalUserDebt();
        }
        if (repaymentAmount <= userBorrowingFees[msg.sender]) {
            userBorrowingFees[msg.sender] -= repaymentAmount;
            repaymentAmount = 0;
        }
        if (repaymentAmount >= userBorrowingFees[msg.sender]) {
            uint256 interestExpense = userBorrowingFees[msg.sender];
            userBorrowingFees[msg.sender] = 0;
            repaymentAmount -= interestExpense;
        }
        borrowedEthAmount[msg.sender] -= repaymentAmount;
        emit Repay(msg.sender, msg.value, totalUserDebt);
    }

    /**
     * @notice Allows users to liquidate the deposited collateral of other users whose loan(s) have fallen below the collateral market's minimum collateralization ratio
     * @param debtor The address of the user who is eligible to have their collateral liquidated
     * @param tokenAddress The token address of the ERC20 token collateral being liquidated
     * @dev Only approved ERC20 token collateral may be liquidated
     * @dev Reverts with the userIsNotEligibleForLiquidation error if the debtor's health factor is not below the minimum collateralization ratio for that borrowing market
     * @dev Reverts with the entireDebtPositionMustBePaidToBeAbleToLiquidate error if the msg.value doesn't match the debtor's exact ETH debt
     * @dev Updates the debtor's depositIndexByToken to 0 for that collateral market
     * @dev Updates the debtor's userBorrowingFees to 0
     * @dev Emits the Liquidate event
     *
     */
    function liquidate(address debtor, IERC20 tokenAddress) external payable isAllowedToken(tokenAddress) {
        uint256 totalUserDebt = borrowedEthAmount[debtor] + userBorrowingFees[debtor];
        if (getUserHealthFactorByToken(debtor, tokenAddress) > minimumCollateralizationRatio[tokenAddress]) {
            revert userIsNotEligibleForLiquidation();
        }
        if (msg.value != totalUserDebt) {
            revert entireDebtPositionMustBePaidToBeAbleToLiquidate();
        }
        uint256 collateralAmount = depositIndexByToken[debtor][tokenAddress];
        depositIndexByToken[debtor][tokenAddress] = 0;
        borrowedEthAmount[debtor] = 0;
        userBorrowingFees[debtor] = 0;
        tokenAddress.safeTransferFrom(address(this), msg.sender, collateralAmount);
        emit Liquidate(debtor, tokenAddress, collateralAmount);
    }

    /**
     * @notice Allows the i_owner to stop (freeze) an ERC20 token collateral market from having new borrowing positions opened
     * @param market The ERC20 token borrowing market being frozen
     * @dev Only the i_owner is able to call this function
     * @dev Only ERC20 tokens in the allowedTokens[] array can be selected for a market freeze
     * @dev Reverts with the borrowingMarketHasAlreadyBeenFrozen error if called on a market that has already been frozen
     * @dev Sets the frozenBorrowingMarket[market] to true to prevent new borrowing positions from being opened against this ERC20 token collateral
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
     * @notice Allows the i_owner to re-open (unfreeze) an ERC20 token collateral market, enabling new borrowing positions to be opened against that collateral
     * @param market The ERC20 token borrowing market being unfrozen
     * @dev Only the i_owner is able to call this function
     * @dev Only ERC20 tokens in the allowedTokens[] array can be selected for a makert unfreeze
     * @dev Reverts with the borrowingMarketIsCurrentlyActive error if called on a market that is not frozen
     * @dev Sets the frozenBorrowingMarket[market] to false to enable the opening of new borrowing positions against this ERC20 token collateral
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
     * @notice Allows ETH lenders to withdraw their lent ETH and ETH yield generated from borrowing activity
     * @param amountOfEth The amount of ETH the lender is withdrawing to their address
     * @dev Reverts with the cannotWithdrawMoreEthThanLenderIsEntitledTo error if the lender tries to withdraw an amount more than their lent ETH and ETH yield combined
     * @dev Reverts with the notEnoughEthInContract error if the lender tries to withdraw more ETH than what is currently held in the contract
     * @dev Prioritizes withdrawing from the user's ETH yield if the amount requested to be withdrawn is <= their amount of ETH yield
     * @dev Updates the lendersYieldPool
     * @dev Updates the lentEthAmount[] mapping
     * @dev Emits the EthWithdrawl event
     */
    function withdrawLentEth(uint256 amountOfEth) external moreThanZero(amountOfEth) {
        uint256 withdrawAmount = amountOfEth;
        uint256 maximumLenderEthAllocation = calculateLenderEthYield(msg.sender) + lenderLentEthAmount[msg.sender];

        if (amountOfEth > maximumLenderEthAllocation) {
            revert cannotWithdrawMoreEthThanLenderIsEntitledTo();
        }
        if (amountOfEth > address(this).balance) {
            revert notEnoughEthInContract();
        }
        // When withdrawing exclusively from the lender's ETH yield
        if (amountOfEth <= calculateLenderEthYield(msg.sender)) {
            lendersYieldPool -= withdrawAmount;

            // The timestamps for deposits are reset to the current block-time (zero'd out) so that the lender's claimable yield is reset to zero after claiming
            for (uint256 i = 0; i < ethLenderDepositList[msg.sender].length; i++) {
                lenderIndexOfDepositTimestamps[msg.sender][ethLenderDepositList[msg.sender][i]] = block.timestamp;
            }

            withdrawAmount = 0;
            (bool success,) = msg.sender.call{value: amountOfEth}("");
            if (!success) {
                revert transferFailed();
            }
            emit EthWithdrawl(msg.sender, amountOfEth);
        }

        // When withdrawing from both the lender's ETH yield and their own deposited ETH
        if (amountOfEth >= calculateLenderEthYield(msg.sender)) {
            lendersYieldPool -= calculateLenderEthYield(msg.sender);
            withdrawAmount -= calculateLenderEthYield(msg.sender);
            lenderLentEthAmount[msg.sender] -= withdrawAmount;
            // The timestamps for deposits are reset to zero so that the lender can't try to claim yield off of old timestamps
            for (uint256 i = 0; i < ethLenderDepositList[msg.sender].length; i++) {
                lenderIndexOfDepositTimestamps[msg.sender][ethLenderDepositList[msg.sender][i]] = 0;
            }
            // Clears the lender's deposit list to enable fresh accounting of balances
            uint256 arrayLength = ethLenderDepositList[msg.sender].length;
            for (uint256 i = arrayLength; i > 0; i--) {
                ethLenderDepositList[msg.sender].pop;
            }
            // Adds the remaining ETH the lender still has in the contract to their deposit list if this value is greater than zero
            if (lenderLentEthAmount[msg.sender] > 0) {
                uint256 endOfArray = ethLenderDepositList[msg.sender].length - 1;
                ethLenderDepositList[msg.sender].push(lenderLentEthAmount[msg.sender]);
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
     * @notice Allows ETH lenders to withdraw their entire ETH yield, accrued from borrowing activity
     * @dev Reverts with the notEnoughEthInContract error if the lender's ETH yield is greater than the amount of ETH currently in the contract
     * @dev Updates the lendersYieldPool
     * @dev Emits the EthWitdrawl event
     */
    function withdrawEthYield() external moreThanZero(calculateLenderEthYield(msg.sender)) {
        uint256 ethYield = calculateLenderEthYield(msg.sender);

        if (ethYield > address(this).balance) {
            revert notEnoughEthInContract();
        }
        lendersYieldPool -= ethYield;

        // The timestamps for deposits are reset to the current block-time (zero'd out) so that the lender's claimable yield is reset to zero after claiming
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
     * @notice Calculates the amount of ETH yield a lender is entitled to based on borrowing activity and the lender's share of the total ETH pool less borrowing fees
     * @param lender The address of the ETH lender whose lending payout is being calculated
     * @dev Reverts with the inputMustBeGreaterThanZero error if there is no ETH in the contract     *
     */
    function calculateLenderEthYield(address lender)
        public
        view
        moreThanZero(address(this).balance)
        returns (uint256 currentLenderEthYield)
    {
        // Calculate the combined time of lender's ETH deposits
        uint256 totalTimeEthLent;
        for (uint256 i = 0; i < ethLenderDepositList[lender].length; i++) {
            // Checks to see if there is an old timestamp being reviewed, if so then it will not be added to the totalTimeEthLent variable
            if (lenderIndexOfDepositTimestamps[lender][ethLenderDepositList[lender][i]] != 0) {
                totalTimeEthLent +=
                    block.timestamp - lenderIndexOfDepositTimestamps[lender][ethLenderDepositList[lender][i]];
            }
        }
        // Calculate the percentage of the lender's claimable yield that they can claim currently
        uint256 percentageOfEthYieldClaimable = totalTimeEthLent / SECONDS_IN_A_YEAR;

        // Calculate the lender's percentage of lent ETH in the entire ETH pool
        uint256 lenderEthPercentageOfPool = lenderLentEthAmount[lender] / totalLentEth;

        // Calculate the maximum amount of ETH the lender can claim from the ETH yield pool
        uint256 maximumEthYieldLenderCanClaimFromYieldPool = lenderEthPercentageOfPool * lendersYieldPool;

        // Calculate the amount of the lender's ETH yield they can currently claim: maximumEthYieldLenderCanClaimFromYieldPool * percentageOfEthYieldClaimable
        currentLenderEthYield = maximumEthYieldLenderCanClaimFromYieldPool * percentageOfEthYieldClaimable;
    }

    /**
     * @notice Calculates a user's health factor in a specific ERC20 token borrowing market by dividing the amount of tokens the user deposited by their total ETH debt
     * @param user The address of the user whose health factor is being queried
     * @param tokenAddress The ERC20 token collateral whose borrowing market is being queried to calculate the user's health factor
     * @dev Reverts with the cannotCalculateHealthFactor error if the user does not have any borrowing debt
     */
    function getUserHealthFactorByToken(address user, IERC20 tokenAddress) public view returns (uint256 healthFactor) {
        uint256 totalUserEthDebt = borrowedEthAmount[msg.sender] + userBorrowingFees[msg.sender];

        if (totalUserEthDebt == 0) {
            revert cannotCalculateHealthFactor();
        }

        uint256 totalEthDebtInUSD = priceConverter.getEthConversionRate(totalUserEthDebt, i_EthUsdPriceFeed);
        healthFactor = depositIndexByToken[user][tokenAddress] * 1e18 / totalEthDebtInUSD * 100;
    }

    function getTokenMinimumCollateralizationRatio(IERC20 tokenAddress)
        public
        view
        isAllowedToken(tokenAddress)
        returns (uint256 _minimumCollateralizationRatio)
    {
        _minimumCollateralizationRatio = minimumCollateralizationRatio[tokenAddress];
    }
}
