# Zero-Balance Corporate Sweep Module

![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)
![Framework: Foundry](https://img.shields.io/badge/Framework-Foundry-orange.svg)
![Integration: Aave V3](https://img.shields.io/badge/Integration-Aave_V3-purple.svg)

An open-source smart account plugin designed to bring institutional treasury management to Web3. 

This module automates the management of operational expenditures (OpEx) by instantly sweeping idle stablecoins into battle-tested yield protocols (Aave V3), while utilizing Just-In-Time (JIT) pre-transaction hooks to guarantee liquidity for outgoing corporate payments. 

## The Problem

Traditional Web3 corporate wallets are highly inefficient. Stablecoins sit idle, earning no yield, because moving capital in and out of DeFi protocols requires manual multi-sig approvals. This creates friction, slows down daily operations, and severely complicates month-end reconciliation for accounting teams trying to map on-chain transactions to a standard Chart of Accounts.

## The Solution

The **Zero-Balance Sweep Module** operates as a non-custodial gatekeeper for your operating balance, acting much like a traditional overnight corporate sweep account. 

### Core Features

* **Automated Yield Generation:** Define a minimum operating threshold. Any stablecoin balance exceeding this threshold is automatically swept into Aave V3.
* **Just-In-Time (JIT) Funding:** When an authorized user initiates a supplier payment or payroll transaction, the module intercepts the request. If the wallet lacks the immediate USDC balance, the module programmatically withdraws the exact shortfall from Aave V3 in the same block before executing the transaction.
* **Seamless Reconciliation:** By using Aave V3's rebasing `aTokens` (e.g., aUSDC), corporate finance teams can easily reconcile interest income at month-end without calculating complex Liquidity Pool (LP) token valuations. The on-chain activity maps cleanly directly into standard double-entry bookkeeping systems.
* **Manual Treasury Controls:** Includes strict access-controlled functions for financial officers to execute manual batch supplies or withdrawals.

## Architecture & Logic

Built to be compatible with standard Modular Smart Account architectures (such as Safe Modules / ERC-6900 plugins), the module guarantees that core wallet security remains intact while adding programmable financial workflows.

* `setThreshold(uint256 _amount)`: Configures the target daily operating liquidity.
* `executeSweep()`: Permissionless trigger (callable via Gelato or manual execution) to push excess capital to the yield target.
* `preTransactionHook(uint256 _txAmount)`: The JIT withdrawal logic that prevents failed OpEx transactions.
* `manualSupply(uint256 _amount)` & `manualWithdraw(uint256 _amount)`: Admin-only overrides for proactive cash flow management.

## Prerequisites

This project uses [Foundry](https://book.getfoundry.sh/) as its development and testing framework.

```bash
curl -L [https://foundry.paradigm.xyz](https://foundry.paradigm.xyz) | bash
foundryup
