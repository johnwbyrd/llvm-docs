# LLDB ProcessSimulator Plugin

## Problem

We want to debug emulated code using LLDB without requiring a separate emulator process or network protocol. The emulator should run in-process, providing fast memory/register access and enabling features like reverse debugging.

## Goal

```
(lldb) target create program.elf
(lldb) process launch --plugin simulator
```

This launches the emulator inside LLDB, enabling breakpoints, watchpoints, stepping, and memory/register inspection through standard LLDB commands.

---

## Design Principles

1. **Single Source of Truth** - All debugging state lives in `emu::System`, not duplicated in LLDB
2. **System owns debugging primitives** - Breakpoints, watchpoints, stop reasons
3. **Context owns per-CPU state** - Registers, PC, instruction execution
4. **ProcessSimulator is a stateless adapter** - Delegates everything to System
5. **Target-agnostic** - ProcessSimulator knows `emu::System` and `emu::Context`, never `MOS::Context`

---

## Architecture

```
LLDB
├── ProcessSimulator (new) ─────────────► emu::System
│   └── One ThreadSimulator per CPU      │
│       └── RegisterContextSimulator     │
│                                        │
                                         ▼
                              ┌─────────────────────┐
                              │    emu::System      │
                              │  - breakpoints      │
                              │  - watchpoints      │
                              │  - stop reasons     │
                              │  - memory routing   │
                              └─────────────────────┘
                                         │
                              ┌──────────┼──────────┐
                              ▼          ▼          ▼
                         emu::Context  emu::Context  emu::Device
                          (CPU 0)      (CPU 1...)   (Memory, etc.)
```

### Responsibility Boundaries

| Component | Owns | Does NOT Own |
|-----------|------|--------------|
| `emu::System` | Breakpoints, watchpoints, stop reasons, memory routing | Per-CPU registers |
| `emu::Context` | Registers, PC, flags, instruction execution | Breakpoints, watchpoints |
| `ProcessSimulator` | LLDB ↔ System translation | Any debugging state |

---

## Key Design Decisions

### How does ProcessSimulator create a target-specific emulator?

Use LLVM's `TargetRegistry` pattern (same as `DisassemblerLLVMC`):

1. Get triple from LLDB's `Target::GetArchitecture()`
2. Look up LLVM Target via `TargetRegistry::lookupTarget()`
3. Create MC infrastructure (MCRegisterInfo, MCAsmInfo, MCSubtargetInfo, MCContext)
4. Call `Target::createEmulator()` which returns abstract `emu::Context*`

This keeps ProcessSimulator completely target-agnostic. MOS-specific code stays in `llvm/lib/Target/MOS/`.

**Reference:** `llvm/include/llvm/MC/TargetRegistry.h` for `createEmulator()` signature.

### How do breakpoints work?

LLDB calls `ProcessSimulator::EnableBreakpointSite()` with an address. ProcessSimulator delegates to `System::addBreakpoint()`. When `System::run()` executes, it checks breakpoints before each instruction and sets a stop reason if hit.

### How do stop reasons propagate?

1. `System::run()` returns when execution stops (breakpoint, halt, error)
2. `System::getStopReason()` and `getStopAddress()` report why
3. `ThreadSimulator::CalculateStopInfo()` translates to LLDB's `StopInfo`

**Stop reason mapping:**

| emu::System::StopReason | LLDB StopInfo |
|-------------------------|---------------|
| Breakpoint | `StopInfo::CreateStopReasonWithBreakpointSiteID()` |
| Watchpoint | `StopInfo::CreateStopReasonWithWatchpointID()` |
| SingleStep | `StopInfo::CreateStopReasonToTrace()` |
| Halted | Set process state to `eStateExited` |
| Error | Set process state to `eStateCrashed` |

**Reference:** `lldb/include/lldb/Target/StopInfo.h:140-162` for factory methods.

### How does register access work?

`RegisterContextSimulator` calls `emu::Context::readRegister()` and `writeRegister()` directly. Register numbers use DWARF numbering, which the emulator already supports.

No memory indirection - registers live as C++ members in the Context.

### How does ELF loading work?

In `DoLaunch()`:
1. Get `ObjectFile` from the module
2. Iterate `SectionList`
3. Copy each section's contents into `emu::Memory` via `writeBlock()`
4. Call `Context::reset()` to initialize CPU state

**Entry point handling varies by architecture:**
- MOS: `reset()` reads the reset vector from 0xFFFC, no explicit PC set needed
- Other architectures: May need `setPC(obj->GetEntryPointAddress())` after reset

