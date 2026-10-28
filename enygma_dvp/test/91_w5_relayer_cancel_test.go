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
