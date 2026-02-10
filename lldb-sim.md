# LLDB ProcessSimulator Plugin

## Status: Working

The ProcessSimulator plugin is implemented and functional. It runs the llvm-mos emulator in-process for debugging MOS 6502 code (and other architectures with registered emulators).

```
(lldb) target create program.elf
(lldb) process launch --plugin simulator
Process 1 launched: 'program.elf' (mos)
(lldb) breakpoint set -n main
(lldb) continue
(lldb) frame variable
(lldb) register read --all
```

---

## Verified Working

| Feature | Status | Notes |
|---------|--------|-------|
| Process launch | ✅ | `process launch --plugin simulator` |
| Breakpoints | ✅ | Set by name (`-n main`) or address (`-a 0x8000`) |
| Continue | ✅ | Runs until breakpoint, halt, or error |
| Single-step | ✅ | `stepi` works correctly |
| Register read | ✅ | Shows A, X, Y, P, S, PC; `--all` includes imaginary registers |
| Memory read | ✅ | Reads emulator memory |
| Source display | ✅ | DWARF line info works |
| Stop at entry | ✅ | `--stop-at-entry` flag works |
| Frame variable | ✅ | Local variables via imaginary registers |
| Stack unwinding | ✅ | Full backtrace with frame selection |
| Imaginary registers | ✅ | RC0-RCn, RS0-RSn read from zero-page memory |

---

## Known Limitations

### Watchpoints
Not yet tested, but infrastructure exists in System.

---

## Architecture

```
LLDB
├── ProcessSimulator ──────────────────► emu::System
│   └── ThreadSimulator (one per CPU)   │
│       └── RegisterContextEmulator     │
│           └── [ImaginaryWrapper]      │
│                                       ▼
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
                        emu::Context  Semihost   emu::Memory
                         (MOS CPU)   (I/O)       (64KB RAM)
```

### Design Principles

1. **Single Source of Truth** - All debugging state lives in `emu::System`
2. **ProcessSimulator is a stateless adapter** - Delegates everything to System
3. **Target-agnostic** - ProcessSimulator knows `emu::System` and `emu::Context`, never `MOS::Context`
4. **Synchronous execution** - DoResume blocks, sets state transitions, returns
5. **DRY** - `System::create()` factory shared between llvm-emu and ProcessSimulator
6. **Platform code in ABI** - `ABI::WrapRegisterContext()` adds MOS-specific imaginary register support

---

## Implementation Files

```
lldb/source/Plugins/Process/Simulator/
├── CMakeLists.txt
├── ProcessSimulator.h/.cpp       # Process subclass, owns System
├── ThreadSimulator.h/.cpp        # Thread subclass, wraps Context
└── RegisterContextEmulator.h/.cpp  # Generic RegisterContext for emulators

lldb/source/Plugins/ABI/MOS/
├── ABISysV_mos.h/.cpp            # MOS ABI, implements WrapRegisterContext
├── MOSImaginaryRegisters.h/.cpp  # Parses DWARF for RC/RS register addresses
├── MOSRegisterContext.h/.cpp     # For GDB remote (inherits GDBRemoteRegisterContext)
└── RegisterContextImaginaryWrapper.h/.cpp  # Decorator for imaginary register support
```

---

## Key Implementation Details

### Imaginary Register Support

MOS uses "imaginary registers" (RC0-RCn, RS0-RSn) stored in zero-page memory. These are exposed to LLDB via:

1. **ABISysV_mos::AugmentRegisterInfo()** - Adds imaginary registers to the register list
2. **MOSImaginaryRegisters** - Parses DWARF to find zero-page addresses for each register
3. **RegisterContextImaginaryWrapper** - Decorator that intercepts ReadRegister/WriteRegister for imaginary registers and routes them through Process::ReadMemory/WriteMemory
4. **ABI::WrapRegisterContext()** - Generic hook for platform-specific register context enhancements

```cpp
// In ThreadSimulator::CreateRegisterContextForFrame
m_reg_context_sp = std::make_shared<RegisterContextEmulator>(...);
if (ABISP abi = process->GetABI())
  m_reg_context_sp = abi->WrapRegisterContext(m_reg_context_sp);
```

### System::create() Factory

Shared setup for memory and semihosting:

```cpp
auto system = emu::System::create(addr_bits, sandbox_dir);
// Creates:
// - Memory device (full address space)
// - Semihost device (console I/O, file access)
// - Exit callback to halt system
```

### DoResume Pattern

The critical fix for synchronous execution was the state transition pattern:

```cpp
Status ProcessSimulator::DoResume(RunDirection direction) {
  m_system->clearStopReason();

  // Detect single-step request
  bool single_step = /* check thread temporary resume states */;

  // CRITICAL: Set running state BEFORE execution
  SetPrivateState(eStateRunning);

  if (single_step) {
    m_context->step();
    m_system->setStopReason(StopReason::SingleStep, m_context->getPC());
  } else {
    m_system->run();
    if (m_system->getStopReason() == StopReason::Halted)
      SetExitStatus(m_system->getExitCode(), "");
  }

  // CRITICAL: Set stopped state AFTER execution
  SetPrivateState(eStateStopped);
  return Status();  // Return success, not error
}
```

### Stop Reason Mapping

| emu::System::StopReason | LLDB Action |
|-------------------------|-------------|
| Breakpoint | `StopInfo::CreateStopReasonWithBreakpointSiteID()` |
| Watchpoint | `StopInfo::CreateStopReasonWithWatchpointID()` |
| SingleStep | `StopInfo::CreateStopReasonToTrace()` |
| Halted | `SetExitStatus()` |
| Error/None | No stop info |

---

## Testing

```bash
# Basic test with imaginary registers
lldb ~/git/dwarf-torture/build/bin/nested_structs_O0 \
     -o "b main" \
     -o "process launch --plugin simulator" \
     -o "frame variable" \
     -o "register read --all" \
     -o "quit"

# Deep call stack test
lldb ~/git/dwarf-torture/build/bin/nested_structs_O0 \
     -o "b process_rectangle" \
     -o "process launch --plugin simulator" \
     -o "bt" \
     -o "frame select 1" \
     -o "frame variable local_rect" \
     -o "quit"
```

---

## Future Work

| Feature | Priority | Notes |
|---------|----------|-------|
| Watchpoints | Low | Infrastructure exists, needs testing |
| Reverse debugging | Low | Undo journal exists in System |
| Multi-CPU | Low | System already supports multiple Contexts |

---

## References

- `lldb/source/Plugins/Process/Simulator/` - ProcessSimulator implementation
- `lldb/source/Plugins/ABI/MOS/` - MOS ABI and imaginary register support
- `llvm/include/llvm/Emulator/System.h` - System interface
- `llvm/include/llvm/Emulator/Context.h` - Context interface
- `lldb/docs/use/mcp.md` - MCP interface for AI-driven debugging
