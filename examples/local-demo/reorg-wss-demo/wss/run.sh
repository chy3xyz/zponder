#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../../../.."
REPO_ROOT="$PWD"
DEMO_DIR="$REPO_ROOT/examples/local-demo/reorg-wss-demo"
export PATH="$HOME/.foundry/bin:$HOME/.cargo/bin:$PATH"

ANVIL_PORT="${ANVIL_PORT:-8623}"
PROXY_PORT="${PROXY_PORT:-8624}"
HTTP_PORT="${HTTP_PORT:-8625}"
RPC="http://127.0.0.1:$ANVIL_PORT"
WORK_DIR=$(mktemp -d "/tmp/zponder-wss-e2e.XXXXXX")
DB="$WORK_DIR/wss.db"
ZPOND_LOG="$WORK_DIR/zponder.log"
ANVIL_LOG="$WORK_DIR/anvil.log"
PROXY_LOG="$WORK_DIR/proxy.log"
PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
ANVIL_PID=""
PROXY_PID=""
ZPOND_PID=""

pass() { printf 'PASS %s\n' "$1"; }
die() {
    printf 'FAIL %s\n' "$1" >&2
    printf 'work dir: %s\n' "$WORK_DIR" >&2
    tail -60 "$ZPOND_LOG" 2>/dev/null >&2 || true
    exit 1
}
check_eq() {
    [[ "$2" == "$3" ]] || die "$1: expected '$2', got '$3'"
    pass "$1 = $3"
}
cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    for pid in "$ZPOND_PID" "$PROXY_PID" "$ANVIL_PID"; do
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    done
    sleep 0.2
    for pid in "$ZPOND_PID" "$PROXY_PID" "$ANVIL_PID"; do
        [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null || true
        [[ -n "$pid" ]] && wait "$pid" 2>/dev/null || true
    done
    printf 'artifacts: %s\n' "$WORK_DIR"
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for bin in anvil cast solc sqlite3 curl python3 zig; do
    command -v "$bin" >/dev/null 2>&1 || die "$bin not found"
done
python3 - "$ANVIL_PORT" "$PROXY_PORT" "$HTTP_PORT" <<'PY' || die "ANVIL_PORT/PROXY_PORT/HTTP_PORT must be free"
import socket, sys
for port in map(int, sys.argv[1:]):
    with socket.socket() as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("127.0.0.1", port))
PY

printf 'WSS e2e work dir: %s\n' "$WORK_DIR"
SOURCE_BIN="${ZPOND_BIN:-$REPO_ROOT/zig-out/bin/zponder}"
if [[ "${SKIP_BUILD:-0}" != "1" && -z "${ZPOND_BIN:-}" ]]; then
    zig build
fi
[[ -x "$SOURCE_BIN" ]] || die "zponder binary missing: $SOURCE_BIN"
cp "$SOURCE_BIN" "$WORK_DIR/zponder"
pass "copied zponder binary to isolated work dir"

anvil --host 127.0.0.1 --port "$ANVIL_PORT" --quiet >"$ANVIL_LOG" 2>&1 &
ANVIL_PID=$!
for _ in $(seq 1 100); do
    cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break
    kill -0 "$ANVIL_PID" 2>/dev/null || die "anvil exited"
    sleep 0.1
done
cast block-number --rpc-url "$RPC" >/dev/null 2>&1 || die "anvil did not become ready"
pass "anvil ready on :$ANVIL_PORT"

start_proxy() {
    python3 "$DEMO_DIR/wss/tcp_proxy.py" --listen-port "$PROXY_PORT" --upstream-port "$ANVIL_PORT" >>"$PROXY_LOG" 2>&1 &
    PROXY_PID=$!
    for _ in $(seq 1 100); do
        if python3 - "$PROXY_PORT" <<'PY' 2>/dev/null
import socket, sys
with socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=0.2):
    pass
PY
        then
            return 0
        fi
        kill -0 "$PROXY_PID" 2>/dev/null || die "proxy exited"
        sleep 0.1
    done
    die "proxy did not become ready"
}
start_proxy
pass "killable TCP proxy ready on :$PROXY_PORT"

mkdir -p "$WORK_DIR/build"
solc --abi --bin --optimize --overwrite "$DEMO_DIR/Ping.sol" -o "$WORK_DIR/build" >"$WORK_DIR/solc.log" 2>&1 || die "solc failed"
python3 - "$WORK_DIR/build/Ping.abi" "$DEMO_DIR/Ping.abi" <<'PY' || die "Ping.abi drifted from Ping.sol"
import json, sys
assert json.load(open(sys.argv[1])) == json.load(open(sys.argv[2]))
PY
DEPLOY=$(cast send --private-key "$PK" --rpc-url "$RPC" --json --create "$(<"$WORK_DIR/build/Ping.bin")")
ADDR=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["contractAddress"].lower())' <<<"$DEPLOY")
[[ "$ADDR" =~ ^0x[0-9a-f]{40}$ ]] || die "invalid deployed address: $ADDR"
pass "Ping deployed at $ADDR"

cat >"$WORK_DIR/config.toml" <<EOF
[global]
log_level = "info"
log_file = ""
snapshot_interval = 0
chain = "anvil"
track_blocks = true

[rpc]
url = "$RPC"
ws_url = "ws://127.0.0.1:$PROXY_PORT"
timeout = 5000
retry_count = 3

[database]
type = "sqlite"
db_name = "$DB"

[http]
port = $HTTP_PORT
host = "127.0.0.1"
cors = false

