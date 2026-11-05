#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../../../.."
REPO_ROOT="$PWD"
DEMO_DIR="$REPO_ROOT/examples/local-demo/reorg-wss-demo"
export PATH="$HOME/.foundry/bin:$HOME/.cargo/bin:$PATH"

ANVIL_PORT="${ANVIL_PORT:-8621}"
HTTP_PORT="${HTTP_PORT:-8622}"
RPC="http://127.0.0.1:$ANVIL_PORT"
WORK_DIR=$(mktemp -d "/tmp/zponder-reorg-e2e.XXXXXX")
DB="$WORK_DIR/reorg.db"
ZPOND_LOG="$WORK_DIR/zponder.log"
ANVIL_LOG="$WORK_DIR/anvil.log"
PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
ANVIL_PID=""
ZPOND_PID=""

pass() { printf 'PASS %s\n' "$1"; }
die() {
    printf 'FAIL %s\n' "$1" >&2
    printf 'work dir: %s\n' "$WORK_DIR" >&2
    tail -40 "$ZPOND_LOG" 2>/dev/null >&2 || true
    exit 1
}
check_eq() {
    [[ "$2" == "$3" ]] || die "$1: expected '$2', got '$3'"
    pass "$1 = $3"
}
check_ne() {
    [[ "$2" != "$3" ]] || die "$1: both values were '$2'"
    pass "$1 ($2 != $3)"
}
cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    for pid in "$ZPOND_PID" "$ANVIL_PID"; do
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    done
    sleep 0.2
    for pid in "$ZPOND_PID" "$ANVIL_PID"; do
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
python3 - "$ANVIL_PORT" "$HTTP_PORT" <<'PY' || die "ANVIL_PORT/HTTP_PORT must be free"
import socket, sys
for port in map(int, sys.argv[1:]):
    with socket.socket() as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("127.0.0.1", port))
PY

printf 'reorg e2e work dir: %s\n' "$WORK_DIR"
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
    if cast block-number --rpc-url "$RPC" >/dev/null 2>&1; then
        break
    fi
    kill -0 "$ANVIL_PID" 2>/dev/null || die "anvil exited"
    sleep 0.1
done
cast block-number --rpc-url "$RPC" >/dev/null 2>&1 || die "anvil did not become ready"
pass "anvil ready on :$ANVIL_PORT"

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

send_ping() {
    local n=$1 label=$2 receipt
    receipt=$(cast send --private-key "$PK" --rpc-url "$RPC" --json "$ADDR" 'ping(uint256)' "$n")
    printf '%s\n' "$receipt" >"$WORK_DIR/$label.json"
    python3 -c 'import json,sys; print(json.load(sys.stdin)["transactionHash"])' <<<"$receipt"
}

KEEP_TX=$(send_ping 0 keep)
SNAPSHOT=$(cast rpc evm_snapshot --rpc-url "$RPC")
SNAPSHOT_BLOCK=$(cast block-number --rpc-url "$RPC")
FORK_BLOCK=$((SNAPSHOT_BLOCK + 1))
for n in 1 2 3; do
    send_ping "$n" "old-$n" >/dev/null
