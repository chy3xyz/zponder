#!/usr/bin/env bash
# zponder Local Demo — End-to-End Example
#
# Starts an Anvil node, deploys an ERC20 token, runs zponder to index
# Transfer events, then queries both REST and GraphQL APIs.
#
# Prerequisites:
#   - Zig 0.16.0+ (zig build)
#   - Foundry (anvil + cast)
#   - sqlite3 (macOS: brew install sqlite3)
#
# Usage:
#   bash examples/local-demo/run.sh

set -euo pipefail
cd "$(dirname "$0")/../.."

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── cleanup ────────────────────────────────────────────────────────────────
cleanup() {
    echo ""
    echo -e "${YELLOW}Cleaning up...${NC}"
    kill $ZPOND_PID 2>/dev/null || true
    kill $ANVIL_PID 2>/dev/null || true
    wait $ZPOND_PID 2>/dev/null || true
    wait $ANVIL_PID 2>/dev/null || true
    rm -f demo_indexer.db demo_indexer.db-shm demo_indexer.db-wal
    echo -e "${GREEN}Done.${NC}"
}
trap cleanup EXIT INT TERM

# ── check prerequisites ────────────────────────────────────────────────────
command -v zig >/dev/null 2>&1 || { echo -e "${RED}zig not found${NC}"; exit 1; }
command -v anvil >/dev/null 2>&1 || { echo -e "${RED}anvil not found (install Foundry)${NC}"; exit 1; }
command -v cast >/dev/null 2>&1 || { echo -e "${RED}cast not found (install Foundry)${NC}"; exit 1; }

echo -e "${BOLD}${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║           zponder — Local Demo                             ║${NC}"
echo -e "${BOLD}${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"

# ── 1. Start Anvil ─────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}[1/6] Starting Anvil...${NC}"
anvil --port 8545 > /tmp/anvil-demo.log 2>&1 &
ANVIL_PID=$!
sleep 3

# Verify Anvil is ready
for i in $(seq 1 10); do
    if curl -s -X POST http://localhost:8545 \
        -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        2>/dev/null | grep -q '"result"'; then
        echo -e "  ${GREEN}Anvil ready (PID $ANVIL_PID)${NC}"
        break
    fi
    sleep 1
done

# ── 2. Deploy DemoToken ────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}[2/6] Compiling & deploying DemoToken ERC20...${NC}"
SOLC_OPTS="--abi --bin --optimize --overwrite"
solc $SOLC_OPTS examples/local-demo/DemoToken.sol -o /tmp/demo-build 2>&1 | tail -1

DEPLOYER_PK="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
BYTECODE=$(cat /tmp/demo-build/DemoToken.bin)

RESULT=$(cast send --private-key "$DEPLOYER_PK" \
    --rpc-url http://localhost:8545 \
    --create "$BYTECODE" "constructor(uint256)" 1000000 2>&1)

TOKEN_ADDR=$(echo "$RESULT" | grep contractAddress | awk '{print $2}')
echo -e "  ${GREEN}DemoToken deployed at $TOKEN_ADDR${NC}"

# ── 3. Generate transfers ──────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}[3/6] Sending transfer transactions...${NC}"

ACCT1="0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
ACCT2="0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
ACCT3="0x90F79bf6EB2c4f870365E785982E1f101E93b906"

TX1=$(cast send --private-key "$DEPLOYER_PK" --rpc-url http://localhost:8545 \
    "$TOKEN_ADDR" "transfer(address,uint256)" "$ACCT1" 1000000000000000000000 2>&1 | grep "^transactionHash" | awk '{print $2}')
echo -e "  Tx 1: deployer → acct1 (1000 DEMO)  ${GREEN}$TX1${NC}"

TX2=$(cast send --private-key "$DEPLOYER_PK" --rpc-url http://localhost:8545 \
    "$TOKEN_ADDR" "transfer(address,uint256)" "$ACCT2" 500000000000000000000 2>&1 | grep "^transactionHash" | awk '{print $2}')
echo -e "  Tx 2: deployer → acct2 (500 DEMO)   ${GREEN}$TX2${NC}"

TX3=$(cast send --private-key "$DEPLOYER_PK" --rpc-url http://localhost:8545 \
    "$TOKEN_ADDR" "transfer(address,uint256)" "$ACCT3" 100000000000000000000 2>&1 | grep "^transactionHash" | awk '{print $2}')
