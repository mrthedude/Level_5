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

/////////////////
//// Errors ////
////////////////
error unrecognizedFunctionCall();
error notEligibleAsCollateral();
error inputMustBeGreaterThanZero();
error notAuthorizedToCallThisFunction();
error cannotRemoveFromCollateralListWithOpenDebtPositions();
error cannotRepayMoreThanBorrowedAmount();
error transferFailed();

contract lending {
    using SafeERC20 for IERC20;
    //////////////////////////
    //// State Variables ////
    /////////////////////////

    address public immutable i_owner;
    IERC20[] public allowedTokens;

    mapping(address user => mapping(IERC20 tokenAddress => uint256 amountDeposited)) public depositIndexByToken;
    mapping(address borrower => uint256 amount) public borrowedAmount;
    mapping(address lender => uint256 ethAmount) public lentEthAmount;
    mapping(address borrower => uint256 healthFactor) public userHealthFactor;
    mapping(IERC20 token => uint256 collateralFactor) public minimumCollateralizationRatio;

    //////////////////
    //// Events /////
    /////////////////
    event AllowedTokenSet(IERC20 indexed tokenAddress, uint256 indexed minimumCollateralizationRatio);
    event RemovedTokenSet(IERC20 indexed tokenAddress);
    event ERC20Deposit(address indexed depositer, IERC20 indexed tokensDeposited, uint256 indexed amountDeposited);
    event EthDeposit(address indexed depositer, uint256 indexed amount);
    event Borrow();
    event Withdraw();
    event Repay(address indexed user, uint256 indexed amountRepaid, uint256 indexed userHealthFactor);
    event Liquidate();

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
     */
    constructor(address _owner) {
        i_owner = _owner;
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
        IERC20[] memory newArray;
        for (uint256 i = 0; i < allowedTokens.length; i++) {
            if (allowedTokens[i] != tokenAddress) {
                newArray[i] = allowedTokens[i];
            }
        }
        allowedTokens = newArray;
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

    function withdraw(uint256 amount) external moreThanZero(amount) {}

    function borrow() external {}

    /**
     * @notice Allows users to repay the Eth they borrowed from the lending contract
     * @param amount The amount of Eth the user is repaying
     * @dev The repay amount must be greater than zero
     * @dev The user's borrowedAmount[] adjusts accordingly to the amount repaid, then the Repay event is emitted
     */
    function repay(uint256 amount) external moreThanZero(amount) {
        if (borrowedAmount[msg.sender] < amount) {
            revert cannotRepayMoreThanBorrowedAmount();
        }
        (bool success,) = address(this).call{value: amount}("");
        if (!success) {
            revert transferFailed();
        }
        borrowedAmount[msg.sender] -= amount;
        emit Repay(msg.sender, amount, getUserHealthFactor(msg.sender));
    }

    function liquidate() external {}

    function getUserHealthFactor(address user) public view returns (uint256 healthFactor) {}
}
