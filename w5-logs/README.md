# Enygma DvP: what happens to your tokens if the other side never delivers?

An independent check of Rayls' public Enygma repository ([raylsnetwork/Enygma](https://github.com/raylsnetwork/Enygma), commit `3dd403e`, folder `enygma_dvp`) on a local Hardhat chain. No real money, no wallet, no live network.

## What was run

1. Rayls' own DvP, timeout, front-running, relayer and cross-circuit tests, with the repository unmodified (`15-upstream-tests.log`).
2. Two new test files, both logged in `18-w5-timeout-refund.log`:
   - `90_w5_timeout_refund_test.go`, the direct route: Alice opens a swap, Bob never delivers, a stranger account calls `claimSwapTimeout` after the deadline, Alice withdraws the refund note and the recipient's ERC20 balance is checked. A second spend of the refund note and a spend of the original note are both tried.
   - `91_w5_relayer_cancel_test.go`, the SwapRelayer route: Alice files her leg with `SwapRelayer`, Bob never delivers, a stranger calls `cancelSwap` before and after the expiry, the test checks that her original note comes back unspent with no new note inserted, withdraws it to a fresh address, checks the balances and tries a second spend. It also prints the gas of both routes from the same run.
3. Source excerpts the results rest on (`19-source-evidence.txt`) and the list of changed files (`20-what-changed.txt`).

`00-summary.txt` has every step with PASS or FAIL. The script that produced everything is `w5-final.sh` at the root of this branch.

## Reproduce

Open a Codespace on this fork, switch to branch `w5-logs` and run `bash w5-final.sh`. The same script also runs on a GitHub Actions runner (`.github/workflows/w5-check.yml`).

## Scope

- Local chain and a local proof server only. The proving keys are generated with the repository's own keygen because `scripts/keys/` is not in the repository, and circuits these tests do not use get a copy of the Payment verification key so `init` can run (`10-placeholder-vks.log`).
