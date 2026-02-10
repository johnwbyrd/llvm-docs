#!/bin/bash
# lldb-mcp-cmd.sh - Send commands to LLDB MCP server
#
# Usage: ./lldb-mcp-cmd.sh <lldb-command>
#
# Examples:
#   ./lldb-mcp-cmd.sh "bt"
#   ./lldb-mcp-cmd.sh "register read"
#   ./lldb-mcp-cmd.sh "frame variable"
#   ./lldb-mcp-cmd.sh "memory read 0x1000 -c 16"

set -e

COMMAND="${1:?Usage: $0 <lldb-command>}"
PORT="${LLDB_MCP_PORT:-59999}"

# Check if server is running
if ! ss -tlnp 2>/dev/null | grep -q ":$PORT" && ! netstat -tlnp 2>/dev/null | grep -q ":$PORT"; then
    echo "ERROR: No MCP server listening on port $PORT"
    echo "Start one with: ./lldb-mcp-start.sh <executable>"
    exit 1
fi

# Generate a unique request ID
REQUEST_ID="$(date +%s%N)"

# Send initialize (required for each connection)
INIT_REQUEST='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"lldb-mcp-cmd","version":"1.0"}}}'

# Send the command
CMD_REQUEST=$(cat <<EOF
{"jsonrpc":"2.0","id":$REQUEST_ID,"method":"tools/call","params":{"name":"command","arguments":{"command":"$COMMAND"}}}
EOF
)

# Send both requests and capture response
RESPONSE=$(echo -e "${INIT_REQUEST}\n${CMD_REQUEST}" | nc -w3 localhost "$PORT" 2>/dev/null)

# Extract just the command response (second JSON object)
CMD_RESPONSE=$(echo "$RESPONSE" | grep "\"id\":$REQUEST_ID" | head -1)

if [ -z "$CMD_RESPONSE" ]; then
    echo "ERROR: No response from MCP server"
    echo "Raw response: $RESPONSE"
    exit 1
fi

# Check for error
if echo "$CMD_RESPONSE" | grep -q '"isError":true'; then
    # Extract error message
    ERROR_MSG=$(echo "$CMD_RESPONSE" | sed 's/.*"text":"\([^"]*\)".*/\1/' | sed 's/\\n/\n/g')
    echo "ERROR: $ERROR_MSG"
    exit 1
fi

# Extract and print the result text
RESULT=$(echo "$CMD_RESPONSE" | sed 's/.*"text":"\([^"]*\)".*/\1/' | sed 's/\\n/\n/g')
echo "$RESULT"
