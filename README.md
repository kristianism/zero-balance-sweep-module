# Zero-Balance Corporate Sweep Module

A Safe module for moving idle ERC-20 operating balances into Aave V3 and returning liquidity to the Safe when needed.

The Safe owns the underlying assets and aTokens throughout normal operation. The module routes calls through Safe's `execTransactionFromModule` and never uses `delegatecall`.

## Status

This repository is a reference implementation. It has unit, fuzz, invariant, Ethereum mainnet-fork, and official Safe v1.4.1 proxy integration tests. It has received an internal security review, but no independent professional audit.

Do not deploy it with production treasury funds without reviewing the exact Safe configuration, token, Aave market, relayer controls, and deployment transactions.

## Implemented behavior

- Sweeps the Safe's asset balance above `operatingThreshold` into Aave V3.
- Supplies aTokens directly to the Safe.
- Withdraws an exact shortfall before a planned payment.
- Requires a Safe-set, amount-bound, expiring intent before a relayer can execute a JIT withdrawal.
- Supports per-call sweep and JIT caps plus a shared relayer cooldown.
- Provides Safe-only manual supply, withdrawal, intent cancellation, configuration, and asset recovery functions.
- Validates that the configured aToken matches both the asset and Aave Pool.
- Clears a pre-existing Pool allowance before approval when required by strict-approval tokens.

## Trust model

| Actor or dependency | Authority and assumptions |
| --- | --- |
| Safe owners | Control module configuration, manual operations, relayer authorization, and module enablement. |
| Enabled Safe modules | Safe modules can execute arbitrary Safe transactions. Another enabled module can make the Safe call this module's Safe-only functions. Review the Safe's full module list. |
| Relayers | Can sweep balances above the threshold. A relayer can withdraw only after the Safe creates an exact, unexpired JIT intent. Relayers cannot execute arbitrary Safe payments through this module. |
| Aave V3 Pool | Receives supplied assets and controls withdrawals. Pool, reserve status, caps, liquidity, governance, and smart-contract risk remain external dependencies. |
| Asset token | Must be the exact supported Aave reserve asset. Non-standard transfer behavior may be incompatible. |

A zero cap means unlimited. Guardrails default to zero, so authorizing a relayer before configuring finite limits creates an unrestricted automation window.

## JIT funding semantics

There are two execution patterns:

1. **Safe-authorized batch:** The Safe calls `jitWithdraw` and then executes the outgoing payment in one owner-approved batch. No relayer intent is required because the Safe is the caller.
2. **Relayer funding:** The Safe first creates a one-time intent with `setJitIntent`. An authorized relayer later calls `jitWithdraw` for that exact amount before the deadline. The resulting payment is a separate Safe transaction.

The relayer path tops up the Safe. It does not intercept, approve, or execute the outgoing payment.

## Contract interface

### Safe-only controls

- `setThreshold(uint256 amount)`
- `setRelayer(address relayer, bool authorized)`
- `setJitIntent(uint256 amount, uint256 deadline)`
- `cancelJitIntent()`
- `setRelayerGuardrails(uint256 maxJit, uint256 maxSweep, uint256 cooldown)`
- `manualSupply(uint256 amount)`
- `manualWithdraw(uint256 amount)`
- `recoverToken(address token, uint256 amount)`
- `recoverNative()`

`manualSupply` is an explicit override and can reduce the idle balance below `operatingThreshold`.

### Automation

- `executeSweep()`
- `jitWithdraw(uint256 transactionAmount)`

### Views

- `previewSweepAmount()`
- `previewShortfall(uint256 transactionAmount)`
- Current wiring, thresholds, relayer guardrails, action timestamps, and JIT intent state

## Repository layout

```text
src/
  SafeCorporateSweepModule.sol
  interfaces/
test/
  SafeCorporateSweepModule.unit.t.sol
  SafeCorporateSweepModule.invariant.t.sol
  SafeCorporateSweepModule.t.sol
  SafeCorporateSweepModule.safe.t.sol
  mocks/
script/
  Deploy.s.sol
```

## Requirements

