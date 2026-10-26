#!/usr/bin/env bash
# Week 5 (v2): run Rayls' own Enygma DvP integration tests, incl. the deadline / timeout path,
# on a clean Linux machine. Local Hardhat chain only: no real money, no wallet, no live network.
# Usage (Codespace terminal, repo root): bash w5-run.sh
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
DVP="$ROOT/enygma_dvp"
LOG="$ROOT/w5-logs"
rm -rf "$LOG"; mkdir -p "$LOG" "$HOME/bin"
export PATH="$HOME/bin:$PATH" GOTOOLCHAIN=auto
SUM="$LOG/00-summary.txt"; : > "$SUM"
say()  { echo; echo "=== $(date -u '+%Y-%m-%d %H:%M:%S') UTC  $*"; }
note() { echo "$*" | tee -a "$SUM"; }
step() { local name="$1"; shift; say "$name"; local t0=$(date +%s)
         if "$@" > "$LOG/$name.log" 2>&1; then note "PASS  $name ($(( $(date +%s)-t0 )) s)"; return 0
         else note "FAIL  $name (see w5-logs/$name.log)"; tail -n 25 "$LOG/$name.log"; return 1; fi; }
wait_port() { for i in $(seq 1 "$2"); do (echo > /dev/tcp/127.0.0.1/$1) 2>/dev/null && return 0; sleep 2; done; return 1; }

say "Week 5 run started"
note "started  $(date -u '+%Y-%m-%d %H:%M:%S') UTC"
note "repo     $(git -C "$ROOT" remote get-url origin)"
note "commit   $(git -C "$ROOT" rev-parse HEAD) (upstream main $(git -C "$ROOT" log -1 --format=%h origin/main 2>/dev/null))"
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

# ---------- 1. dependencies and proving keys ----------
step 01-npm-install npm ci --no-audit --no-fund
# The repo does not ship scripts/keys/ (the README says it does), so generate them with the repo's own keygen.
if ls gnark_circuits/scripts/keys/DvPInitiatorPK.key >/dev/null 2>&1; then note "SKIP  02-keygen (keys already generated)"
else step 02-keygen bash -c 'cd gnark_circuits && mkdir -p scripts/keys scripts/verifier && go run ./cmd/keygen'; fi
note "keys     $(ls gnark_circuits/scripts/keys 2>/dev/null | tr '\n' ' ')"

# ---------- 2. local chain, compile, patch, deploy ----------
say "03-hardhat-node (local chain on 127.0.0.1:8545)"
pkill -f "hardhat node" 2>/dev/null; sleep 1
nohup npx hardhat node > "$LOG/03-hardhat-node.log" 2>&1 &
if wait_port 8545 90; then note "PASS  03-hardhat-node"; else note "FAIL  03-hardhat-node"; fi
step 04-hardhat-compile  npx hardhat compile
step 05-patch-verifier   bash -c 'cd gnark_circuits && go run ./cmd/patch_verifier/'
step 06-regen-poseidon   node scripts/regen_poseidon.js
step 07-build-deploy     bash -c 'cd scripts && go build -o /tmp/deploy_contracts ./cmd/deploy'
step 08-deploy           /tmp/deploy_contracts
step 09-export-vk        bash -c 'cd gnark_circuits && go run ./cmd/export_vk_init/ ../build'

# init needs one VK file per circuit listed in enygmadvp.config.json (25), but keygen only builds the
# circuits these tests use. Fill the unused slots with a copy of Payment.json so init can register them.
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
real, filled = [], []
for n in names:
    p = f"build/{n}.json"
    if os.path.exists(p): real.append(n)
    else: shutil.copy("build/Payment.json", p); filled.append(n)
with open(sys.argv[1], "w") as f:
    f.write(f"circuits in config: {len(names)}\nreal VKs: {len(real)} {real}\nplaceholders (not used by these tests): {len(filled)} {filled}\n")
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

# ---------- 4. Rayls' own integration tests ----------
say "15-integration-tests (PrivateMint, Payment, DvP, DvP_WithDeadline)"
( cd test && go test -run '^(TestV2Erc20OnChain_PrivateMint|TestV2Erc20Payment|TestV2DvP|TestV2DvP_WithDeadline)$' -v -count=1 -timeout 900s ) 2>&1 | tee "$LOG/15-integration-tests.log"
grep -E '^\s*(--- (PASS|FAIL)|PASS$|FAIL$|ok |FAIL\s)' "$LOG/15-integration-tests.log" | tee -a "$SUM"

say "16-merkle-status"
curl -s -X POST http://127.0.0.1:8081/util/merkleStatus -H 'Content-Type: application/json' -d '{}' | python3 -m json.tool > "$LOG/16-merkle-status.json" 2>&1
python3 - "$LOG/16-merkle-status.json" <<'PY' | tee -a "$SUM"
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

# ---------- publish logs to the fork (branch w5-logs) ----------
say "Saving logs to GitHub (branch w5-logs)"
cd "$ROOT"
git config user.name "Smolder AR"; git config user.email "smolderar@users.noreply.github.com"
git checkout -B w5-logs >/dev/null 2>&1
git add -f w5-logs w5-run.sh
git commit -m "Week 5 run log $(date -u '+%Y-%m-%d %H:%M') UTC" >/dev/null 2>&1
if git push -f -u origin w5-logs > /dev/null 2>&1; then echo "Logs pushed. Tell Claude: done"; else echo "Push failed. Tell Claude: push failed"; fi
