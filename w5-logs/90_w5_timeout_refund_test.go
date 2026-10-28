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