echo -e "  Tx 3: deployer → acct3 (100 DEMO)   ${GREEN}$TX3${NC}"

sleep 1

# ── 4. Build zponder ───────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}[4/6] Building zponder...${NC}"
zig build 2>&1 | tail -1
echo -e "  ${GREEN}Build complete${NC}"

# ── 5. Update config with deployed token address ───────────────────────────
echo ""
echo -e "${YELLOW}[5/6] Starting zponder...${NC}"
sed "s/0x5FbDB2315678afecb367f032d93F642f64180aa3/$TOKEN_ADDR/" \
    examples/local-demo/config.toml > /tmp/zponder-demo-config.toml

rm -f demo_indexer.db demo_indexer.db-shm demo_indexer.db-wal

nohup ./zig-out/bin/zponder -c /tmp/zponder-demo-config.toml > /tmp/zponder-demo.log 2>&1 &
ZPOND_PID=$!
sleep 5

# Check if zponder is alive
if ! kill -0 $ZPOND_PID 2>/dev/null; then
    echo -e "  ${RED}zponder failed to start. Log:${NC}"
    cat /tmp/zponder-demo.log
    exit 1
fi
echo -e "  ${GREEN}zponder started (PID $ZPOND_PID)${NC}"
echo -e "  REST API:    ${CYAN}http://localhost:9090${NC}"
echo -e "  GraphQL API: ${CYAN}http://localhost:9091/graphql${NC}"

# ── 6. Query APIs ──────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║  Query Results                                            ║${NC}"
echo -e "${BOLD}${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"

divider() {
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  $1${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

divider "GET /health (REST)"
curl -s http://localhost:9090/health | python3 -m json.tool 2>/dev/null || \
    curl -s http://localhost:9090/health

divider "GET /events/demo/Transfer?limit=3 (REST)"
curl -s "http://localhost:9090/events/demo/Transfer?limit=3&order=desc" | \
    python3 -m json.tool 2>/dev/null || \
    curl -s "http://localhost:9090/events/demo/Transfer?limit=3&order=desc"

divider "GET /sync_state (REST)"
curl -s http://localhost:9090/sync_state | python3 -m json.tool 2>/dev/null || \
    curl -s http://localhost:9090/sync_state

divider "POST /graphql { contracts } (GraphQL)"
curl -s -X POST http://localhost:9091/graphql \
    -H 'Content-Type: application/json' \
    -d '{"query":"{ contracts { name address chain fromBlock events } }"}' | \
    python3 -m json.tool 2>/dev/null

divider "POST /graphql { syncStates } (GraphQL)"
curl -s -X POST http://localhost:9091/graphql \
    -H 'Content-Type: application/json' \
    -d '{"query":"{ syncStates { contractName currentBlock status } }"}' | \
    python3 -m json.tool 2>/dev/null

divider "POST /graphql { latestEvents } (GraphQL)"
curl -s -X POST http://localhost:9091/graphql \
    -H 'Content-Type: application/json' \
    -d '{"query":"{ latestEvents(contract: \"demo\", event: \"Transfer\", limit: 2) { blockNumber transactionHash eventName fields { key value } } }"}' | \
    python3 -m json.tool 2>/dev/null

divider "POST /graphql { contractCall } (GraphQL)"
echo "totalSupply():"
curl -s -X POST http://localhost:9091/graphql \
    -H 'Content-Type: application/json' \
    -d "{\"query\":\"{ contractCall(contract: \\\"demo\\\", method: \\\"totalSupply()\\\") }\"}" | \
    python3 -m json.tool 2>/dev/null

echo ""
echo "balanceOf($ACCT1):"
curl -s -X POST http://localhost:9091/graphql \
    -H 'Content-Type: application/json' \
    -d "{\"query\":\"{ contractCall(contract: \\\"demo\\\", method: \\\"balanceOf(address)\\\", args: [\\\"$ACCT1\\\"]) }\"}" | \
    python3 -m json.tool 2>/dev/null

divider "GET /version (REST)"
curl -s http://localhost:9090/version | python3 -m json.tool 2>/dev/null || \
    curl -s http://localhost:9090/version

echo ""
echo -e "${GREEN}${BOLD}Demo complete. All APIs are working.${NC}"
echo ""
echo -e "  Playground: ${CYAN}http://localhost:9091/graphql/playground${NC}"
echo -e "  Press Ctrl+C to stop."
echo ""

# Keep running until Ctrl+C
while true; do sleep 1; done
