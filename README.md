## Lending: LEVEL 5

**This is a lending and borrowing contract where users can lend ETH to the contract and claim in-kind yield from borrowers who deposit approved ERC20 tokens as collateral. The contract has basic liquidation functionality, can freeze and unfreeze borrowing markets, and integrates a Chainlink ETH/USD price feed for updated LTV ratios on open debt positions. All ERC20 collateral tokens are treated as having a fixed price of $1/token for simplicity**

## Contract Descriptions:

- **ERC20_token.sol**: An ERC20 token that serves as an initial accepted collateral for the `Lending.sol` contract to lend deposited ETH against

- **Lending.sol**: A lending and borrowing contract with basic liquidation mechanics, lending yield, and an integrated Chainlink ETH/USD price feed to provide real-time LTV's for users. This contract uses approved ERC20 tokens as collateral to borrow deposited ETH against with a market-specific minimum collateralization ratios governing the borrowing limits. ETH lenders are compensated through in-kind yield derived from borrowing activity, their share of the total amount of ETH lent to the contract, and the length of time that their ETH has been deposited into the contract for.

  **priceConverter.sol**: Uses the provided Chainlink ETH/USD price feed to convert any amount of ETH to its current dollar value

- **HelperConfig.s.sol**: Helper contract to programmatically configure contract deployments based on the chainId where the contract is being deployed to

- **Deploy_Lending.s.sol**: Modular deployment contract that deploys `Lending.sol` and `ERC20_token.sol` with constructor parameters that are programmatically determinded in `HelperConfig.s.sol`, allowing for local testing as well as production deployments.

  **Lending_Test.t.sol**: Unit tests on `Lending.sol` to verify the functionality of the code and if the logic causes the intended outcomes

  **MockV3Aggregator.t.sol**: Mock/fake Chainlink ETH/USD pricefeed, used for testing the `Lending.sol` contract functions in the `Lending_Test.t.sol` file