### How does single-stepping work?

LLDB calls `DoResume()` with step information available via `GetThreadList()`. For single-step:
1. Call `Context::step()` once instead of `System::run()`
2. Set stop reason to `SingleStep`
3. Return immediately

For continue, call `System::run()` which executes until breakpoint/halt.

### How does the plugin lifecycle work?

LLDB plugins follow this pattern:
- `Initialize()` - Called once at LLDB startup, registers plugin with `PluginManager`
- `CreateInstance()` - Called when user requests this plugin, returns new ProcessSimulator
- `Terminate()` - Called at LLDB shutdown, unregisters plugin

`CreateInstance()` receives the Target and Listener. It should check if an emulator exists for the target's architecture before creating the process.

### When should CanDebug() return true?

`CanDebug()` should return true when:
1. The user explicitly selected the plugin (`--plugin simulator`), OR
2. The target architecture has a registered emulator AND no better option exists

For initial implementation, require explicit selection. Auto-selection can come later.

### What's the threading model?

`DoResume()` should be synchronous for simplicity:
1. Call `System::run()` (blocks until stop)
2. Set process state based on stop reason
3. Return

LLDB handles the async wrapper. No need for separate emulator threads.

---

## Files to Create

```
lldb/source/Plugins/Process/Simulator/
├── CMakeLists.txt
├── ProcessSimulator.h/.cpp      # Process subclass, owns System
├── ThreadSimulator.h/.cpp       # Thread subclass, wraps Context
└── RegisterContextSimulator.h/.cpp  # RegisterContext, calls Context::readRegister()
```

Also modify: `lldb/source/Plugins/Process/CMakeLists.txt` to add subdirectory.

---

## Required emu::System Interface

System needs these capabilities (most already exist):

**Breakpoints:** `addBreakpoint()`, `removeBreakpoint()`, `hasBreakpoint()`

**Watchpoints:** `addWatchpoint()`, `removeWatchpoint()` with read/write/readwrite types

**Stop reasons:** `getStopReason()`, `getStopAddress()`, `getStoppedContext()`, `clearStopReason()`

**Execution:** `run()` that stops on breakpoint/watchpoint/halt/error

**Memory:** `read()`, `write()` that route through devices

**Memory sizing:** Use `Context::getAddressBits()` to determine address space size. For MOS (16-bit), create 64KB memory. For 32-bit+ architectures, may need sparse memory or different approach.

---

## Required emu::Context Interface

Context needs these capabilities (most already exist):

**Execution:** `step()`, `reset()`, `isHalted()`, `getExitCode()`

**State:** `getPC()`, `setPC()`, `getCycles()`, `getAddressBits()`

**Register access:** `getNumRegisters()`, `readRegister()`, `writeRegister()` using DWARF numbers

---

## Implementation Order

1. **Verify emu::System/Context have required methods** - Check existing headers
2. **Create ProcessSimulator skeleton** - Plugin registration, `CanDebug()`, `CreateInstance()`
3. **Implement emulator initialization** - MC infrastructure setup, `createEmulator()` call
4. **Implement ELF loading** - Section iteration and memory population
5. **Create ThreadSimulator** - Thread wrapper with `CalculateStopInfo()`
6. **Create RegisterContextSimulator** - Direct register access
7. **Implement DoResume()** - Call `System::run()`, handle stop reasons
8. **Implement breakpoints** - `EnableBreakpointSite()` → `System::addBreakpoint()`
9. **Test with simple program** - Verify basic debugging works

---

## References

**LLDB Process plugins to study:**
- `lldb/source/Plugins/Process/minidump/` - Post-mortem debugging, no live process
- `lldb/source/Plugins/Process/scripted/` - Synthetic process, custom memory/registers

**LLVM Target registration:**
- `llvm/include/llvm/MC/TargetRegistry.h` - `createEmulator()` factory pattern
- `lldb/source/Plugins/Disassembler/LLVMC/DisassemblerLLVMC.cpp` - How to get LLVM Target from triple

**Emulator framework:**
- `llvm/include/llvm/Emulator/System.h` - System interface
- `llvm/include/llvm/Emulator/Context.h` - Context interface
- `llvm/tools/llvm-emu/llvm-emu.cpp` - Example of setting up System/Context/Memory

---

## Future Work (Out of Scope)

- **Reverse debugging** - Undo journal for `reverse-step`
- **Semihosting** - File I/O passthrough
- **Multi-CPU synchronization** - Clock-based scheduling
- **Source-level debugging** - Should work automatically if registers/memory work correctly
