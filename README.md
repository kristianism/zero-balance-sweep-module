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
* `executeSweep()`: Authorized relayer/Safe trigger to push excess capital to the yield target.
* `setJitIntent(uint256 _amount, uint256 _deadline)`: Safe-signed one-time intent required before relayer JIT execution.
* `jitWithdraw(uint256 _txAmount)`: JIT withdrawal logic that enforces the pending intent and funding post-condition.
* `setRelayerGuardrails(...)`: Safe-controlled per-call caps and cooldown for relayer automation.
* `manualSupply(uint256 _amount)` & `manualWithdraw(uint256 _amount)`: Admin-only overrides for proactive cash flow management.

## Prerequisites

This project uses [Foundry](https://book.getfoundry.sh/) as its development and testing framework.

```
curl -L [https://foundry.paradigm.xyz](https://foundry.paradigm.xyz) | bash
foundryup
```

## Getting Started

Clone the repository:
```
git clone https://github.com/kristianism/zero-balance-sweep-module.git
cd zero-balance-sweep-module
```

## Install dependencies:
```
forge install foundry-rs/forge-std --no-commit
forge install OpenZeppelin/openzeppelin-contracts --no-commit
```

### Set up your environment variables.

Create a .env file based on .env.example and add your RPC URLs (we highly recommend testing on an L2 fork like Base or Sonic for realistic gas economics):
```
MAINNET_RPC_URL=your_rpc_url_here
```

### Run the test suite against a mainnet fork:
```
source .env
forge test --fork-url $MAINNET_RPC_URL -vvv
```

## Project Layout

```
src/
  SafeCorporateSweepModule.sol         # Main module implementation
  interfaces/
    ISafe.sol                          # Minimal Gnosis Safe surface
    IAaveV3Pool.sol                    # Aave V3 Pool + aToken interfaces
    ISafeCorporateSweepModule.sol      # Public module interface (events, errors, externals)
test/
  SafeCorporateSweepModule.t.sol       # Mainnet-fork tests against real Aave V3 liquidity
  mocks/
    MockSafe.sol                       # Minimal Safe stand-in for unit testing
script/
  Deploy.s.sol                         # Foundry deploy script
```

## Mainnet Wiring (Ethereum)

| Component | Address |
| --- | --- |
| USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| aUSDC (Aave V3) | `0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c` |
| Aave V3 Pool | `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2` |

After deploying the module, the Safe owners must sign a transaction calling
`enableModule(moduleAddress)` on the Safe before any sweep / JIT entrypoint
can route funds.

## Security & Auditing
Disclaimer:
This module handles direct access to corporate treasury funds. While it utilizes standardized OpenZeppelin libraries and interfaces with battle-tested protocols, this code has not yet been audited.
Do not deploy to mainnet with production funds without a comprehensive security review.

## Contributing
We welcome contributions from Web3 developers and traditional finance professionals alike. Please open an issue to discuss proposed changes before submitting a Pull Request.

## License
Distributed under the MIT License. See LICENSE for more information.
