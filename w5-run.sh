#!/usr/bin/env bash
# Week 5: run Rayls' own Enygma DvP tests (incl. the deadline / timeout path) on a clean Linux machine.
# Local Hardhat chain only. No real money, no wallet, nothing sent to any live network.
# Usage (inside the Codespace, repo root): bash w5-run.sh
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
DVP="$ROOT/enygma_dvp"
LOG="$ROOT/w5-logs"
mkdir -p "$LOG" "$HOME/bin"
export PATH="$HOME/bin:$PATH" GOTOOLCHAIN=auto
SUM="$LOG/00-summary.txt"
: > "$SUM"
say()  { echo; echo "=== $(date -u '+%Y-%m-%d %H:%M:%S') UTC  $*"; }
note() { echo "$*" | tee -a "$SUM"; }
step() { local name="$1"; shift; say "$name"; if "$@" > "$LOG/$name.log" 2>&1; then note "PASS  $name"; else note "FAIL  $name (see w5-logs/$name.log)"; tail -n 25 "$LOG/$name.log"; fi; }
wait_port() { for i in $(seq 1 "$2"); do (echo > /dev/tcp/127.0.0.1/$1) 2>/dev/null && return 0; sleep 2; done; return 1; }

say "Week 5 run started"
note "started  $(date -u '+%Y-%m-%d %H:%M:%S') UTC"
note "repo     $(git -C "$ROOT" remote get-url origin)"
note "commit   $(git -C "$ROOT" rev-parse HEAD)"
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
note "clang    $($CC --version 2>&1 | head -n1)"

cd "$DVP" || { note "FAIL  enygma_dvp folder not found"; exit 1; }

# ---------- build, local chain, deploy ----------
step 01-npm-install            npm ci --no-audit --no-fund
step 02-hardhat-compile        npx hardhat compile
say "03-hardhat-node (local chain on 127.0.0.1:8545)"
pkill -f "hardhat node" 2>/dev/null; sleep 1
nohup npx hardhat node > "$LOG/03-hardhat-node.log" 2>&1 &
if wait_port 8545 60; then note "PASS  03-hardhat-node"; else note "FAIL  03-hardhat-node"; fi
step 04-regen-poseidon         node scripts/regen_poseidon.js
step 05-build-deploy           bash -c 'cd scripts && go build -o /tmp/deploy_contracts ./cmd/deploy'
step 06-deploy                 /tmp/deploy_contracts
step 07-export-vk              bash -c 'cd gnark_circuits && go run ./cmd/export_vk_init/ ../build'
step 08-build-init             bash -c 'cd scripts && go build -o /tmp/init_contracts ./cmd/init'
step 09-init                   /tmp/init_contracts

# ---------- proof server ----------
step 10-build-gnark-server     bash -c 'cd gnark_circuits && go build -o /tmp/gnark_server ./cmd/server'
say "11-gnark-server (127.0.0.1:8081)"
pkill -f /tmp/gnark_server 2>/dev/null; sleep 1
( cd gnark_circuits && nohup /tmp/gnark_server > "$LOG/11-gnark-server.log" 2>&1 & )
if wait_port 8081 300; then note "PASS  11-gnark-server"; else note "FAIL  11-gnark-server"; fi

# ---------- Rayls' own integration tests ----------
say "12-integration-tests (PrivateMint, Payment, DvP, DvP_WithDeadline)"
( cd test && go test -run 'TestV2Erc20OnChain_PrivateMint|TestV2Erc20Payment|TestV2DvP|TestV2DvP_WithDeadline' -v -count=1 -timeout 900s ) 2>&1 | tee "$LOG/12-integration-tests.log"
grep -E '^(=== RUN|--- (PASS|FAIL)|PASS|FAIL|ok )' "$LOG/12-integration-tests.log" | tee -a "$SUM"

say "13-merkle-status"
curl -s -X POST http://127.0.0.1:8081/util/merkleStatus -H 'Content-Type: application/json' -d '{}' | python3 -m json.tool > "$LOG/13-merkle-status.json" 2>&1
note "merkle   $(python3 -c "import json;d=json.load(open('$LOG/13-merkle-status.json'));print(json.dumps(d)[:600])" 2>&1)"

cp build/receipts.json "$LOG/receipts.json" 2>/dev/null
note "finished $(date -u '+%Y-%m-%d %H:%M:%S') UTC"

# ---------- publish the logs to the fork (branch w5-logs) ----------
say "Saving logs to GitHub (branch w5-logs)"
cd "$ROOT"
git config user.name "Smolder AR"; git config user.email "smolderar@users.noreply.github.com"
git checkout -B w5-logs >/dev/null 2>&1
git add -f w5-logs w5-run.sh
git commit -m "Week 5 run log $(date -u '+%Y-%m-%d %H:%M') UTC" >/dev/null 2>&1
if git push -f -u origin w5-logs > /dev/null 2>&1; then echo "Logs pushed. Tell Claude: done"; else echo "Push failed. Tell Claude: push failed"; fi