[[contracts]]
name = "ping"
address = "$ADDR"
abi_path = "$DEMO_DIR/Ping.abi"
from_block = 0
events = ["Ping"]
poll_interval_ms = 100
block_batch_size = 100
max_reorg_depth = 20
EOF

"$WORK_DIR/zponder" -c "$WORK_DIR/config.toml" >"$ZPOND_LOG" 2>&1 &
ZPOND_PID=$!
for _ in $(seq 1 150); do
    curl -sf "http://127.0.0.1:$HTTP_PORT/health" >/dev/null 2>&1 && break
    kill -0 "$ZPOND_PID" 2>/dev/null || die "zponder exited during startup"
    sleep 0.1
done
curl -sf "http://127.0.0.1:$HTTP_PORT/health" >/dev/null 2>&1 || die "zponder health timeout"

wait_log_count() {
    local pattern=$1 expected=$2 label=$3 got=0
    for _ in $(seq 1 300); do
        got=$(grep -c "$pattern" "$ZPOND_LOG" 2>/dev/null || true)
        ((got >= expected)) && return 0
        kill -0 "$ZPOND_PID" 2>/dev/null || die "zponder exited while waiting for $label"
        sleep 0.1
    done
    die "$label: expected at least $expected matches, got $got"
}
wait_sql() {
    local sql=$1 expected=$2 label=$3 got=""
    for _ in $(seq 1 300); do
        got=$(sqlite3 "$DB" "$sql" 2>/dev/null || true)
        [[ "$got" == "$expected" ]] && return 0
        kill -0 "$ZPOND_PID" 2>/dev/null || die "zponder exited while waiting for $label"
        sleep 0.1
    done
    die "$label: expected '$expected', got '${got:-<none>}'"
}
wait_log_count 'WSS 订阅已激活' 1 'initial WSS subscription'
pass "HTTP catch-up switched to eth_subscribe(logs)"

send_ping() {
    local n=$1 label=$2 receipt
    receipt=$(cast send --private-key "$PK" --rpc-url "$RPC" --json "$ADDR" 'ping(uint256)' "$n")
    printf '%s\n' "$receipt" >"$WORK_DIR/$label.json"
}
for n in 1 2; do
    send_ping "$n" "before-$n"
done
wait_sql 'SELECT COUNT(*) FROM event_ping_Ping;' 2 'pre-disconnect events'
pass "live events indexed before disconnect"

kill -9 "$PROXY_PID" 2>/dev/null || die "failed to kill proxy"
wait "$PROXY_PID" 2>/dev/null || true
PROXY_PID=""
wait_log_count 'WSS 将在 .* 后重连' 1 'disconnect detection'
pass "proxy disconnect detected; reconnect backoff started"

for n in 3 4; do
    send_ping "$n" "during-$n"
done
wait_log_count 'WSS 连接失败（' 1 'failed reconnect while proxy is down'
pass "events produced while WebSocket proxy was down"

start_proxy
wait_log_count 'WSS 订阅已激活' 2 're-established WSS subscription'
pass "proxy restarted; eth_subscribe(logs) active again"

for n in 5 6; do
    send_ping "$n" "after-$n"
done
wait_sql 'SELECT COUNT(*) FROM event_ping_Ping;' 6 'all pre/during/post events'
pass "events after reconnect indexed"

python3 - "$DB" "$WORK_DIR" <<'PY' || die "a pre/during/post transaction is missing or duplicated"
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
for phase, values in (("before", (1, 2)), ("during", (3, 4)), ("after", (5, 6))):
    for n in values:
        receipt = json.load(open(f"{sys.argv[2]}/{phase}-{n}.json"))
        count = db.execute("SELECT COUNT(*) FROM event_ping_Ping WHERE tx_hash=?", (receipt["transactionHash"],)).fetchone()[0]
        assert count == 1, (phase, n, count)
PY
pass "every transaction before/during/after disconnect appears exactly once"
check_eq "duplicate (tx_hash,log_index,contract_address) groups" 0 \
    "$(sqlite3 "$DB" 'SELECT COUNT(*) FROM (SELECT tx_hash,log_index,contract_address FROM event_ping_Ping GROUP BY 1,2,3 HAVING COUNT(*)>1);')"
check_eq "raw_logs dead letters after reconnect" 0 "$(sqlite3 "$DB" 'SELECT COUNT(*) FROM raw_logs;')"

python3 - "$RPC" "$ADDR" "$DB" <<'PY' || die "database and canonical eth_getLogs tuple sets differ"
import json, sqlite3, sys, urllib.request
payload = {"jsonrpc":"2.0","id":1,"method":"eth_getLogs","params":[{"address":sys.argv[2],"fromBlock":"0x0","toBlock":"latest"}]}
request = urllib.request.Request(sys.argv[1], data=json.dumps(payload).encode(), headers={"Content-Type":"application/json"})
logs = json.load(urllib.request.urlopen(request))["result"]
chain = {(row["transactionHash"].lower(), int(row["logIndex"], 16), row["address"].lower()) for row in logs}
db = sqlite3.connect(sys.argv[3])
stored = {(row[0].lower(), row[1], row[2].lower()) for row in db.execute("SELECT tx_hash,log_index,contract_address FROM event_ping_Ping")}
assert stored == chain, {"missing": chain - stored, "extra": stored - chain}
assert len(chain) == 6, len(chain)
PY
pass "SQLite tuple set exactly matches six canonical eth_getLogs rows"
check_eq "WSS subscription activation count" 2 "$(grep -c 'WSS 订阅已激活' "$ZPOND_LOG")"

printf 'ALL WSS RECONNECT ASSERTIONS PASSED\n'