done
OLD_TIP=$(cast block-number --rpc-url "$RPC")
OLD_HASH=$(cast block "$FORK_BLOCK" --json --rpc-url "$RPC" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hash"])')
pass "canonical branch before reorg: fork=$FORK_BLOCK tip=$OLD_TIP"

cat >"$WORK_DIR/config.toml" <<EOF
[global]
log_level = "info"
log_file = ""
snapshot_interval = 0
chain = "anvil"
track_blocks = true

[rpc]
url = "$RPC"
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
block_batch_size = 1
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
if [[ "${SYNC_TIP_WORKAROUND:-1}" == "1" ]]; then
    cast rpc evm_mine --rpc-url "$RPC" >/dev/null
fi

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
wait_sql 'SELECT COUNT(*) FROM event_ping_Ping;' 4 'initial Ping rows'
wait_sql "SELECT last_synced_block FROM sync_state WHERE contract_address='$ADDR';" "$((OLD_TIP + 1))" 'initial cursor'
pass "initial canonical events indexed"

sqlite3 "$DB" <<'SQL'
CREATE TABLE reorg_cursor_audit (
    contract_address TEXT NOT NULL,
    last_synced_block INTEGER NOT NULL,
    status TEXT NOT NULL,
    observed_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
CREATE TRIGGER capture_reorg_cursor
AFTER UPDATE OF last_synced_block, status ON sync_state
WHEN NEW.status = 'reorg_rollback'
BEGIN
    INSERT INTO reorg_cursor_audit(contract_address, last_synced_block, status)
    VALUES (NEW.contract_address, NEW.last_synced_block, NEW.status);
END;
SQL

cast rpc evm_revert "$SNAPSHOT" --rpc-url "$RPC" | python3 -c 'import json,sys; assert json.load(sys.stdin) is True' || die "evm_revert failed"
for n in 101 102 103; do
    send_ping "$n" "new-$n" >/dev/null
done
cast rpc evm_mine --rpc-url "$RPC" >/dev/null
cast rpc evm_mine --rpc-url "$RPC" >/dev/null
NEW_TIP=$(cast block-number --rpc-url "$RPC")
NEW_HASH=$(cast block "$FORK_BLOCK" --json --rpc-url "$RPC" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hash"])')
check_ne "real fork changed block $FORK_BLOCK hash" "$OLD_HASH" "$NEW_HASH"

wait_sql 'SELECT COUNT(*) FROM event_ping_Ping;' 4 'post-reorg exact event count'
wait_sql "SELECT last_synced_block FROM sync_state WHERE contract_address='$ADDR';" "$((NEW_TIP + 1))" 'post-reorg advanced cursor'

check_eq "rollback cursor audited at fork" "$FORK_BLOCK" \
    "$(sqlite3 "$DB" "SELECT last_synced_block FROM reorg_cursor_audit WHERE contract_address='$ADDR' AND status='reorg_rollback' ORDER BY observed_at DESC LIMIT 1;")"
check_eq "pre-fork Ping(0) retained exactly once" 1 \
    "$(sqlite3 "$DB" "SELECT COUNT(*) FROM event_ping_Ping WHERE block_number=$SNAPSHOT_BLOCK AND tx_hash='$KEEP_TX';")"
OLD_TX_COUNT=$(python3 - "$DB" "$WORK_DIR" <<'PY'
import json, sqlite3, sys
hashes = [json.load(open(f"{sys.argv[2]}/old-{n}.json"))["transactionHash"] for n in (1, 2, 3)]
db = sqlite3.connect(sys.argv[1])
print(db.execute(f"SELECT COUNT(*) FROM event_ping_Ping WHERE tx_hash IN ({','.join('?' * len(hashes))})", hashes).fetchone()[0])
PY
)
check_eq "reorged old transactions deleted" 0 "$OLD_TX_COUNT"

python3 - "$DB" "$WORK_DIR" <<'PY' || die "replacement events are not unique at their original heights"
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
for n in (101, 102, 103):
    receipt = json.load(open(f"{sys.argv[2]}/new-{n}.json"))
    rows = db.execute("SELECT evt_n FROM event_ping_Ping WHERE tx_hash=? AND block_number=?", (receipt["transactionHash"], int(receipt["blockNumber"], 16))).fetchall()
    assert len(rows) == 1 and int(rows[0][0], 16) == n, (n, rows)
PY
pass "replacement Ping events appear exactly once at fork heights"
check_eq "duplicate (tx_hash,log_index,contract_address) groups" 0 \
    "$(sqlite3 "$DB" 'SELECT COUNT(*) FROM (SELECT tx_hash,log_index,contract_address FROM event_ping_Ping GROUP BY 1,2,3 HAVING COUNT(*)>1);')"
check_eq "stored fork hash replaced by canonical hash" "$NEW_HASH" \
    "$(sqlite3 "$DB" "SELECT block_hash FROM block_hashes WHERE contract_address='$ADDR' AND block_number=$FORK_BLOCK;")"
check_eq "raw_logs dead letters" 0 "$(sqlite3 "$DB" 'SELECT COUNT(*) FROM raw_logs;')"

CHAIN_LOGS=$(python3 - "$RPC" "$ADDR" <<'PY'
import json, sys, urllib.request
payload = {"jsonrpc":"2.0","id":1,"method":"eth_getLogs","params":[{"address":sys.argv[2],"fromBlock":"0x0","toBlock":"latest"}]}
request = urllib.request.Request(sys.argv[1], data=json.dumps(payload).encode(), headers={"Content-Type":"application/json"})
print(len(json.load(urllib.request.urlopen(request))["result"]))
PY
)
check_eq "SQLite event count equals canonical eth_getLogs count" "$CHAIN_LOGS" \
    "$(sqlite3 "$DB" 'SELECT COUNT(*) FROM event_ping_Ping;')"
check_eq "cursor advanced after rollback" "$((NEW_TIP + 1))" \
    "$(sqlite3 "$DB" "SELECT last_synced_block FROM sync_state WHERE contract_address='$ADDR';")"

printf 'ALL REORG ASSERTIONS PASSED\n'
