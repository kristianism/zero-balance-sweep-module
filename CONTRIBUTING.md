# Contributing

Contributions should preserve the module's narrow authority: move the configured Safe asset between the Safe and its configured Aave V3 reserve without granting a relayer arbitrary payment authority.

## Security reports

Do not open a public issue for a suspected vulnerability.

Use GitHub private vulnerability reporting when it is available for this repository. If it is unavailable, contact the maintainer privately and wait for an agreed disclosure date before publishing details.

Include:

- affected commit and contract;
- impact and required attacker capabilities;
- exact reproduction steps;
- a minimal Foundry proof of concept;
- proposed remediation, if known;
- whether the issue affects deployed contracts or only unreleased code.

Do not test against third-party production Safes or move funds you do not own.

## Development setup

Requirements:

- Git with submodule support;
- Foundry;
- an Ethereum RPC URL for fork tests.

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

Never commit `.env` files, RPC credentials, private keys, keystores, or deployment secrets.

## Proposing a change

For material behavior changes, open an issue first. Describe:

- the problem and intended behavior;
- affected trust boundaries;
- compatibility impact for deployed modules, scripts, and interfaces;
- new or changed invariants;
- testing strategy.

Small documentation, test, and clearly scoped bug fixes can go directly to a pull request.

## Branches and commits

Create a focused branch from the latest `main`:

```bash
git switch main
git pull --ff-only
git switch -c fix/short-description
```

Keep commits reviewable. Use imperative commit subjects such as:

```text
fix: clear stale allowance before Aave supply
test: add real Safe proxy fork coverage
docs: document relayer activation sequence
```

Do not combine unrelated formatting, dependency, and contract behavior changes unless the formatting change is required by `forge fmt`.

## Solidity requirements

- Keep Solidity pinned to the version in `foundry.toml` unless the pull request documents and tests a compiler upgrade.
- Use custom errors rather than revert strings in production contracts.
- Preserve `Enum.Operation.Call` for Safe-routed token and Aave interactions.
- Treat every external call as a trust boundary.
- Keep Safe-only and relayer authority explicit in the interface and NatSpec.
- Avoid unbounded approvals. Clear incompatible pre-existing allowances and approve only the amount required for the current supply.
- Maintain checks-effects-interactions ordering where practical and use `nonReentrant` on state-changing functions that make external calls.
- Do not add upgradeability without a separate design and security review.
- Update events when accounting-relevant behavior changes.

## Testing requirements

Every behavior change needs a regression test that fails before the fix and passes after it.

Run:

```bash
forge fmt --check
forge build --sizes
forge test -vvv
```

Changes affecting Safe or Aave integration must also pass a pinned Ethereum fork:

```bash
export MAINNET_RPC_URL="https://your-ethereum-rpc.example"
forge test --fork-url "$MAINNET_RPC_URL" --fork-block-number 25826804 \
  --match-contract '^(SafeCorporateSweepModuleTest|SafeCorporateSweepModuleSafeIntegrationTest)$' -vvv
```

When applicable, add:

- unit tests for access control and revert paths;
- fuzz tests for amount boundaries and conservation properties;
- stateful invariant tests;
- fork tests against the exact Safe and Aave contracts used in production;
- tests for non-standard ERC-20 allowance or return-value behavior.

A passing mock test does not replace a live fork integration test.

## Pull request checklist

Before requesting review:

- [ ] The change has one clear purpose.
- [ ] Security and compatibility consequences are described.
- [ ] New behavior has regression tests.
- [ ] Unit, fuzz, invariant, and relevant fork tests pass.
- [ ] `forge fmt --check` and `git diff --check` pass.
- [ ] Contract size remains below the EIP-170 limit.
- [ ] README, interface NatSpec, deployment instructions, and events are updated where needed.
- [ ] No secrets, generated build artifacts, or local environment files are included.
- [ ] New dependencies are pinned and justified.

Include the exact test commands and results in the pull request description. If a test could not run, state why rather than marking it as passed.

## Review expectations

Reviewers should check:

- caller authority and Safe module interactions;
- asset flow and approval lifecycle;
- Aave reserve and aToken wiring;
- relayer caps, cooldowns, and intent lifecycle;
- event accuracy for accounting and monitoring;
- rollback or replacement procedure for deployed modules.

Address review comments with follow-up commits or a clear technical explanation. Avoid force-pushing after review starts unless the reviewer agrees.

## Documentation and style

Use plain technical language. Distinguish implemented behavior from proposed architecture. Document external assumptions and non-atomic workflows directly.

Format Solidity with `forge fmt`. Keep Markdown headings descriptive and commands executable as written.

## License

By contributing, you agree that your contribution is licensed under the repository's MIT License.
