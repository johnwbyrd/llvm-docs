# llvm-mc Instruction Emulator

The llvm-mc tool includes a generic instruction emulator framework that enables running compiled programs directly without external emulators. The emulator provides cycle-accurate execution, instruction tracing, and host I/O via ZBC semihosting.

---

## Quick Start

```bash
# Basic execution (console I/O only)
llvm-mc --triple=mos --run program.o

# With file I/O (sandboxed to a directory)
llvm-mc --triple=mos --run --semihost=/path/to/sandbox program.o

# With instruction tracing
llvm-mc --triple=mos --run --trace program.o

# Trace in VCD format for waveform viewers
llvm-mc --triple=mos --run --trace --trace-format=vcd program.o
```

---

## Command-Line Options

| Option | Default | Description |
|--------|---------|-------------|
| `--run` | off | Execute the loaded ELF file |
| `--semihost=<dir>` | (none) | Enable filesystem access sandboxed to directory |
| `--trace` | off | Print each instruction as it executes |
| `--trace-format=<fmt>` | text | Trace format: `text`, `json`, or `vcd` |
| `--run-max-cycles=<n>` | 1000000 | Maximum cycles before forced halt |

### Semihosting Modes

- **No `--semihost`**: Console-only mode. Programs can use stdin/stdout/stderr and exit, but filesystem operations return errors.
- **`--semihost=<dir>`**: Sandboxed mode. File operations are restricted to the specified directory.

### Exit Codes

The emulator returns the guest program's exit code (from `exit()` or `SYS_EXIT`). Special cases:

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Emulator error (e.g., no emulator for target) |
| Non-zero | Guest program's exit code |

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                        emu::System                          │
│  - Routes memory accesses to devices by address             │
│  - Manages CPU contexts and timer interrupts                │
│  - Coordinates execution and halt signals                   │
└─────────────────────────────────────────────────────────────┘
        │                       │                       │
        ▼                       ▼                       ▼
┌───────────────┐       ┌───────────────┐       ┌───────────────┐
│  emu::Memory  │       │emu::Semihost  │       │ (other devices)│
│    (RAM)      │       │  (host I/O)   │       │                │
│  0x0000-FFFF  │       │  0xFCE0-FCFF  │       │                │
└───────────────┘       └───────────────┘       └───────────────┘
        ▲                       ▲
        │ read/write            │
        └───────────────────────┘
                    │
┌─────────────────────────────────────────────────────────────┐
│                  MOS::Context (emu::Context)                │
│  - CPU registers: A, X, Y, S, PC, status flags              │
│  - step(): fetch, decode, execute one instruction           │
│  - Cycle-accurate with page-cross penalties                 │
│  - IRQ/NMI interrupt support                                │
└─────────────────────────────────────────────────────────────┘
```

### Key Components

| File | Purpose |
|------|---------|
| `llvm/include/llvm/Emulator/Context.h` | Abstract CPU execution context |
| `llvm/include/llvm/Emulator/System.h` | Device router and execution coordinator |
| `llvm/include/llvm/Emulator/Device.h` | Memory-mapped device interface |
| `llvm/include/llvm/Emulator/Memory.h` | RAM device implementation |
| `llvm/include/llvm/Emulator/Semihost.h` | ZBC semihosting device |
| `llvm/include/llvm/Emulator/Trace.h` | Execution trace writers |
| `llvm/lib/Target/MOS/MCTargetDesc/MOSContext.h` | MOS 6502 CPU implementation |

---

## emu::Context - CPU Execution Context

Abstract base class for target-specific CPU implementations.

### Core Interface

```cpp
class Context {
public:
  // Execution control
  virtual bool step() = 0;              // Execute one instruction
  virtual bool run();                   // Execute until halted
  virtual void reset() = 0;             // Reset to initial state

  // State accessors
  virtual uint64_t getPC() const = 0;
  virtual void setPC(uint64_t PC) = 0;
  virtual uint64_t getCycles() const = 0;
  virtual bool isHalted() const = 0;
  virtual void halt(int ExitCode = 0) = 0;
  virtual int getExitCode() const;

  // Address space
  virtual unsigned getAddressBits() const;  // Default: 32

