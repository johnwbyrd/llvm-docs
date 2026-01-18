# LLDB ProcessSimulator Plugin

## Overview

Implement an LLDB Process plugin that provides GDB's `target sim` functionality - a built-in simulator that LLDB can drive directly without a separate process or network protocol.

**Goal:** `(lldb) target sim program.elf` launches the emulator inside LLDB, enabling breakpoints, stepping, memory inspection, and register access through standard LLDB commands.

## Design Principles

1. **Generic from the start** - The Context interface works for any target, not just MOS
2. **Breakpoints in Context** - The emulator handles breakpoint checking internally
3. **Register access via byte buffer** - Uses LLDB's `DynamicRegisterInfo` + `RegisterContextMemory` pattern
4. **Imaginary registers included** - Compiler-generated zero-page registers exposed through register interface

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│ LLDB                                                    │
│  ├── ProcessSimulator (new plugin)                      │
│  │    └── ThreadSimulator                               │
│  │         └── RegisterContextSimulator                 │
│  └── existing: ABISysV_mos, DynamicRegisterInfo        │
└────────────────────┬────────────────────────────────────┘
                     │ uses
┌────────────────────▼────────────────────────────────────┐
│ llvm/include/llvm/Emulator/                             │
│  ├── Context.h (extended with debug interface)          │
│  ├── System.h                                           │
│  └── Memory.h                                           │
└────────────────────┬────────────────────────────────────┘
                     │ implemented by
┌────────────────────▼────────────────────────────────────┐
│ Target-specific (e.g., MOS)                             │
│  └── MOSContext (existing, extends Context)             │
└─────────────────────────────────────────────────────────┘
```

## Context Interface Extensions

Add to `llvm/include/llvm/Emulator/Context.h`:

```cpp
//===--------------------------------------------------------------------===//
// Debug Interface (for LLDB integration)
//===--------------------------------------------------------------------===//

/// Register descriptor for debugger integration.
struct RegisterDesc {
  const char *Name;
  uint32_t ByteSize;
  uint32_t ByteOffset;  // Offset in register state buffer
  uint32_t DWARFNumber;
  uint32_t LLDBKind;    // lldb_regnum_generic_*
};

/// Get register descriptors. Called after ELF load to include imaginary registers.
/// Returns vector of descriptors (may include dynamically discovered registers).
virtual std::vector<RegisterDesc> getRegisterInfo() const = 0;

/// Get total size of register state buffer in bytes.
virtual size_t getRegisterStateSize() const = 0;

/// Read all registers into buffer. Returns bytes written.
virtual size_t readRegisters(void *Buffer, size_t Size) const = 0;

/// Write all registers from buffer. Returns bytes read.
virtual size_t writeRegisters(const void *Buffer, size_t Size) = 0;

//===--------------------------------------------------------------------===//
// Breakpoint Support
//===--------------------------------------------------------------------===//

/// Add a breakpoint at the given address.
virtual void addBreakpoint(uint64_t Addr) = 0;

/// Remove a breakpoint at the given address.
virtual void removeBreakpoint(uint64_t Addr) = 0;

/// Check if a breakpoint exists at the given address.
virtual bool hasBreakpoint(uint64_t Addr) const = 0;

/// Clear all breakpoints.
virtual void clearBreakpoints() = 0;

/// Stop reason after step() returns.
enum class StopReason {
  None,           // Still running
  Breakpoint,     // Hit a breakpoint
  Step,           // Single step completed
  Halted,         // BRK or halt() called
  Error           // Execution error
};

/// Get the reason execution stopped.
virtual StopReason getStopReason() const = 0;

/// Get address that caused the stop (for breakpoints).
virtual uint64_t getStopAddress() const { return getPC(); }
```

## Files to Create

### 1. `lldb/source/Plugins/Process/sim/ProcessSimulator.h`

```cpp
class ProcessSimulator : public Process {
public:
  // Plugin interface
  static lldb::ProcessSP CreateInstance(lldb::TargetSP target_sp,
                                         lldb::ListenerSP listener_sp,
                                         const FileSpec *crash_file_path,
                                         bool can_connect);
  static void Initialize();
  static void Terminate();
  static llvm::StringRef GetPluginNameStatic() { return "sim"; }

  // Process interface
  bool CanDebug(lldb::TargetSP target_sp, bool plugin_specified_by_name) override;
  Status DoLaunch(Module *exe_module, ProcessLaunchInfo &launch_info) override;
  Status DoResume(lldb::RunDirection direction) override;
  Status DoHalt(bool &caused_stop) override;
  Status DoDestroy() override;
  void RefreshStateAfterStop() override;
  bool IsAlive() override;

  // Memory
  size_t DoReadMemory(lldb::addr_t addr, void *buf, size_t size, Status &error) override;
  size_t DoWriteMemory(lldb::addr_t addr, const void *buf, size_t size, Status &error) override;

  // Breakpoints
  Status EnableBreakpointSite(BreakpointSite *bp_site) override;
  Status DisableBreakpointSite(BreakpointSite *bp_site) override;

