# Debugging with LLDB MCP Server

## Prerequisites

- LLDB built with MCP support
- `nc` (netcat)

## Starting the Server

**Step 1: Kill anything using the port**
```bash
fuser -k 59999/tcp 2>/dev/null
pkill -9 -f lldb 2>/dev/null
sleep 2
```

**Step 2: Start the server**
```bash
tail -f /dev/null | /path/to/lldb -o "protocol-server start MCP listen://localhost:59999" &
```

**Step 3: Wait and verify**
```bash
sleep 3
ss -tlnp | grep 59999
```

You should see:
```
LISTEN 0 5 127.0.0.1:59999 0.0.0.0:* users:(("lldb",pid=XXXXX,fd=8))
```

## Sending Commands

```bash
export LLDB_MCP_PORT=59999

./lldb-mcp-cmd.sh "target list"
./lldb-mcp-cmd.sh "target create /path/to/executable"
./lldb-mcp-cmd.sh "breakpoint set -n main"
./lldb-mcp-cmd.sh "process launch --plugin simulator"
./lldb-mcp-cmd.sh "bt"
./lldb-mcp-cmd.sh "register read"
./lldb-mcp-cmd.sh "frame variable"
```

## Stopping the Server

```bash
pkill -9 -f lldb
```

## Using from Claude Code

When running from Claude Code's bash tool, Step 2 must use `run_in_background: true`:

```
<Bash run_in_background="true">
tail -f /dev/null | /path/to/lldb -o "protocol-server start MCP listen://localhost:59999" 2>&1
</Bash>
```

Then wait and verify in a separate command.

## Common Commands

| Command | Description |
|---------|-------------|
| `target create <path>` | Load executable |
| `breakpoint set -n <func>` | Breakpoint by function |
| `breakpoint set -f <file> -l <line>` | Breakpoint by location |
| `process launch --plugin simulator` | Launch MOS simulator |
| `process attach --pid <pid>` | Attach to process |
| `continue` | Resume |
| `step` / `next` | Step into / over |
| `bt` | Backtrace |
| `frame variable` | Local variables |
| `register read` | Registers |
| `memory read <addr> -c <n>` | Read memory |
| `process interrupt` | Stop |
| `quit` | Exit |
