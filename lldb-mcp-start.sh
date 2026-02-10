#!/bin/bash
# lldb-mcp-start.sh - Start LLDB with MCP server
#
# Usage: ./lldb-mcp-start.sh [port]
#
# Environment variables:
#   LLDB_PATH - Path to lldb binary (default: lldb)

PORT="${1:-59999}"
LLDB="${LLDB_PATH:-lldb}"

# Kill anything using the port
fuser -k "$PORT/tcp" 2>/dev/null || true
pkill -9 -f lldb 2>/dev/null || true
sleep 2

# Start the server
tail -f /dev/null | "$LLDB" -o "protocol-server start MCP listen://localhost:$PORT" &

# Wait and verify
sleep 3
if ss -tlnp 2>/dev/null | grep -q ":$PORT"; then
    echo "MCP server listening on port $PORT"
else
    echo "ERROR: Server failed to start"
    exit 1
fi
