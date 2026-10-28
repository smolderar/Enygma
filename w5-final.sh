#!/usr/bin/env bash
# Week 5 (final): follow a timed-out Enygma DvP swap all the way to the refund,
# by both exits: the direct timeout and the SwapRelayer cancel.
# Local Hardhat chain only: no real money, no wallet, no live network.
#
# Usage (Codespace terminal, repo root):   bash w5-final.sh
# Logs stay on this machine and are zipped to w5-logs.zip.
# Nothing is pushed to GitHub unless you run it as:   W5_PUBLISH=1 bash w5-final.sh
# Quick compile check of the two new test files only:  bash w5-final.sh --check
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
DVP="$ROOT/enygma_dvp"
LOG="$ROOT/w5-logs"
PUBLISH="${W5_PUBLISH:-0}"
NEWTEST="$DVP/test/90_w5_timeout_refund_test.go"
NEWTEST2="$DVP/test/91_w5_relayer_cancel_test.go"
rm -rf "$LOG" "$ROOT/w5-logs.zip"; mkdir -p "$LOG" "$HOME/bin"
export PATH="$HOME/bin:$PATH" GOTOOLCHAIN=auto
SUM="$LOG/00-summary.txt"; : > "$SUM"
say()  { echo; echo "=== $(date -u '+%Y-%m-%d %H:%M:%S') UTC  $*"; }
note() { echo "$*" | tee -a "$SUM"; }
step() { local name="$1"; shift; say "$name"; local t0=$(date +%s)
         if "$@" > "$LOG/$name.log" 2>&1; then note "PASS  $name ($(( $(date +%s)-t0 )) s)"; return 0
         else note "FAIL  $name (see w5-logs/$name.log)"; tail -n 25 "$LOG/$name.log"; return 1; fi; }
wait_port() { for i in $(seq 1 "$2"); do (echo > /dev/tcp/127.0.0.1/$1) 2>/dev/null && return 0; sleep 2; done; return 1; }

