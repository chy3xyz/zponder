#!/usr/bin/env bash
# zponder Launchpad Demo — template indexing end-to-end acceptance test
#
# Flow:
#   anvil → deploy Launchpad → createCurve() ×3 → buy() on each clone
#         → zponder (factory discovery feeds the "curve" template)
#         → assert one set of tables holds every clone's events
#
# This script is a test, not a printout: every assertion exits 1 when it fails.
#
# Usage:
#   bash examples/local-demo/launchpad-demo/run.sh
#
# Env overrides:
#   ANVIL_PORT=8590  HTTP_PORT=8591  CLEAN_DB=1  SKIP_BUILD=1
#
# Leave behind: repo-root `demo.db` (delete with CLEAN_DB=1 or `rm -f demo.db*`)

set -euo pipefail
cd "$(dirname "$0")/../../.."
REPO_ROOT="$PWD"
DEMO_DIR="examples/local-demo/launchpad-demo"

export PATH="$HOME/.foundry/bin:$HOME/.cargo/bin:$PATH"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ANVIL_PORT="${ANVIL_PORT:-8590}"
HTTP_PORT="${HTTP_PORT:-8591}"
RPC="http://127.0.0.1:${ANVIL_PORT}"
DB="$REPO_ROOT/demo.db"
CONFIG=/tmp/zponder-launchpad-config.toml
ZPOND_LOG=/tmp/zponder-launchpad.log
ANVIL_LOG=/tmp/zponder-launchpad-anvil.log
BUILD_DIR=/tmp/zponder-launchpad-build

# 6 Buy events expected: clone1 ×1, clone2 ×2, clone3 ×3
BUYS_PER_CLONE=(1 2 3)

say() { echo ""; echo -e "${YELLOW}━━ $1${NC}"; }
pass() { echo -e "  ${GREEN}PASS${NC} $1"; }
die() { echo -e "  ${RED}FAIL${NC} $1"; exit 1; }

check_eq() { # label expected actual
    if [[ "$2" == "$3" ]]; then
        pass "$1 = $3"
    else
        echo -e "  ${RED}FAIL${NC} $1: expected '$2', got '$3'"
        echo -e "  ${YELLOW}zponder log tail:${NC}"
        tail -20 "$ZPOND_LOG" 2>/dev/null || true
        exit 1
    fi
}

# ── cleanup ────────────────────────────────────────────────────────────────
# zponder's SIGTERM path is a graceful shutdown that can hang, so we go
# straight to SIGKILL (and also by pattern, because `timeout` wraps the real
# process and killing the wrapper would orphan the child).
cleanup() {
    local rc=$?
    kill -9 "${ZPOND_PID:-0}" 2>/dev/null || true
    pkill -9 -f 'zponder-launchpad-config' 2>/dev/null || true
    kill -9 "${ANVIL_PID:-0}" 2>/dev/null || true
    pkill -9 -f "anvil --port ${ANVIL_PORT}" 2>/dev/null || true
    if [[ "${CLEAN_DB:-0}" == "1" ]]; then
        rm -f "$DB" "$DB-shm" "$DB-wal"
    fi
    exit "$rc"
}
trap cleanup EXIT INT TERM

# ── 0. prerequisites ───────────────────────────────────────────────────────
for bin in anvil cast solc sqlite3 curl python3 zig; do
    command -v "$bin" >/dev/null 2>&1 || die "$bin not found in PATH"
done
for p in "$ANVIL_PORT" "$HTTP_PORT"; do
    if (echo >"/dev/tcp/127.0.0.1/$p") >/dev/null 2>&1; then
        die "port $p is already in use (set ANVIL_PORT/HTTP_PORT to free ports)"
    fi
done

echo -e "${BOLD}${CYAN}zponder — Launchpad template-indexing acceptance${NC}"
echo "  anvil : $RPC"
echo "  REST  : http://127.0.0.1:${HTTP_PORT}"
echo "  db    : $DB"

# ── 1. build ───────────────────────────────────────────────────────────────
say "[1/7] Build zponder"
if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    zig build 2>&1 | tail -3
fi
[[ -x ./zig-out/bin/zponder ]] || die "zig-out/bin/zponder missing"
pass "binary: ./zig-out/bin/zponder"

# ── 2. anvil ───────────────────────────────────────────────────────────────
say "[2/7] Start anvil on :$ANVIL_PORT"
anvil --port "$ANVIL_PORT" --quiet >"$ANVIL_LOG" 2>&1 &
ANVIL_PID=$!
disown # keep bash from printing its own "Killed: 9" job notice at exit
for _ in $(seq 1 50); do
    if curl -s -X POST "$RPC" -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null | grep -q '"result"'; then
        pass "anvil ready (pid $ANVIL_PID)"
        break
    fi
    sleep 0.2