- Foundry
- Solidity 0.8.24, installed automatically by Foundry
- An Ethereum RPC URL for fork tests

Dependencies are pinned as Git submodules and in `foundry.lock`.

## Setup

```bash
git clone --recurse-submodules https://github.com/kristianism/zero-balance-sweep-module.git
cd zero-balance-sweep-module
forge build
forge test
```

For an existing clone:

```bash
git submodule update --init
```

## Testing

Run deterministic unit, fuzz, and invariant tests:

```bash
forge test -vvv
```

Run Ethereum mainnet-fork tests against Aave V3 and the official Safe v1.4.1 deployment:

```bash
export MAINNET_RPC_URL="https://your-ethereum-rpc.example"
forge test --fork-url "$MAINNET_RPC_URL" \
  --match-contract '^(SafeCorporateSweepModuleTest|SafeCorporateSweepModuleSafeIntegrationTest)$' -vvv
```

For reproducible fork results, add a fixed block:

```bash
forge test --fork-url "$MAINNET_RPC_URL" --fork-block-number 25826804 \
  --match-contract '^(SafeCorporateSweepModuleTest|SafeCorporateSweepModuleSafeIntegrationTest)$' -vvv
```

Other useful checks:

```bash
forge fmt --check
forge build --sizes
slither . --exclude-dependencies
```

The invariant harness checks automation-path properties in a zero-interest mock market:

- the module does not retain underlying or aTokens during normal operations;
- the Safe's mock-market principal is conserved;
- automated sweeps and JIT withdrawals do not leave the Safe below its configured threshold.

These properties do not cover manual overrides, external Safe transactions, Aave interest accrual, or malicious assets.

## Ethereum mainnet wiring

| Component | Address |
| --- | --- |
| USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| Aave V3 aUSDC | `0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c` |
| Aave V3 Pool | `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2` |
| Safe v1.4.1 singleton used in tests | `0x41675C099F32341bf84BFc5382aF534df5C7461a` |
| Safe v1.4.1 Proxy Factory used in tests | `0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67` |

Verify addresses against the official [Aave V3](https://github.com/aave-dao/aave-v3-origin) and [Safe deployments](https://github.com/safe-global/safe-deployments) repositories before each deployment. Do not copy mainnet addresses to another network.

## Deployment

Copy `.env.example`, then set:

```text
SAFE_ADDRESS=
ASSET=
ATOKEN=
AAVE_POOL=
OPERATING_THRESHOLD=
RELAYER=0x0000000000000000000000000000000000000000
```

Deploy:

```bash
source .env
forge script script/Deploy.s.sol:Deploy --rpc-url "$MAINNET_RPC_URL" --broadcast
```

Supply a Foundry keystore, hardware-wallet, or other supported signer through the CLI. Do not put a deployer private key in the repository or shell history.

Recommended activation sequence:

1. Deploy with `RELAYER` set to the zero address.
2. Verify the immutable Safe, asset, aToken, Pool, and threshold values.
3. Have the Safe enable the module in an owner-approved transaction.
4. Have the Safe set finite relayer guardrails.
5. Have the Safe authorize the relayer.
6. Test a small sweep and withdrawal before raising operating limits.

The module is immutable and non-upgradeable. Replacing it requires deploying a new instance, enabling the new module, revoking relayers and pending intent on the old module, and disabling the old module through the Safe.

## Accounting notes

- Aave aToken balances rebase as interest accrues. Reconcile balance changes separately from principal movements.
- `ManualWithdrawn` reports the actual underlying returned, including full-balance withdrawals using `type(uint256).max`.
- Assets sent directly to the module do not enter Aave. Safe-only recovery functions return them to the Safe.
- Events are operational evidence, but accounting records should also reconcile token transfers and current balances.

## Security

Report suspected vulnerabilities privately before public disclosure. See [CONTRIBUTING.md](CONTRIBUTING.md) for the reporting and testing requirements.

## Contributing

Contributions are welcome when they include a clear threat model, regression tests, and updated documentation. Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

## License

MIT. See [LICENSE](LICENSE).