  // Interrupts (optional)
  virtual void assertIRQ();             // Level-triggered
  virtual void deassertIRQ();
  virtual void assertNMI();             // Edge-triggered

  // Memory access (routes through System)
  uint8_t read(uint64_t Addr);
  void write(uint64_t Addr, uint8_t Value);
  uint16_t read16(uint64_t Addr);       // Little-endian
  void write16(uint64_t Addr, uint16_t Value);

  // Tracing
  void setTracing(bool Enable);
  void setTraceWriter(TraceWriter *TW);
};
```

### Execution Model

The `step()` method executes one instruction:

1. Check for pending interrupts (NMI first, then IRQ)
2. Fetch instruction bytes from PC
3. Decode via MCDisassembler
4. Trace if enabled
5. Execute instruction semantics
6. Accumulate cycles (base + penalties)
7. Update PC (unless modified by branch/jump)

---

## emu::System - Device Router

Coordinates memory-mapped devices and CPU execution.

### Device Mapping

```cpp
System Sys;

// Add RAM covering address space
auto RAM = std::make_unique<Memory>(65536);
Sys.addOwnedDevice(0x0000, 0xFFFF, std::move(RAM));

// Add semihost device (overlays RAM at high addresses)
auto Semihost = Semihost::createConsoleOnly(Sys);
Sys.addDevice(0xFCE0, 0xFCFF, Semihost.get());
```

**Priority**: Later-added devices take priority. When the CPU accesses an address, the System searches devices in reverse order.

**Unmapped access**: Reads return `0xFF` (floating bus), writes are ignored.

### Timer Support

```cpp
// Configure periodic timer interrupt
Sys.setSemihostDevice(Semihost.get());  // For STATUS register
Sys.configureTimer(60, 0);              // 60 Hz to context 0
```

Timer IRQs are level-triggered: the IRQ stays asserted until the guest writes 0 to the semihost STATUS register.

---

## emu::Device - Memory-Mapped Interface

```cpp
class Device {
public:
  virtual uint8_t read(uint64_t Offset) = 0;
  virtual void write(uint64_t Offset, uint8_t Value) = 0;

  // Optional bulk operations (default: byte-by-byte)
  virtual void readBlock(uint8_t *Dest, uint64_t Offset, uint64_t Size);
  virtual void writeBlock(uint64_t Offset, const uint8_t *Src, uint64_t Size);
};
```

### Built-in Devices

| Device | Description |
|--------|-------------|
| `emu::Memory` | Simple RAM with optional read-only flag |
| `emu::Semihost` | ZBC semihosting for host I/O |

---

## emu::Semihost - Host I/O

Implements the ZBC semihosting protocol for guest programs to interact with the host.

### Creation Modes

```cpp
// Console only - stdin/stdout/stderr and exit
auto Dev = Semihost::createConsoleOnly(Sys);

// Sandboxed filesystem - restricted to directory
auto Dev = Semihost::create(Sys, "/path/to/sandbox");

// Unrestricted filesystem (DANGEROUS - use for testing only)
auto Dev = Semihost::createInsecure(Sys);
```

### Device Register Layout (32 bytes)

| Offset | Name | Access | Description |
|--------|------|--------|-------------|
| 0x00-0x07 | SIGNATURE | R | "ZBCSHOST" magic |
| 0x08-0x0F | RIFF_PTR | RW | Pointer to RIFF buffer in guest memory |
| 0x10-0x17 | — | — | Reserved |
| 0x18 | DOORBELL | W | Write triggers semihost call |
| 0x19 | STATUS | RW | Bit 0: response ready / timer tick |
| 0x1A-0x1F | — | — | Reserved |

### Address Calculation

The semihost device address is calculated based on the CPU's address bus width:

```
reserved_start = 2^n - 2^(n/2)
semihost_base = reserved_start - 512 - 32

For 16-bit (n=16):
  reserved_start = 65536 - 256 = 65280
  semihost_base = 65280 - 512 - 32 = 64736 = 0xFCE0