done
kill -0 "$ANVIL_PID" 2>/dev/null || { cat "$ANVIL_LOG"; die "anvil did not start"; }

# ── 3. compile & deploy ────────────────────────────────────────────────────
say "[3/7] Compile Launchpad.sol + Curve.sol and deploy"
rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"
if ! solc --abi --bin --optimize --overwrite \
    "$DEMO_DIR/Launchpad.sol" "$DEMO_DIR/Curve.sol" -o "$BUILD_DIR" >"$BUILD_DIR/solc.log" 2>&1; then
    cat "$BUILD_DIR/solc.log"; die "solc failed"
fi
# The config points at the committed ABIs — make sure they match the sources.
python3 -c '
import json, sys
build, demo = sys.argv[1], sys.argv[2]
for name in ("Launchpad", "Curve"):
    if json.load(open(build + "/" + name + ".abi")) != json.load(open(demo + "/" + name + ".abi")):
        print("ABI drift: " + name)
        sys.exit(1)
' "$BUILD_DIR" "$DEMO_DIR" || die "committed .abi drifted from .sol — re-copy solc output"
pass "solc ok; committed ABIs match sources"

PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
send() { cast send --private-key "$PK" --rpc-url "$RPC" --json "$@"; }
jget() { python3 -c "$1"; }

LAUNCHPAD=$(send --create "$(cat "$BUILD_DIR/Launchpad.bin")" | jget 'import json,sys;print(json.load(sys.stdin)["contractAddress"].lower())')
pass "Launchpad deployed at $LAUNCHPAD"

# ── 4. create clones + buys ────────────────────────────────────────────────
say "[4/7] createCurve() ×3, then buy() on each clone"
CURVES=()
for i in 1 2 3; do
    RECEIPT=$(send "$LAUNCHPAD" "createCurve()")
    LOGS=$(echo "$RECEIPT" | jget 'import json,sys;print(len(json.load(sys.stdin)["logs"]))')
    [[ "$LOGS" == "1" ]] || die "createCurve #$i: expected 1 log (CurveCreated), got $LOGS"
    # CurveCreated(address curve, address token) — both non-indexed data words.
    CURVE=$(echo "$RECEIPT" | jget 'import json,sys;d=json.load(sys.stdin)["logs"][0]["data"][2:];print("0x"+d[24:64])')
    CURVES+=("$CURVE")
    pass "clone $i: $CURVE"
done

for i in 0 1 2; do
    for n in $(seq 1 "${BUYS_PER_CLONE[$i]}"); do
        TX=$(send "${CURVES[$i]}" "buy(uint256)" "$((n * 1000000000000000000))" \
            | jget 'import json,sys;print(json.load(sys.stdin)["transactionHash"])')
        pass "clone $((i+1)) buy #$n: $TX"
    done
done
TOTAL_BUYS=0
for n in "${BUYS_PER_CLONE[@]}"; do TOTAL_BUYS=$((TOTAL_BUYS + n)); done
echo "  total Buy events expected: $TOTAL_BUYS"

# ── 5. start zponder ───────────────────────────────────────────────────────
say "[5/7] Start zponder (factory discovery → curve template)"
rm -f "$DB" "$DB-shm" "$DB-wal"
sed -e "s/0x5FbDB2315678afecb367f032d93F642f64180aa3/${LAUNCHPAD}/g" \
    -e "s|localhost:8590|127.0.0.1:${ANVIL_PORT}|" \
    -e "s/port = 8591/port = ${HTTP_PORT}/" \
    "$DEMO_DIR/config.toml" >"$CONFIG"

timeout -k 2 300 ./zig-out/bin/zponder -c "$CONFIG" >"$ZPOND_LOG" 2>&1 &
ZPOND_PID=$!
disown # as with anvil: silence bash's own killed-job notice

READY=0
for _ in $(seq 1 100); do
    if curl -sf "http://127.0.0.1:${HTTP_PORT}/health" >/dev/null 2>&1; then READY=1; break; fi
    kill -0 "$ZPOND_PID" 2>/dev/null || { tail -30 "$ZPOND_LOG"; die "zponder exited during startup"; }
    sleep 0.2
done
[[ "$READY" == "1" ]] || { tail -30 "$ZPOND_LOG"; die "zponder REST API did not come up"; }
pass "zponder up (pid $ZPOND_PID), REST on :$HTTP_PORT"

