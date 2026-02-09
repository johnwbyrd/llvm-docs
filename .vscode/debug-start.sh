#!/bin/bash
#
# Start MAME and LLDB for debugging MOS programs
#
# Usage: ./debug-start.sh [binary]
#
# Starts MAME with GDB stub on port 23946 and LLDB with MCP server on port 59999.
# Stop with: ./debug-stop.sh
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LLVM_MOS_DIR="$(dirname "$SCRIPT_DIR")"
LLDB="$LLVM_MOS_DIR/build/bin/lldb"
MAME="$HOME/git/mame/mame"
TEST_BINARY="${1:-$HOME/git/dwarf-torture/build/bin/nested_structs_O0}"

# Validate prerequisites
[[ -f "$TEST_BINARY" ]] || { echo "Error: Binary not found: $TEST_BINARY"; exit 1; }
[[ -x "$LLDB" ]] || { echo "Error: LLDB not found: $LLDB"; exit 1; }
[[ -x "$MAME" ]] || { echo "Error: MAME not found: $MAME"; exit 1; }
pgrep -f "mame.*zbcm6502.*debugger_port 23946" >/dev/null && { echo "Error: Already running. Run debug-stop.sh first."; exit 1; }

echo "Starting debug session: $TEST_BINARY"

# Start MAME
"$MAME" zbcm6502 -window -skip_gameinfo -debugger gdbstub -debug \
    -debugger_port 23946 -seconds_to_run 300 -elfload "$TEST_BINARY" \
    >/tmp/mame-debug.log 2>&1 &
echo $! >/tmp/mame-debug.pid
sleep 2
kill -0 "$(cat /tmp/mame-debug.pid)" 2>/dev/null || { echo "Error: MAME died"; cat /tmp/mame-debug.log; exit 1; }

# Create LLDB init script
LLDB_INIT=$(mktemp)
cat >"$LLDB_INIT" <<EOF
gdb-remote localhost:23946
protocol-server start MCP listen://localhost:59999
EOF

# Start LLDB (nohup + disown to fully detach)
nohup bash -c "sleep infinity | '$LLDB' --source '$LLDB_INIT' '$TEST_BINARY'" \
    >/tmp/lldb-debug.log 2>&1 &
echo $! >/tmp/lldb-debug.pid
disown

# Wait for MCP server
for _ in {1..25}; do
    nc -z localhost 59999 2>/dev/null && break
    sleep 0.2
done
nc -z localhost 59999 2>/dev/null || { echo "Error: MCP server not responding"; cat /tmp/lldb-debug.log; exit 1; }

rm -f "$LLDB_INIT"
echo "Ready. MCP server on localhost:59999. Stop with: ./debug-stop.sh"