```

### Supported Operations

| Syscall | Number | Description |
|---------|--------|-------------|
| SYS_OPEN | 0x01 | Open file |
| SYS_CLOSE | 0x02 | Close file |
| SYS_WRITEC | 0x03 | Write character to console |
| SYS_WRITE0 | 0x04 | Write null-terminated string |
| SYS_WRITE | 0x05 | Write bytes to file |
| SYS_READ | 0x06 | Read bytes from file |
| SYS_READC | 0x07 | Read character from console |
| SYS_SEEK | 0x0A | Seek in file |
| SYS_FLEN | 0x0C | Get file length |
| SYS_REMOVE | 0x0E | Delete file |
| SYS_RENAME | 0x0F | Rename file |
| SYS_CLOCK | 0x10 | Get centiseconds since start |
| SYS_TIME | 0x11 | Get Unix timestamp |
| SYS_EXIT | 0x18 | Exit with status |
| SYS_TIMER_CONFIG | 0x32 | Configure periodic timer IRQ |

---

## emu::TraceWriter - Execution Tracing

### Trace Formats

| Format | Flag | Use Case |
|--------|------|----------|
| Text | `--trace-format=text` | Human-readable, grep-friendly |
| JSON | `--trace-format=json` | Machine parsing, streaming |
| VCD | `--trace-format=vcd` | Waveform viewers (GTKWave) |

### Text Format Example

```
12345	$0200	A=42 X=00 Y=FF S=FD P=30	lda #$42
12347	$0202	A=42 X=00 Y=FF S=FD P=30	sta $0400
```

Fields: cycle, PC, registers, disassembly (tab-separated)

### JSON Format Example

```json
{"cycle":12345,"pc":"0200","regs":{"A":"42","X":"00","Y":"FF","S":"FD","P":"30"},"inst":"lda #$42"}
```

### VCD Format

IEEE 1364 Value Change Dump format. Register widths are auto-detected from the first traced instruction. Compatible with GTKWave and other waveform viewers.

---

## MOS 6502 Implementation

The MOS target provides `MOS::Context`, a complete 6502 emulator.

### CPU State

```cpp
// Registers
uint8_t  A;           // Accumulator
uint8_t  X, Y;        // Index registers
uint8_t  S;           // Stack pointer (page 1: $0100-$01FF)
uint16_t PC;          // Program counter

// Status flags (P register)
bool N;               // Negative (bit 7)
bool V;               // Overflow (bit 6)
bool D;               // Decimal mode (bit 3)
bool I;               // Interrupt disable (bit 2)
bool Z;               // Zero (bit 1)
bool C;               // Carry (bit 0)

// Interrupt state
uint8_t IRQPending;   // Hardware IRQ asserted
uint8_t NMIPending;   // NMI pending
```

### Address Space

- **Address bus**: 16-bit (64KB)
- **Stack**: Page 1 ($0100-$01FF)
- **Vectors**: NMI=$FFFA, RESET=$FFFC, IRQ=$FFFE

### Interrupt Handling

**NMI (Non-Maskable, Edge-Triggered)**:
1. Push PC high byte, PC low byte, P (with B=0)
2. Set I flag
3. Load PC from $FFFA
4. Cost: 7 cycles

**IRQ (Hardware, Level-Triggered)**:
1. Check: IRQPending && !I
2. Push PC high byte, PC low byte, P (with B=0)
3. Set I flag
4. Load PC from $FFFE
5. Cost: 7 cycles
6. IRQ stays asserted until device clears it

**Priority**: NMI is checked before IRQ, both before instruction fetch.

### Cycle Counting

Cycles are accumulated from multiple sources:

1. **Base cycles**: From instruction TSFlags (bits 4-8)
2. **Page-cross penalty**: From TSFlags (bits 9-12) when indexed mode crosses page boundary
3. **Branch taken**: +1 cycle when branch condition is true
4. **Branch page-cross**: +1 additional cycle if branch target is on different page

A page boundary is crossed when the high byte of an address changes (every 256 bytes).

### Halt Instruction

Instructions with the `HaltEmulation` TSFlag bit set (bit 27) cause the emulator to halt with exit code 0. This is used for BRK in test scenarios.

---

## Instruction Semantics Generation

Instruction semantics can be defined in two ways:

### TableGen Emulate Blocks

```tablegen
let Emulate = [{ A = $Value; setNZ(A); }] in {
  defm LDA : Op<0xA9, "lda", Immediate>;
  defm LDA : Op<0xA5, "lda", ZeroPage>;
}
```

The `EmulatorEmitter` TableGen backend:
1. Processes `Emulate` fields from instruction definitions
2. Resolves `$Variable` references (e.g., `$EA`, `$Value` from addressing modes)
3. Generates C++ switch cases wrapped in `#ifdef GET_EMULATOR_CASES`