# ── 6. wait for convergence ────────────────────────────────────────────────
say "[6/7] Wait for discovery + template indexing (up to 60s)"
wait_sql() { # sql expected label
    local got deadline=$((SECONDS + 60))
    while true; do
        got=$(sqlite3 "$DB" "$1" 2>/dev/null || true)
        [[ "$got" == "$2" ]] && return 0
        if ((SECONDS >= deadline)); then
            echo -e "  ${RED}timeout${NC}: $3 → expected '$2', got '${got:-<none>}'"
            echo -e "  ${YELLOW}zponder log tail:${NC}"; tail -30 "$ZPOND_LOG" || true
            exit 1
        fi
        sleep 0.3
    done
}
wait_sql "SELECT COUNT(*) FROM template_addresses WHERE template='curve';" 3 "template_addresses 3"
wait_sql "SELECT COUNT(*) FROM event_curve_Buy;" "$TOTAL_BUYS" "event_curve_Buy $TOTAL_BUYS"
# template_addresses only reaches 3 once discovery ran; the event count only
# reaches 6 once the template backfill + sweep covered every clone.
sleep 1
pass "converged: 3 cloned addresses discovered, $TOTAL_BUYS Buy events indexed"

# ── 7. assertions ──────────────────────────────────────────────────────────
say "[7/7] Assertions"
echo "  event_curve_Buy by address:"
sqlite3 -header -column "$DB" \
    "SELECT contract_address, COUNT(*) AS buys FROM event_curve_Buy GROUP BY 1 ORDER BY 1;" | sed 's/^/    /'
echo "  template_addresses:"
sqlite3 -header -column "$DB" \
    "SELECT template, address, from_block, backfilled FROM template_addresses ORDER BY 1, 2;" | sed 's/^/    /'
echo "  GET /contracts (the template is listed with an empty address):"
curl -s "http://127.0.0.1:${HTTP_PORT}/contracts" | python3 -m json.tool | sed 's/^/    /'

# A1 — each clone did its own buys (3 clones × distinct counts)
for i in 0 1 2; do
    got=$(sqlite3 "$DB" "SELECT COUNT(*) FROM event_curve_Buy WHERE contract_address='${CURVES[$i]}';")
    check_eq "A1 clone$((i+1)) buys (${CURVES[$i]})" "${BUYS_PER_CLONE[$i]}" "$got"
done

# A2 — three distinct contract addresses in the one shared table
check_eq "A2 COUNT(DISTINCT contract_address)" 3 \
    "$(sqlite3 "$DB" 'SELECT COUNT(DISTINCT contract_address) FROM event_curve_Buy;')"

# A3 — filtering by a single clone address yields exactly that clone's rows
check_eq "A3 rows WHERE contract_address='${CURVES[1]}'" "${BUYS_PER_CLONE[1]}" \
    "$(sqlite3 "$DB" "SELECT COUNT(*) FROM event_curve_Buy WHERE contract_address='${CURVES[1]}';")"

# A4 — discovery recorded all three clones against the template
check_eq "A4 template_addresses WHERE template='curve'" 3 \
    "$(sqlite3 "$DB" "SELECT COUNT(*) FROM template_addresses WHERE template='curve';")"

# A5 — exactly one set of event_curve_* tables (not one per clone)
check_eq "A5 COUNT(tables LIKE 'event_curve_*')" 1 \
    "$(sqlite3 "$DB" '.tables' | tr -s ' ' '\n' | grep -c '^event_curve_' || true)"
ls -1 "$DB"* | sed 's/^/    /'

# A6 — REST ?address= narrows to the requested clone
REST_ADDR=$(curl -s "http://127.0.0.1:${HTTP_PORT}/events/curve/Buy?address=${CURVES[1]}&limit=100")
check_eq "A6a REST ?address= row count" "${BUYS_PER_CLONE[1]}" \
    "$(echo "$REST_ADDR" | jget 'import json,sys;print(len(json.load(sys.stdin)))')"
check_eq "A6b REST ?address= distinct contract_address" "${CURVES[1]}" \
    "$(echo "$REST_ADDR" | jget 'import json,sys;d=json.load(sys.stdin);print(",".join(sorted({r["contract_address"] for r in d})))')"

# A7 — unfiltered REST sees every clone's events in the same table
check_eq "A7 REST unfiltered row count" "$TOTAL_BUYS" \
    "$(curl -s "http://127.0.0.1:${HTTP_PORT}/events/curve/Buy?limit=100" | jget 'import json,sys;print(len(json.load(sys.stdin)))')"

echo ""
echo -e "${GREEN}${BOLD}All assertions passed.${NC}"
echo "  Inspect: sqlite3 demo.db \"SELECT contract_address, COUNT(*) FROM event_curve_Buy GROUP BY 1;\""
echo "  Cleanup: rm -f demo.db*   (or re-run with CLEAN_DB=1)"
