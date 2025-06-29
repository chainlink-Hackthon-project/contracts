# CrossChain Lending Platform

## What is this project?

This project is a cross-chain lending platform that lets users lock their Ethereum (ETH) as collateral on the Ethereum network and borrow USDT on the Avalanche network. It makes borrowing across chains easy and secure without manually moving assets.

## How does it work?

- You lock your ETH on Ethereum using our smart contract.
- The system confirms your locked ETH through a **double confirmation** process to ensure security.
- After confirmation, you can borrow USDT from a liquidity pool on Avalanche.
- Interest rates and loan limits change dynamically based on market conditions like asset supply and price volatility.
- When you repay the borrowed USDT with interest, your ETH collateral is released back to you.
- If the collateral value drops too much, automated liquidation protects the lenders.

## Key Features

- **Cross-chain locking and messaging** using Chainlink’s CCIP for secure communication between Ethereum and Avalanche.
- **Double confirmation mechanism** for verifying collateral locks.
- **Liquidity pool model** allowing multiple lenders to provide funds fairly.
- **Dynamic interest rates and LTV ratios** based on real-time oracle data.
- **Automated liquidations** to reduce risk for lenders.

## Why use this?

- Easily borrow funds on Avalanche while keeping your ETH on Ethereum.
- No need to manually bridge assets or move funds.
- Fair and adaptive interest rates save money for borrowers.
- Safe and trustless cross-chain lending.