### SAIL Formal Specification

The MOS target includes a formal SAIL specification (`llvm/lib/Target/MOS/Sail/mos6502.sail`) that defines instruction semantics. The SAIL compiler generates Jib IR (`mos6502.ir`) which can be translated to C++ by the EmulatorEmitter.

SAIL provides:
- Formal semantics for verification
- Automatic C++ code generation
- Consistent behavior across tools

---

## Execution Flow (llvm-mc --run)

1. **Parse ELF**: Load object file and enumerate sections
2. **Create emulator**: `Target::createEmulator()` returns target-specific Context
3. **Query address width**: `Context::getAddressBits()` (16 for MOS)
4. **Allocate RAM**: Size = 2^(address bits)
5. **Load sections**: Copy .text and .data to RAM (skip .bss, debug sections)
6. **Setup semihost**: Calculate address, register exit callback
7. **Reset CPU**: Read reset vector, initialize registers
8. **Configure tracing**: If `--trace`, create appropriate TraceWriter
9. **Execute**: `System::run()` until halt or cycle limit
10. **Return exit code**: From halted context

---

## Adding Emulation for a New Target

### 1. Create Context Subclass

```cpp
// llvm/lib/Target/FOO/MCTargetDesc/FOOContext.h
namespace FOO {
class Context : public emu::Context {
public:
  // CPU registers
  uint32_t R[16];
  uint32_t PC;
  uint64_t Cycles;
  bool Halted;
  int ExitCode;

  Context(const MCDisassembler *D, const MCInstrInfo *II);

  bool step() override;
  void reset() override;
  uint64_t getPC() const override { return PC; }
  void setPC(uint64_t P) override { PC = P; }
  uint64_t getCycles() const override { return Cycles; }
  bool isHalted() const override { return Halted; }
  void halt(int Code) override { Halted = true; ExitCode = Code; }

private:
  const MCDisassembler *Disasm;
  const MCInstrInfo *II;
};
}
```

### 2. Implement step()

```cpp
bool Context::step() {
  if (Halted) return true;

  // Fetch
  uint8_t Bytes[16];
  for (int i = 0; i < 16; ++i)
    Bytes[i] = read(PC + i);

  // Decode
  MCInst Inst;
  uint64_t Size;
  ArrayRef<uint8_t> ByteArr(Bytes, 16);
  Disasm->getInstruction(Inst, Size, ByteArr, PC, nulls());

  // Trace
  if (Tracing && Trace) {
    SmallVector<TraceReg, 8> Regs;
    // ... populate register values
    Trace->traceInstruction(Cycles, PC, Inst, Regs);
  }

  // Execute
  execute(Inst);  // Generated or manual switch

  // Advance
  PC += Size;
  Cycles += getCyclesForInst(Inst);

  return true;
}
```

### 3. Register Factory Function

```cpp
// In FOOMCTargetDesc.cpp
static emu::Context *createFOOEmulator(const MCSubtargetInfo &STI,
                                       MCContext &Ctx) {
  auto *Disasm = TheTarget.createMCDisassembler(STI, Ctx);
  auto *II = TheTarget.createMCInstrInfo();
  return new FOO::Context(Disasm, II);
}

extern "C" LLVM_EXTERNAL_VISIBILITY void LLVMInitializeFOOTargetMC() {
  // ... other registrations ...
  TargetRegistry::RegisterEmulator(getTheFOOTarget(), createFOOEmulator);
}
```

---

## References

- [ZBC Semihosting Protocol](https://github.com/mamedev/mame/blob/master/docs/source/techspecs/zbc.rst)
- [ARM Semihosting](https://developer.arm.com/documentation/dui0471/m/what-is-semihosting-)
- [SAIL Language](https://github.com/rems-project/sail)