  // Threads
  bool DoUpdateThreadList(ThreadList &old, ThreadList &new_list) override;

private:
  std::unique_ptr<llvm::emu::Context> m_context;
  std::unique_ptr<llvm::emu::System> m_system;
};
```

### 2. `lldb/source/Plugins/Process/sim/ProcessSimulator.cpp`

Implementation that:
- Creates target-specific Context via TargetRegistry
- Loads ELF sections into System memory
- Delegates execution to Context::step()
- Converts Context::StopReason to LLDB stop events

### 3. `lldb/source/Plugins/Process/sim/ThreadSimulator.h/cpp`

Single-threaded for now. Creates RegisterContextSimulator.

### 4. `lldb/source/Plugins/Process/sim/RegisterContextSimulator.h/cpp`

Uses Context::getRegisterInfo() to build DynamicRegisterInfo.
Uses Context::readRegisters()/writeRegisters() for state access.

### 5. `lldb/source/Plugins/Process/sim/CMakeLists.txt`

```cmake
add_lldb_library(lldbPluginProcessSimulator PLUGIN
  ProcessSimulator.cpp
  ThreadSimulator.cpp
  RegisterContextSimulator.cpp

  LINK_LIBS
    lldbCore
    lldbTarget
    LLVMEmulator
    LLVMMC
    LLVMObject
)
```

## Files to Modify

### 1. `llvm/include/llvm/Emulator/Context.h`

Add the debug interface methods described above.

### 2. `llvm/lib/Target/MOS/MCTargetDesc/MOSContext.h/cpp`

Implement the new Context methods:
- `getRegisterInfo()` - return vector of RegisterDesc for A, X, Y, S, PC, flags, plus imaginary registers
- `getRegisterStateSize()` - return size needed for all registers
- `readRegisters()`/`writeRegisters()` - pack/unpack register state
- `addBreakpoint()`/`removeBreakpoint()` - manage breakpoint set
- Modify `step()` to check breakpoints and set StopReason

### 3. `lldb/source/Plugins/Process/CMakeLists.txt`

Add `add_subdirectory(sim)`

### 4. `lldb/source/Plugins/Plugins.def`

Register the plugin.

## Implementation Order

### Phase 1: Context Interface

1. Add debug interface to `Context.h` (pure virtual methods)
2. Implement in MOSContext
3. Add breakpoint checking to MOSContext::step()
4. Test with existing llvm-mc --run to verify no regression

### Phase 2: Minimal Process Plugin

1. Create ProcessSimulator with just DoLaunch + IsAlive
2. Register plugin
3. Verify `target sim` command appears in LLDB

### Phase 3: Execution Control

1. Implement DoResume (calls Context::step() in loop)
2. Implement DoHalt (sets flag checked by step loop)
3. Implement breakpoint enable/disable
4. Test: set breakpoint, run, verify stop

### Phase 4: Memory & Registers

1. Implement DoReadMemory/DoWriteMemory (delegate to System)
2. Implement RegisterContextSimulator
3. Test: `register read`, `memory read`

### Phase 5: Integration

1. Verify source-level debugging works with DWARF
2. Test stepping (step, next, finish)
3. Test variable inspection

## UX

```
$ lldb program.elf
(lldb) target sim
(lldb) breakpoint set -n main
(lldb) run
Process 1 stopped
* thread #1, stop reason = breakpoint 1.1
    frame #0: main at program.c:10
(lldb) register read
       a = 0x00
       x = 0x00
       y = 0x00
      pc = 0x0200
(lldb) step
(lldb) print counter
(int) $0 = 42
```

Alternative invocation:
```
$ lldb
(lldb) target sim program.elf
```

Both workflows are supported - be generous in what we accept.

## Design Decisions

1. **UX: Be generous in what we accept**
   - `target sim program.elf` - loads and launches
   - `file program.elf` then `target sim` - also works
   - Infer architecture from ELF's e_machine field

2. **Imaginary registers via register interface**
   - The Context's getRegisterInfo() includes imaginary registers (__rc0, __rs0, etc.)
   - MOSContext discovers these from ELF symbols at load time
   - This means getRegisterInfo() is called after ELF load, not at construction

3. **Thread model**: Single thread (tid=1) for now. Interface allows multi-thread later.

4. **Cycle limiting**: Default max-cycles during `run` to prevent hangs. Can be overridden.

## Comparison with Current Approach

| Aspect | Current (MAME + GDB stub) | ProcessSimulator |
|--------|---------------------------|------------------|
| Separate process | Yes (MAME) | No (in-process) |
| Network protocol | GDB remote | Direct API calls |
| Startup time | Slow (spawn MAME) | Fast |
| Memory access | Serialized over socket | Direct pointer |
| Register access | Packet round-trip | Direct read |
| Maintenance | Two codebases | Single codebase |

## Dependencies

- `LLVMEmulator` library must be accessible from LLDB
- May need to move some headers to `llvm/include/llvm/Emulator/` if not already public
