#!/bin/bash
#
# Stop MAME and LLDB debug session
#

echo "Stopping debug session..."

# Kill LLDB and children
if [[ -f /tmp/lldb-debug.pid ]]; then
    pid=$(cat /tmp/lldb-debug.pid)
    pkill -9 -P "$pid" 2>/dev/null
    kill -9 "$pid" 2>/dev/null
    rm -f /tmp/lldb-debug.pid
fi

# Kill MAME
if [[ -f /tmp/mame-debug.pid ]]; then
    kill -9 "$(cat /tmp/mame-debug.pid)" 2>/dev/null
    rm -f /tmp/mame-debug.pid
fi

# Clean up strays
pkill -9 -f "mame.*zbcm6502.*debugger_port 23946" 2>/dev/null
pkill -9 -f "sleep infinity" 2>/dev/null

echo "Done."