# ---------- the two new test files (nothing upstream is edited) ----------
write_tests() {
cat > "$NEWTEST" <<'W5TEST'
package tests

// 90_w5_timeout_refund_test.go
//
// Added for an independent check (not part of upstream). Local Hardhat chain only.
//
// Question: in a private DvP swap, what happens to Alice's tokens if Bob never
// delivers?
//
// This file follows the tokens all the way back out of the vault, with a
// stranger account triggering the timeout, and then checks that neither the
// refund note nor the original note can be spent again.
//
//	RefundAfterTimeout  Alice opens a swap. Bob never delivers. A stranger
//	                    account (not Alice, not Bob) calls claimSwapTimeout
//	                    after the deadline. Alice then withdraws the refund
//	                    note (revertCommitA) and the recipient's ERC20 balance
//	                    is checked. After that: the original note and a second
//	                    spend of the refund note must both be refused.
//
// Every transaction is also printed as an outside observer would see it:
// sender, contract, events ("[observer]" lines).
//
// Prerequisites: the same as 04_v2_dvp_deadline_test.go (hardhat node, deploy,
// init, gnark server on :8081).
//
//	cd test && CC=clang go test -run TestW5_ -v -count=1 -timeout 900s

import (
	"context"
	"encoding/json"
	"fmt"
	"math/big"
	"strings"
	"testing"
	"time"

	"github.com/raylsnetwork/enygma_dvp/src/core"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
)

// w5DeadlineSeconds is just over EnygmaDvp.MIN_SWAP_DURATION (15 minutes).
const w5DeadlineSeconds = int64(16 * 60)

// w5NftId returns an ERC721 tokenId outside the ranges the upstream tests use
// (25, 42, 100-114, 117, and 1000..~1e9 in test 19).
func w5NftId() int64 {
	return 1_100_000_000 + time.Now().UnixNano()%100_000_000
}

// w5say prints one readable line of the run, without the file:line prefix,
// so the sequence can be followed in the terminal.
func w5say(format string, a ...interface{}) {
	fmt.Printf("    [W5] "+format+"\n", a...)
}

// w5short prints a long field element as its first 6 and last 4 digits.
func w5short(b *big.Int) string {
	s := b.String()
	if len(s) <= 12 {
		return s
	}
	return s[:6] + "..." + s[len(s)-4:]
}

// w5commas formats a gas figure as 1,006,618.
func w5commas(n uint64) string {
	s := fmt.Sprintf("%d", n)
	out := ""
	for i, c := range s {
		if i > 0 && (len(s)-i)%3 == 0 {
			out += ","
		}
		out += string(c)
	}
	return out
}

type w5Env struct {
	tc       *dvpTestContext
	pw       *pwEnv
	dvpAddr  common.Address
	dvpABI   abi.ABI
	vaultABI abi.ABI
	erc20ABI abi.ABI
	stranger *bind.TransactOpts
	names    map[common.Address]string
	extra    []abi.ABI // more contracts whose events observe() should name (e.g. SwapRelayer)
}

// Gas used in this run by the direct route, so the relayer test can compare.
var w5LegGas, w5TimeoutGas uint64

func newW5Env(t *testing.T) *w5Env {
	t.Helper()
	tc := newDvpTestContext(t)
	receipts := loadOnchainReceipts(t)
	dvpAddr := common.HexToAddress(receipts["EnygmaDvp"].ContractAddress)
	vaultABI := loadOnchainABI(t, "core/contracts/vaults/Erc20CoinVault.sol/Erc20CoinVault.json")
	e := &w5Env{
		tc:       tc,
		dvpAddr:  dvpAddr,
		dvpABI:   loadOnchainABI(t, "core/contracts/EnygmaDvp.sol/EnygmaDvp.json"),
		vaultABI: vaultABI,
		erc20ABI: loadOnchainABI(t, "erc20/contracts/RaylsERC20.sol/RaylsERC20.json"),
		// pwEnv (from 26_v2_erc20_partial_withdraw_test.go) pointed at the main
		// deployment's ERC20 vault, so its Payment-circuit withdrawal helpers can
		// be reused here.
		pw: &pwEnv{
			ctx:       tc.ctx,
			client:    tc.client,
			vault:     tc.erc20Vault,
			erc20:     tc.erc20Token,
			vaultABI:  vaultABI,
			vaultAddr: tc.erc20VaultAddr,
			owner:     tc.auth,
			tokenId:   big.NewInt(dvpErc20TokenId),
		},
		stranger: attackerAuth(t, tc), // fresh funded key from 13_v2_dvp_frontrun_test.go
	}
	receiptsERC20 := common.HexToAddress(receipts["ERC20"].ContractAddress)
	e.names = map[common.Address]string{
		tc.auth.From:       "account[0] (deposits and submits Alice's leg)",
		e.stranger.From:    "stranger (fresh key: not Alice, not Bob)",
		dvpAddr:            "EnygmaDvp",
		tc.erc20VaultAddr:  "Erc20CoinVault",
		tc.erc721VaultAddr: "Erc721CoinVault",
		receiptsERC20:      "ERC20 token",
	}
	w5say("accounts: account[0] %s | stranger %s", tc.auth.From.Hex(), e.stranger.From.Hex())
	return e
}

func (e *w5Env) who(a common.Address) string {
	if n, ok := e.names[a]; ok {
		return n
	}
	return a.Hex()
}

// try simulates the call first to read a revert reason without mining
// anything. If the simulation passes, it sends and mines the transaction.
// It returns the custom error name (or raw error) on revert, "" on success.
func (e *w5Env) try(t *testing.T, from *bind.TransactOpts, to common.Address, a abi.ABI, bc *bind.BoundContract, method string, args ...interface{}) (string, *types.Transaction, *types.Receipt) {
	t.Helper()
	data, err := a.Pack(method, args...)
	if err != nil {
		t.Fatalf("pack %s: %v", method, err)
	}
	call := ethereum.CallMsg{From: from.From, To: &to, Gas: from.GasLimit, Data: data}
	if _, err := e.tc.client.CallContract(context.Background(), call, nil); err != nil {
		if m := hardhatRevertName.FindStringSubmatch(err.Error()); m != nil {
			return m[1] + m[2], nil, nil
		}
		return err.Error(), nil, nil
	}
	tx, err := bc.RawTransact(from, data)
	if err != nil {
		t.Fatalf("send %s: %v", method, err)
	}
	r, err := bind.WaitMined(context.Background(), e.tc.client, tx)
	if err != nil || r.Status != types.ReceiptStatusSuccessful {
		t.Fatalf("%s mined but failed (err=%v)", method, err)
	}
	return "", tx, r
}

// observe prints a mined transaction the way anyone reading the chain sees it.
func (e *w5Env) observe(t *testing.T, label string, from common.Address, tx *types.Transaction, r *types.Receipt) {
	t.Helper()
	w5say("%s", label)
	w5say("  [observer] tx %s... | block %d | from %s | to %s | gas %s",
		tx.Hash().Hex()[:12], r.BlockNumber.Uint64(), e.who(from), e.who(*tx.To()), w5commas(r.GasUsed))
	for _, lg := range r.Logs {
		if len(lg.Topics) == 0 {
			continue
		}
		var ev *abi.Event
		for _, a := range append([]abi.ABI{e.dvpABI, e.vaultABI, e.erc20ABI}, e.extra...) {
			if found, err := a.EventByID(lg.Topics[0]); err == nil {
				ev = found
				break
			}
		}
		if ev == nil {
			w5say("  [observer]    %s: unknown event %s", e.who(lg.Address), lg.Topics[0].Hex()[:12])
			continue
		}
		parts := []string{}
		idx := 1
		for _, in := range ev.Inputs {
			if !in.Indexed || idx >= len(lg.Topics) {
				continue
			}
			v := lg.Topics[idx]
			idx++
			if in.Type.T == abi.AddressTy {
				parts = append(parts, fmt.Sprintf("%s=%s", in.Name, e.who(common.BytesToAddress(v.Bytes()))))
			} else {
				parts = append(parts, fmt.Sprintf("%s=%s", in.Name, w5short(v.Big())))
			}
		}
		nonIndexed := ev.Inputs.NonIndexed()
		if len(nonIndexed) > 0 {
			if vals, err := nonIndexed.Unpack(lg.Data); err == nil {
				for i, in := range nonIndexed {
					var s string
					if b, ok := vals[i].(*big.Int); ok {
						s = w5short(b)
					} else if raw, ok := vals[i].([]byte); ok {
						s = fmt.Sprintf("(%d bytes)", len(raw))
					} else {
						s = fmt.Sprintf("%v", vals[i])
						if len(s) > 60 {
							s = fmt.Sprintf("(%d bytes: proof and public statement)", len(lg.Data))
						}
					}
					parts = append(parts, fmt.Sprintf("%s=%s", in.Name, s))
				}
			} else {
				parts = append(parts, fmt.Sprintf("data=%d bytes", len(lg.Data)))
			}
		}
		w5say("  [observer]    %s.%s  %s", e.who(lg.Address), ev.Name, strings.Join(parts, "  "))
	}
}

// noteState reads whether a nullifier is locked (pending swap) or spent.
func (e *w5Env) noteState(t *testing.T, tree, nf *big.Int) (locked, spent bool) {
	t.Helper()
	var out []interface{}
	if err := e.tc.erc20Vault.Call(nil, &out, "isLocked", tree, nf); err != nil {
		t.Fatalf("isLocked: %v", err)
	}
	locked = out[0].(bool)
	out = nil
	if err := e.tc.erc20Vault.Call(nil, &out, "nullifiers", tree, nf); err != nil {
		t.Fatalf("nullifiers: %v", err)
	}
	return locked, out[0].(bool)
}

// withdrawAll proves a full withdrawal of note n to recipient (Payment circuit,
// WITHDRAW_MESSAGE, change 0) and tries withdrawV2 with it.
func (e *w5Env) withdrawAll(t *testing.T, label string, n pwNote, recipient common.Address) (string, *types.Transaction, *types.Receipt) {
	t.Helper()
	s, err := e.pw.proveWithdraw(t, n, n.value, big.NewInt(0), recipient)
	if err != nil {
		t.Fatalf("%s: gnark /proof/payment refused the withdrawal witness: %v", label, err)
	}
	return e.try(t, e.tc.auth, e.tc.erc20VaultAddr, e.vaultABI, e.tc.erc20Vault,
		"withdrawV2", []*big.Int{n.value, e.pw.tokenId}, recipient, s.receipt)
}

// w5InitiatorProof builds Alice's DvP Initiator proof through the gnark
// server's /proof/dvpInitiator endpoint and keeps every witness value,
// including the revert salt, so the test can spend the refund note later.
func w5InitiatorProof(
	c *core.GnarkClient,
	aliceKey core.KeyPair,
	aliceSaltIn, valueIn, tokenIdIn, bobSpendPk *big.Int,
	bobViewEncapKey []byte,
	valueBob, tokenIdBob, stTreeNumber *big.Int,
	merkleProof *core.MerkleProof,
	merkleDepth int,
	counterVault *big.Int,
) (*core.DvPInitiatorResult, *big.Int, error) {
	ss, cipherText, err := core.Encapsulate(bobViewEncapKey)
	if err != nil {
		return nil, nil, fmt.Errorf("Encapsulate: %w", err)
	}
	saltBBytes, err := core.DerivePaymentSalt(ss)
	if err != nil {
		return nil, nil, err
	}
	saltABytes, err := core.DeriveDvpSaltInit(ss)
	if err != nil {
		return nil, nil, err
	}
	encKey, err := core.DerivePaymentKey(ss)
	if err != nil {
		return nil, nil, err
	}
	saltB := core.SaltBToField(saltBBytes)
	saltA := core.SaltBToField(saltABytes)
	encTxData, err := core.EncryptPayload(encKey, tokenIdIn, valueIn)
	if err != nil {
		return nil, nil, err
	}
	revertSaltBytes, err := core.GenerateRandomValue(32)
	if err != nil {
		return nil, nil, err
	}
	revertSalt := core.SaltBToField(revertSaltBytes)

	pathIndex := merkleProof.Indices
	nf, err := core.GetNullifierWithTree(aliceKey.PrivateKey, stTreeNumber, pathIndex, merkleDepth)
	if err != nil {
		return nil, nil, err
	}
	commitB, err := core.Erc20CommitmentV2(bobSpendPk, saltB, valueIn, tokenIdIn)
	if err != nil {
		return nil, nil, err
	}
	commitA, err := core.Erc20CommitmentV2(aliceKey.PublicKey, saltA, valueBob, tokenIdBob)
	if err != nil {
		return nil, nil, err
	}
	revertCommitA, err := core.Erc20CommitmentV2(aliceKey.PublicKey, revertSalt, valueIn, tokenIdIn)
	if err != nil {
		return nil, nil, err
	}
	pathElems := make([]string, merkleDepth)
	for i := 0; i < merkleDepth; i++ {
		pathElems[i] = merkleProof.Elements[i].String()
	}
	stMessage := commitA
	payload := map[string]interface{}{
		"stMessage":       stMessage.String(),
		"stTreeNumber":    stTreeNumber.String(),
		"stMerkleRoot":    merkleProof.Root.String(),
		"stNullifier":     nf.String(),
		"stCommitB":       commitB.String(),
		"stCommitA":       commitA.String(),
		"stRevertCommitA": revertCommitA.String(),
		"stCounterVault":  counterVault.String(),
		"wtSpendKeyIn":    aliceKey.PrivateKey.String(),
		"wtValueIn":       valueIn.String(),
		"wtSaltIn":        aliceSaltIn.String(),
		"wtTokenIdIn":     tokenIdIn.String(),
		"wtPathElements":  pathElems,
		"wtPathIndex":     pathIndex.String(),
		"wtSpendPkBob":    bobSpendPk.String(),
		"wtSaltB":         saltB.String(),
		"wtValueBob":      valueBob.String(),
		"wtTokenIdBob":    tokenIdBob.String(),
		"wtSaltA":         saltA.String(),
		"wtRevertSalt":    revertSalt.String(),
	}
	body, err := c.PostProof("/proof/dvpInitiator", payload)
	if err != nil {
		return nil, nil, fmt.Errorf("dvpInitiator proof request failed: %w", err)
	}
	var resp struct {
		Proof []json.Number `json:"proof"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, nil, err
	}
	proofStrs := make([]string, len(resp.Proof))
	for i, n := range resp.Proof {
		proofStrs[i] = n.String()
	}
	statement := []*big.Int{stMessage, stTreeNumber, merkleProof.Root, nf, commitB, commitA, revertCommitA, counterVault}
	return &core.DvPInitiatorResult{
		Proof:           proofStrs,
		Statement:       statement,
		NumberOfInputs:  1,
		NumberOfOutputs: 1,
		CipherText:      cipherText,
		EncTxData:       encTxData,
		CommitB:         commitB,
		CommitA:         commitA,
		RevertCommitA:   revertCommitA,
		SaltA:           saltA,
	}, revertSalt, nil
}

func w5Receipt(t *testing.T, r *core.DvPInitiatorResult) onchainProofReceipt {
	t.Helper()
	return onchainProofReceipt{
		Proof:           proofStringsToOnchain(t, r.Proof),
		Statement:       r.Statement,
		NumberOfInputs:  big.NewInt(int64(r.NumberOfInputs)),
		NumberOfOutputs: big.NewInt(int64(r.NumberOfOutputs)),
	}
}

func w5FreshAddress(t *testing.T) common.Address {
	t.Helper()
	k, err := crypto.GenerateKey()
	if err != nil {
		t.Fatal(err)
	}
	return crypto.PubkeyToAddress(k.PublicKey)
}

func TestW5_TimeoutRefund(t *testing.T) {
	if !chainAvailable() {
		t.Skip("Hardhat node not running on localhost:8545 — skipping on-chain test")
	}
	if !serverAvailable("localhost:8081") {
		t.Skip("gnark server not running on localhost:8081 — skipping on-chain test")
	}
	zero := big.NewInt(0)

	t.Run("RefundAfterTimeout", func(t *testing.T) {
		e := newW5Env(t)
		defer e.tc.client.Close()
		tc := e.tc

		vaultStart := e.pw.balanceOf(t, tc.erc20VaultAddr)
		d := dvpSetupDeposits(t, tc, w5NftId())
		w5say("== Alice swaps %s tokens for Bob's NFT. Bob will never deliver.", d.erc20Amount)
		w5say("   Alice's note %s (deposited by a public ERC20 transfer into the vault)", w5short(d.aliceCommitment))

		res, revertSalt, err := w5InitiatorProof(tc.gnarkClient,
			core.KeyPair{PrivateKey: d.aliceSpend.PrivateKey, PublicKey: d.aliceSpend.PublicKey},
			d.aliceSaltField, d.erc20Amount, d.erc20TokenId,
			d.bobSpend.PublicKey, d.bobView.EncapsKey,
			d.nftAmount, d.nftTokenId, zero,
			d.aliceMerkleProof, tc.merkleDepth, vaultInt(tc.erc721VaultAddr))
		if err != nil {
			t.Fatalf("initiator proof: %v", err)
		}
		check, _ := core.Erc20CommitmentV2(d.aliceSpend.PublicKey, revertSalt, d.erc20Amount, d.erc20TokenId)
		if check.Cmp(res.RevertCommitA) != 0 {
			t.Fatalf("revert salt does not open revertCommitA")
		}
		w5say("   refund note Alice would get back on a timeout (revertCommitA): %s", w5short(res.RevertCommitA))
		rc := w5Receipt(t, res)
		tree, nf := rc.Statement[1], rc.Statement[3]

		// docs/flows/04_dvp_deadline.md shows deadline=now+60s.
		dl60 := new(big.Int).Add(currentBlockTimestamp(t, tc.client), big.NewInt(60))
		if why, _, _ := e.try(t, tc.auth, e.dvpAddr, e.dvpABI, tc.dvp, "submitPartialSettlement", rc, zero, zero, dl60); why == "" {
			t.Fatalf("a 60 s deadline was accepted")
		} else {
			w5say("STEP 1  deadline now+60 s, as in docs/flows/04_dvp_deadline.md -> refused: %s", why)
			if why != "SwapDeadlineTooSoon" {
				t.Errorf("60 s deadline refused with %q, expected SwapDeadlineTooSoon", why)
			}
		}

		// Alice's leg, 16 minute deadline.
		deadline := new(big.Int).Add(currentBlockTimestamp(t, tc.client), big.NewInt(w5DeadlineSeconds))
		why, tx, r := e.try(t, tc.auth, e.dvpAddr, e.dvpABI, tc.dvp, "submitPartialSettlement", rc, zero, zero, deadline)
		if why != "" {
			t.Fatalf("Alice's leg refused: %s", why)
		}
		e.observe(t, fmt.Sprintf("STEP 2  Alice opens the swap, deadline now+%d s (submitPartialSettlement)", w5DeadlineSeconds), tc.auth.From, tx, r)
		w5LegGas = r.GasUsed
		locked, spent := e.noteState(t, tree, nf)
		w5say("        her note: locked=%v spent=%v", locked, spent)
		if !locked || spent {
			t.Errorf("after Alice's leg: locked=%v spent=%v, want locked and unspent", locked, spent)
		}

		// Nobody can cancel early, not even a stranger.
		if why, _, _ := e.try(t, e.stranger, e.dvpAddr, e.dvpABI, tc.dvp, "claimSwapTimeout", res.CommitB); why == "" {
			t.Fatalf("claimSwapTimeout before the deadline was accepted")
		} else {
			w5say("STEP 3  stranger calls claimSwapTimeout before the deadline -> refused: %s", why)
		}

		// Bob never delivers.
		w5say("STEP 4  Bob never delivers. Moving the chain clock forward %d s", w5DeadlineSeconds+5)
		hardhatIncreaseTime(t, tc.client, w5DeadlineSeconds+5)

		why, tx, r = e.try(t, e.stranger, e.dvpAddr, e.dvpABI, tc.dvp, "claimSwapTimeout", res.CommitB)
		if why != "" {
			t.Fatalf("stranger's claimSwapTimeout after the deadline refused: %s", why)
		}
		e.observe(t, "STEP 5  stranger calls claimSwapTimeout after the deadline -> accepted", e.stranger.From, tx, r)
		w5TimeoutGas = r.GasUsed
		sawRevertCommit := false
		for _, lg := range r.Logs {
			if len(lg.Topics) > 2 && lg.Topics[0] == tc.commitmentSig && lg.Topics[2].Big().Cmp(res.RevertCommitA) == 0 {
				sawRevertCommit = true
			}
		}
		if !sawRevertCommit {
			t.Errorf("revertCommitA was not inserted by claimSwapTimeout")
		}
		locked, spent = e.noteState(t, tree, nf)
		w5say("        original note: locked=%v spent=%v | refund is a NEW note %s", locked, spent, w5short(res.RevertCommitA))
		if locked || !spent {
			t.Errorf("after the timeout: original note locked=%v spent=%v, want unlocked and spent", locked, spent)
		}

		// Alice spends the refund note: full withdrawal to a fresh address.
		recipient := w5FreshAddress(t)
		e.names[recipient] = "Alice's withdrawal address (fresh)"
		before := e.pw.balanceOf(t, recipient)
		vaultBefore := e.pw.balanceOf(t, tc.erc20VaultAddr)
		refund := pwNote{spend: d.aliceSpend, view: d.aliceView, salt: revertSalt, value: d.erc20Amount, commit: res.RevertCommitA}
		why, tx, r = e.withdrawAll(t, "refund note", refund, recipient)
		if why != "" {
			t.Fatalf("withdrawing the refund note was refused: %s", why)
		}
		e.observe(t, "STEP 6  Alice withdraws the refund note to a fresh address (withdrawV2)", tc.auth.From, tx, r)
		got := new(big.Int).Sub(e.pw.balanceOf(t, recipient), before)
		vaultDelta := new(big.Int).Sub(vaultBefore, e.pw.balanceOf(t, tc.erc20VaultAddr))
		w5say("        recipient balance +%s | vault balance -%s", got, vaultDelta)
		if got.Cmp(d.erc20Amount) != 0 || vaultDelta.Cmp(d.erc20Amount) != 0 {
			t.Errorf("refund: recipient got %s, vault paid %s, want %s each", got, vaultDelta, d.erc20Amount)
		}

		// The refund note cannot be spent twice.
		why, _, _ = e.withdrawAll(t, "refund note, second time", refund, w5FreshAddress(t))
		w5say("STEP 7  withdraw the refund note a second time -> %s", why)
		if why != "InvalidNullifier" {
			t.Errorf("second withdrawal of the refund note: got %q, want InvalidNullifier", why)
		}

		// The original note cannot be spent either (04's comment says it can).
		orig := pwNote{spend: d.aliceSpend, view: d.aliceView, salt: d.aliceSaltField, value: d.erc20Amount, commit: d.aliceCommitment}
		why, _, _ = e.withdrawAll(t, "original note", orig, w5FreshAddress(t))
		w5say("        withdraw the ORIGINAL note -> %s", why)
		if why != "InvalidNullifier" {
			t.Errorf("original note after timeout: got %q, want InvalidNullifier", why)
		}

		vaultEnd := e.pw.balanceOf(t, tc.erc20VaultAddr)
		w5say("        ERC20 vault: %s before this run's deposit, %s now", vaultStart, vaultEnd)
		w5say("W5-RESULT: stranger timed out the swap, refund note withdrawn, recipient +%s, refund and original both refused afterwards", got)
	})
}
W5TEST
cat > "$NEWTEST2" <<'W5TEST2'
package tests

// 91_w5_relayer_cancel_test.go
//
// Added for an independent check (not part of upstream). Local Hardhat chain only.
//
// The second exit. 90_w5_timeout_refund_test.go follows the direct route:
// EnygmaDvp.claimSwapTimeout spends Alice's note and inserts a new refund note.
// This file follows the relayer route for the same situation:
//
//	RelayerCancel  Alice files her payment leg with SwapRelayer instead.
//	               Bob never delivers. A stranger account (not Alice, not Bob)
//	               calls cancelSwap, first before the expiry, then after it.
//	               The test checks that her ORIGINAL note comes back unspent,
//	               that no new note is inserted, then withdraws that original
//	               note to a fresh address and checks the balances, and finally
//	               tries to spend it a second time.
//
// It also prints the gas of each route's cancel, measured in the same run.
//
// deploy/init do not deploy SwapRelayer, so the test deploys it and registers
// it as a relayer (as 18_v2_swaprelayer_onchain_test.go does).
//
// Prerequisites: the same as 90_w5_timeout_refund_test.go, plus
// `npx hardhat compile` for the SwapRelayer artifact.
//
//	cd test && CC=clang go test -run TestW5_ -v -count=1 -timeout 900s

import (
	"context"
	"encoding/json"
	"fmt"
	"math/big"
	"os"
	"strings"
	"testing"

	"github.com/raylsnetwork/enygma_dvp/src/core"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
)

// w5Artifact reads a compiled contract's ABI and bytecode from ../artifacts.
func w5Artifact(t *testing.T, rel string) (abi.ABI, []byte) {
	t.Helper()
	data, err := os.ReadFile("../artifacts/contracts/" + rel)
	if err != nil {
		t.Fatalf("artifact %s missing (run `npx hardhat compile`): %v", rel, err)
	}
	var a struct {
		ABI      json.RawMessage `json:"abi"`
		Bytecode string          `json:"bytecode"`
	}
	if err := json.Unmarshal(data, &a); err != nil {
		t.Fatalf("parse %s: %v", rel, err)
	}
	parsed, err := abi.JSON(strings.NewReader(string(a.ABI)))
	if err != nil {
		t.Fatalf("parse ABI %s: %v", rel, err)
	}
	return parsed, common.FromHex(a.Bytecode)
}

// w5Mined waits for a setup transaction and fails the test if it reverted.
func w5Mined(t *testing.T, e *w5Env, what string, tx *types.Transaction, err error) {
	t.Helper()
	if err != nil {
		t.Fatalf("%s: %v", what, err)
	}
	r, err := bind.WaitMined(context.Background(), e.tc.client, tx)
	if err != nil || r.Status != types.ReceiptStatusSuccessful {
		t.Fatalf("%s did not succeed (err=%v)", what, err)
	}
}

func TestW5_RelayerCancel(t *testing.T) {
	if !chainAvailable() {
		t.Skip("Hardhat node not running on localhost:8545 — skipping on-chain test")
	}
	if !serverAvailable("localhost:8081") {
		t.Skip("gnark server not running on localhost:8081 — skipping on-chain test")
	}
	zero := big.NewInt(0)

	t.Run("CancelFreesOriginalNote", func(t *testing.T) {
		e := newW5Env(t)
		defer e.tc.client.Close()
		tc := e.tc

		// SwapRelayer, deployed and registered by the owner (account[0]).
		relABI, relBin := w5Artifact(t, "core/contracts/SwapRelayer.sol/SwapRelayer.json")
		relAddr, tx, _, err := bind.DeployContract(tc.auth, relABI, relBin, tc.client, e.dvpAddr)
		w5Mined(t, e, "deploy SwapRelayer", tx, err)
		tx, err = tc.dvp.Transact(tc.auth, "registerRelayer", relAddr)
		w5Mined(t, e, "registerRelayer", tx, err)
		relayer := bind.NewBoundContract(relAddr, relABI, tc.client, tc.client, tc.client)
		e.extra = append(e.extra, relABI)
		e.names[relAddr] = "SwapRelayer"

		d := dvpSetupDeposits(t, tc, w5NftId())
		w5say("== Relayer route: Alice deposits %s tokens and files her leg with SwapRelayer. Bob never delivers.", d.erc20Amount)

		res, _, err := w5InitiatorProof(tc.gnarkClient,
			core.KeyPair{PrivateKey: d.aliceSpend.PrivateKey, PublicKey: d.aliceSpend.PublicKey},
			d.aliceSaltField, d.erc20Amount, d.erc20TokenId,
			d.bobSpend.PublicKey, d.bobView.EncapsKey,
			d.nftAmount, d.nftTokenId, zero,
			d.aliceMerkleProof, tc.merkleDepth, vaultInt(tc.erc721VaultAddr))
		if err != nil {
			t.Fatalf("initiator proof: %v", err)
		}
		rc := w5Receipt(t, res)
		tree, nf := rc.Statement[1], rc.Statement[3]

		// The swapId the relayer expects for this leg.
		var out []interface{}
		if err := relayer.Call(nil, &out, "swapIdOf", rc, true); err != nil {
			t.Fatalf("swapIdOf: %v", err)
		}
		swapId := out[0].([32]byte)

		// The same 15 minute floor applies on this route.
		exp60 := new(big.Int).Add(currentBlockTimestamp(t, tc.client), big.NewInt(60))
		if why, _, _ := e.try(t, tc.auth, relAddr, relABI, relayer, "submitReceipt",
			swapId, rc, true, zero, exp60, res.CipherText, res.EncTxData); why == "" {
			t.Fatalf("a 60 s expiry was accepted")
		} else {
			w5say("R-STEP 1  expiry now+60 s -> refused: %s", why)
		}

		// Alice's leg through the relayer, 16 minute expiry.
		expiry := new(big.Int).Add(currentBlockTimestamp(t, tc.client), big.NewInt(w5DeadlineSeconds))
		why, tx, r := e.try(t, tc.auth, relAddr, relABI, relayer, "submitReceipt",
			swapId, rc, true, zero, expiry, res.CipherText, res.EncTxData)
		if why != "" {
			t.Fatalf("Alice's leg refused by SwapRelayer: %s", why)
		}
		legGas := r.GasUsed
		e.observe(t, fmt.Sprintf("R-STEP 2  Alice files her leg with SwapRelayer, expiry now+%d s (submitReceipt)", w5DeadlineSeconds), tc.auth.From, tx, r)
		locked, spent := e.noteState(t, tree, nf)
		w5say("          her note: locked=%v spent=%v", locked, spent)
		if !locked || spent {
			t.Errorf("after Alice's leg: locked=%v spent=%v, want locked and unspent", locked, spent)
		}

		// Nobody can cancel early.
		if why, _, _ := e.try(t, e.stranger, relAddr, relABI, relayer, "cancelSwap", swapId); why == "" {
			t.Fatalf("cancelSwap before the expiry was accepted")
		} else {
			w5say("R-STEP 3  stranger calls cancelSwap before the expiry -> refused: %s", why)
		}

		// Bob never delivers.
		hardhatIncreaseTime(t, tc.client, w5DeadlineSeconds+5)
		why, tx, r = e.try(t, e.stranger, relAddr, relABI, relayer, "cancelSwap", swapId)
		if why != "" {
			t.Fatalf("stranger's cancelSwap after the expiry refused: %s", why)
		}
		cancelGas := r.GasUsed
		e.observe(t, fmt.Sprintf("R-STEP 4  clock moved %d s, the same stranger calls cancelSwap -> accepted", w5DeadlineSeconds+5), e.stranger.From, tx, r)
		newNotes := 0
		for _, lg := range r.Logs {
			if len(lg.Topics) > 0 && lg.Topics[0] == tc.commitmentSig {
				newNotes++
			}
		}
		_, perr := loadVaultMerkleTree(t, tc.client, tc.erc20VaultAddr, tc.merkleDepth).GenerateProof(res.RevertCommitA)
		refundInTree := perr == nil
		locked, spent = e.noteState(t, tree, nf)
		w5say("          her ORIGINAL note: locked=%v spent=%v | new notes inserted: %d | refund note in the vault: %v", locked, spent, newNotes, refundInTree)
		if locked || spent {
			t.Errorf("after cancelSwap: original note locked=%v spent=%v, want both false", locked, spent)
		}
		if newNotes != 0 || refundInTree {
			t.Errorf("cancelSwap inserted a note: Commitment events=%d, refund note in tree=%v", newNotes, refundInTree)
		}

		// Alice withdraws her original note to a fresh address.
		recipient := w5FreshAddress(t)
		e.names[recipient] = "Alice's withdrawal address (fresh)"
		before := e.pw.balanceOf(t, recipient)
		vaultBefore := e.pw.balanceOf(t, tc.erc20VaultAddr)
		orig := pwNote{spend: d.aliceSpend, view: d.aliceView, salt: d.aliceSaltField, value: d.erc20Amount, commit: d.aliceCommitment}
		why, tx, r = e.withdrawAll(t, "original note", orig, recipient)
		if why != "" {
			t.Fatalf("withdrawing the original note after the cancel was refused: %s", why)
		}
		e.observe(t, "R-STEP 5  Alice withdraws her ORIGINAL note to a fresh address (withdrawV2)", tc.auth.From, tx, r)
		got := new(big.Int).Sub(e.pw.balanceOf(t, recipient), before)
		vaultDelta := new(big.Int).Sub(vaultBefore, e.pw.balanceOf(t, tc.erc20VaultAddr))
		w5say("          recipient balance +%s | vault balance -%s", got, vaultDelta)
		if got.Cmp(d.erc20Amount) != 0 || vaultDelta.Cmp(d.erc20Amount) != 0 {
			t.Errorf("original note: recipient got %s, vault paid %s, want %s each", got, vaultDelta, d.erc20Amount)
		}

		// It cannot be spent twice.
		why, _, _ = e.withdrawAll(t, "original note, second time", orig, w5FreshAddress(t))
		w5say("R-STEP 6  withdraw the original note a second time -> %s", why)
		if why != "InvalidNullifier" {
			t.Errorf("second withdrawal of the original note: got %q, want InvalidNullifier", why)
		}

		if w5TimeoutGas > 0 {
			w5say("          gas, same run: cancelSwap %s vs claimSwapTimeout %s | leg via relayer %s vs direct %s",
				w5commas(cancelGas), w5commas(w5TimeoutGas), w5commas(legGas), w5commas(w5LegGas))
		}
		w5say("W5-RESULT-RELAYER: stranger cancelled after the expiry, original note freed (not spent, no new note), withdrawn +%s, second spend refused", got)
	})
}
W5TEST2
}


say "Week 5 final run started"
note "started  $(date -u '+%Y-%m-%d %H:%M:%S') UTC"
note "where    ${GITHUB_ACTIONS:+GitHub Actions runner}${CODESPACES:+GitHub Codespace}"
note "repo     $(git -C "$ROOT" remote get-url origin 2>/dev/null)"
# Test Rayls' latest public code: merge raylsnetwork/Enygma main into this branch (no-op if already in).
git -C "$ROOT" config user.name "Smolder AR"; git -C "$ROOT" config user.email "smolderar@users.noreply.github.com"
if git -C "$ROOT" fetch -q https://github.com/raylsnetwork/Enygma main:refs/remotes/upstream/main 2>/dev/null; then
  if git -C "$ROOT" merge -q --no-edit upstream/main >/dev/null 2>&1; then note "PASS  00-sync (this branch includes Rayls' latest main)"
  else git -C "$ROOT" merge --abort >/dev/null 2>&1; note "FAIL  00-sync (could not merge Rayls' latest main)"; fi
fi
UP="$(git -C "$ROOT" rev-parse upstream/main 2>/dev/null)"
note "upstream raylsnetwork/Enygma main $UP"
note "machine  $(nproc) cores, $(free -g | awk '/Mem:/{print $2}') GB RAM, $(uname -sr)"

# ---------- tools ----------
say "Tools"
command -v clang >/dev/null || { sudo apt-get update -y >/dev/null && sudo apt-get install -y clang >/dev/null; }
if ! "$HOME/bin/solc" --version >/dev/null 2>&1; then
  P=$(curl -fsSL https://binaries.soliditylang.org/linux-amd64/list.json | python3 -c "import sys,json;print(json.load(sys.stdin)['releases']['0.8.24'])")
  curl -fsSL "https://binaries.soliditylang.org/linux-amd64/$P" -o "$HOME/bin/solc" && chmod +x "$HOME/bin/solc"
fi
export CC="$(command -v clang)"
note "go       $(go version 2>&1)"
note "node     $(node --version 2>&1), npm $(npm --version 2>&1)"
note "solc     $(solc --version 2>&1 | tail -n1)"
cd "$DVP" || { note "FAIL  enygma_dvp folder not found"; exit 1; }
rm -f "$NEWTEST" "$NEWTEST2"   # upstream tests run first on the unmodified repo
if [ "${1:-}" = "--check" ]; then
  write_tests
  if ( cd test && go test -count=1 -run '^$' . ) > /tmp/w5-check.log 2>&1; then
    echo; echo "COMPILE OK: both new test files build on $(git -C "$ROOT" rev-parse --short HEAD)"
  else
    echo; echo "COMPILE FAILED:"; tail -n 30 /tmp/w5-check.log
  fi
  rm -f "$NEWTEST" "$NEWTEST2"; exit 0
fi

# ---------- 1. dependencies and proving keys ----------
step 01-npm-install npm ci --no-audit --no-fund
# The repo does not ship scripts/keys/ (the README says it does), so generate them with the repo's own keygen.
if ls gnark_circuits/scripts/keys/DvPInitiatorPK.key >/dev/null 2>&1; then note "SKIP  02-keygen (keys already generated by the repo's keygen earlier)"
else step 02-keygen bash -c 'cd gnark_circuits && mkdir -p scripts/keys scripts/verifier && go run ./cmd/keygen'; fi

# ---------- 2. fresh local chain, compile, patch, deploy ----------
# Compile first: the Hardhat node reads the compiled artifacts when it starts, and only then can it
# name a contract's custom errors (SwapDeadlineTooSoon, InvalidNullifier, ...) that the tests check.
step 03-hardhat-compile  npx hardhat compile
say "04-hardhat-node (fresh local chain on 127.0.0.1:8545)"
pkill -f "hardhat node" 2>/dev/null; sleep 1
nohup npx hardhat node > "$LOG/04-hardhat-node.log" 2>&1 &
if wait_port 8545 90; then note "PASS  04-hardhat-node"; else note "FAIL  04-hardhat-node"; fi
step 05-patch-verifier   bash -c 'cd gnark_circuits && go run ./cmd/patch_verifier/'
step 06-regen-poseidon   node scripts/regen_poseidon.js
step 07-build-deploy     bash -c 'cd scripts && go build -o /tmp/deploy_contracts ./cmd/deploy'
step 08-deploy           /tmp/deploy_contracts
step 09-export-vk        bash -c 'cd gnark_circuits && go run ./cmd/export_vk_init/ ../build'

# init needs one VK file per circuit listed in enygmadvp.config.json (25), but keygen only builds 8
# circuits. Fill the slots of circuits these tests never use with a copy of Payment.json so init runs.
say "10-placeholder-vks"
python3 - "$LOG/10-placeholder-vks.log" <<'PY'
import json, os, shutil, sys
cfg = json.load(open("enygmadvp.config.json"))
def find(o):
    if isinstance(o, dict):
        for k, v in o.items():
            if k.lower() == "circuits" and isinstance(v, list): return v
            r = find(v)
            if r: return r
    if isinstance(o, list):
        for v in o:
            r = find(v)
            if r: return r
circ = find(cfg) or []
names = [c.get("Filename") or c.get("filename") for c in circ if isinstance(c, dict)]
import hashlib
h = lambda f: hashlib.sha256(open(f, "rb").read()).hexdigest()
pay = h("build/Payment.json")
real, filled = [], []
for n in names:
    p = f"build/{n}.json"
    if n != "Payment" and (not os.path.exists(p) or h(p) == pay):
        shutil.copy("build/Payment.json", p); filled.append(n)   # missing, or a copy left by an earlier run
    else: real.append(n)
with open(sys.argv[1], "w") as f:
    f.write(f"circuits in config: {len(names)}\nreal VKs: {len(real)} {real}\nplaceholders (circuits not built by keygen): {len(filled)} {filled}\n")
print(f"real VKs {len(real)}: {real}"); print(f"placeholders {len(filled)}")
PY
note "vks      $(head -n 2 "$LOG/10-placeholder-vks.log" | tail -n 1)"
step 11-build-init       bash -c 'cd scripts && go build -o /tmp/init_contracts ./cmd/init'
step 12-init             /tmp/init_contracts

# ---------- 3. proof server ----------
step 13-build-gnark-server bash -c 'cd gnark_circuits && go build -o /tmp/gnark_server ./cmd/server'
say "14-gnark-server (127.0.0.1:8081)"
pkill -f /tmp/gnark_server 2>/dev/null; sleep 1
( cd gnark_circuits && nohup /tmp/gnark_server > "$LOG/14-gnark-server.log" 2>&1 & )
if wait_port 8081 300; then note "PASS  14-gnark-server"; else note "FAIL  14-gnark-server"; fi

# ---------- 4. Rayls' own tests, unmodified ----------
say "15-upstream-tests (Rayls' own DvP, timeout, front-run, relayer and cross-circuit tests)"
( cd test && go test -run '^(TestV2Erc20OnChain_PrivateMint|TestV2DvP.*|TestV2CrossCircuit.*|TestV2SwapRelayer.*)$' -v -count=1 -timeout 1500s ) 2>&1 | tee "$LOG/15-upstream-tests.log"
note "--- upstream tests (repo unmodified) ---"
grep -E '^\s*--- (PASS|FAIL|SKIP)|^(PASS|FAIL)$|^ok |^FAIL\s' "$LOG/15-upstream-tests.log" | tee -a "$SUM"

# ---------- 5. add the two new test files and run them ----------
say "16-add-new-tests (two new files, nothing upstream is edited)"
write_tests
note "newtest  enygma_dvp/test/90_w5_timeout_refund_test.go sha256 $(sha256sum "$NEWTEST" | cut -c1-16)"
note "newtest  enygma_dvp/test/91_w5_relayer_cancel_test.go sha256 $(sha256sum "$NEWTEST2" | cut -c1-16)"
cp "$NEWTEST" "$LOG/90_w5_timeout_refund_test.go"; cp "$NEWTEST2" "$LOG/91_w5_relayer_cancel_test.go"

step 17-compile-new-test bash -c 'cd test && go test -count=1 -run "^$" .'
if grep -q "^PASS  17-compile-new-test" "$SUM"; then
  say "18-new-tests TestW5_TimeoutRefund and TestW5_RelayerCancel (both exits, a stranger as the caller, balances checked)"
  ( cd test && go test -run '^TestW5_' -v -count=1 -timeout 900s ) 2>&1 | tee "$LOG/18-w5-timeout-refund.log"
  note "--- new test ---"
  grep -E '^\s*--- (PASS|FAIL|SKIP)|W5-RESULT' "$LOG/18-w5-timeout-refund.log" | sed 's/^ *//' | cut -c1-400 | tee -a "$SUM"
  say "New test, step by step (same run, without the setup noise)"
  awk '/^=== RUN +TestW5_RelayerCancel$/{exit} 1' "$LOG/18-w5-timeout-refund.log" | grep -E '\[W5\]|^\s*--- (PASS|FAIL)' | grep -v 'observer\]' | sed 's/^ *//; s/^\[W5\] //' | cut -c1-160
  sleep 4
  say "Second exit: the SwapRelayer route, step by step (same run)"
  awk 'f; /^=== RUN +TestW5_RelayerCancel$/{f=1}' "$LOG/18-w5-timeout-refund.log" | grep -E '\[W5\]|^\s*--- (PASS|FAIL)' | grep -v 'observer\]' | sed 's/^ *//; s/^\[W5\] //' | cut -c1-160
  sleep 10
else
  note "SKIP  18-new-tests (did not compile, see w5-logs/17-compile-new-test.log)"
fi

# ---------- 6. evidence from the source ----------
say "19-source-evidence"
{
  echo "## claimSwapTimeout (EnygmaDvp.sol)"
  awk '/function claimSwapTimeout/,/^    }/' contracts/core/contracts/EnygmaDvp.sol
  echo; echo "## SwapRelayer.cancelSwap (the relayer route frees the original note instead)"
  awk '/function cancelSwap/,/^    }/' contracts/core/contracts/SwapRelayer.sol
  echo; echo "## Deadline in the docs vs the contract"
  grep -n "now+60s" docs/flows/04_dvp_deadline.md
  grep -n "MIN_SWAP_DURATION =" contracts/core/contracts/EnygmaDvp.sol
} > "$LOG/19-source-evidence.txt" 2>&1
note "PASS  19-source-evidence (w5-logs/19-source-evidence.txt)"

say "20-what-changed"
{
  echo "## Files changed against Rayls' latest main (tracked), excluding w5-logs/, the run script and the Actions workflow"
  git -C "$ROOT" diff --stat upstream/main -- . ':(exclude)w5-logs' ':(exclude)w5-run*.sh' ':(exclude)w5-final.sh' ':(exclude).github/workflows/w5-check.yml' 2>&1
  echo "(PrivateMintVerifier.sol is rewritten by the repo's own setup step: gnark_circuits/cmd/patch_verifier, step 05)"
  echo "## Working tree status for test/, src/, contracts/ (M = modified, ?? = new file)"
  git -C "$ROOT" status --porcelain --untracked-files=normal -- enygma_dvp/test enygma_dvp/src enygma_dvp/contracts 2>&1
} > "$LOG/20-what-changed.txt"
note "changed  $(grep -c . "$LOG/20-what-changed.txt") lines in w5-logs/20-what-changed.txt"

say "21-merkle-status"
curl -s -X POST http://127.0.0.1:8081/util/merkleStatus -H 'Content-Type: application/json' -d '{}' | python3 -m json.tool > "$LOG/21-merkle-status.json" 2>&1
python3 - "$LOG/21-merkle-status.json" <<'PY' | tee -a "$SUM"
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    for v in d.get("vaults", d if isinstance(d, list) else []):
        if isinstance(v, dict): print("merkle  ", v.get("name"), "leaves", v.get("leafCount", v.get("leaves")), "match", v.get("match"))
    print("registry allMatch", (d.get("enygmaDvpRegistryCheck") or {}).get("allMatch"))
except Exception as e: print("merkle   could not parse:", e)
PY
cp build/receipts.json "$LOG/receipts.json" 2>/dev/null
note "finished $(date -u '+%Y-%m-%d %H:%M:%S') UTC"

cat > "$LOG/README.md" <<'W5README'
# Enygma DvP: what happens to your tokens if the other side never delivers?

An independent check of Rayls' public Enygma repository ([raylsnetwork/Enygma](https://github.com/raylsnetwork/Enygma), commit `@@UP@@`, folder `enygma_dvp`) on a local Hardhat chain. No real money, no wallet, no live network.

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
W5README
sed -i "s/@@UP@@/${UP:0:7}/" "$LOG/README.md"

cd "$ROOT"
if command -v zip >/dev/null; then zip -qr w5-logs.zip w5-logs; else python3 -m zipfile -c w5-logs.zip w5-logs; fi

if [ "$PUBLISH" = "1" ]; then
  say "Saving logs to GitHub (branch w5-logs)"
  git config user.name "Smolder AR"; git config user.email "smolderar@users.noreply.github.com"
  git checkout -B w5-logs >/dev/null 2>&1
  # keep the Actions workflow that lives on the remote branch (added on GitHub), in this commit
  git fetch -q origin w5-logs 2>/dev/null && git checkout origin/w5-logs -- .github/workflows/w5-check.yml 2>/dev/null
  cp "$0" "$ROOT/w5-final.sh" 2>/dev/null
  git add -f w5-logs w5-final.sh "$NEWTEST" "$NEWTEST2"
  [ -f .github/workflows/w5-check.yml ] && git add -f .github/workflows/w5-check.yml
  git commit -m "Week 5 final run log $(date -u '+%Y-%m-%d %H:%M') UTC" >/dev/null 2>&1
  if git push -f -u origin w5-logs > /dev/null 2>&1; then echo "Logs pushed to branch w5-logs."; else echo "Push failed."; fi
else
  echo
  echo "Finished. Nothing was pushed to GitHub."
  echo "Logs are in w5-logs/ and w5-logs.zip."
fi
