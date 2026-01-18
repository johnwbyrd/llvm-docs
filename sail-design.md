# Redesigning 65xx SAIL Specifications

This document captures lessons learned from the sail-riscv project that can be applied to improve the 65xx SAIL implementations.

## Table of Contents

1. [Overview](#overview)
2. [Hardware Capability vs Currently Enabled](#hardware-capability-vs-currently-enabled)
3. [Modular File Organization](#modular-file-organization)
4. [Rich Type System](#rich-type-system)
5. [ExecutionResult Union](#executionresult-union)
6. [Callbacks for External Integration](#callbacks-for-external-integration)
7. [Extension Support Infrastructure](#extension-support-infrastructure)
8. [Fetch-Decode-Execute Separation](#fetch-decode-execute-separation)
9. [Initialization and Reset](#initialization-and-reset)
10. [to_str Overloads for Debugging](#to_str-overloads-for-debugging)
11. [Configuration Support](#configuration-support)
12. [Summary](#summary)
13. [Current Implementation Status](#current-implementation-status)
14. [Design Decisions and Quirks](#design-decisions-and-quirks)
15. [65xx Variant Differences](#65xx-variant-differences)
16. [Integration with llvm-mos](#integration-with-llvm-mos)
17. [References](#references)

---

## Overview

The current MOS 6502 SAIL specification (`llvm/lib/Target/MOS/Sail/mos6502.sail`) is a single 926-line file. While functional, it can benefit from patterns established in the mature sail-riscv project, which is the official formal specification of the RISC-V ISA adopted by RISC-V International.

**Key sail-riscv files studied:**
- `model/core/extensions.sail` - Extension support infrastructure
- `model/core/types.sail` - Type definitions
- `model/core/callbacks.sail` - External integration callbacks
- `model/core/regs.sail` - Register definitions
- `model/core/pc_access.sail` - PC manipulation
- `model/sys/mem.sail` - Memory interface
- `model/sys/insts_begin.sail` - Instruction infrastructure
- `model/postlude/step.sail` - Fetch-decode-execute loop
- `model/postlude/model.sail` - Init/reset
- `model/extensions/M/mext_insts.sail` - Example extension

---

## Hardware Capability vs Currently Enabled

The sail-riscv model uses two related but distinct functions for extension support. We adapt this pattern for 65xx, using clearer naming since we're single-threaded (no "hart" concept needed).

### `hardwareCapability(ext)` - Static Hardware Capability

**Purpose:** Checks if the **hardware configuration** supports a given extension. This is a **static** property determined at configuration time.

**How it works:**
- Reads from `config extensions.X.supported` values (from JSON configuration file)
- Or computes based on hardware parameters
- Returns `true` if the hardware *has the capability* to use the extension

**sail-riscv equivalent:** `hartSupports()`

**Examples:**
```sail
function clause hardwareCapability(Ext_6502) = true  // Always supported
function clause hardwareCapability(Ext_65C02) = config cpu.variant >= 1
function clause hardwareCapability(Ext_65CE02) = config cpu.variant == 3
function clause hardwareCapability(Ext_65816) = config cpu.variant >= 4
function clause hardwareCapability(Ext_Decimal) = config features.decimal_mode
```

### `currentlyEnabled(ext)` - Dynamic Runtime State

**Purpose:** Checks if an extension is **currently usable** given dynamic state. An extension can be supported by hardware but temporarily disabled.

**How it works:**
- First checks `hardwareCapability(ext)`
- Then checks any relevant runtime state
- Returns `true` only if both hardware supports it AND it's enabled

**For 65xx:** Since the 6502 family has no CSR bits to toggle extensions at runtime, `currentlyEnabled()` is typically equivalent to `hardwareCapability()`. However, this separation is still useful for:
- The 65816's emulation mode (E flag) which disables 16-bit features
- Future flexibility

**Examples:**
```sail
// Most extensions: enabled if hardware supports them
function clause currentlyEnabled(Ext_65C02) = hardwareCapability(Ext_65C02)

// 65816 native mode features: requires hardware support AND emulation mode off
function clause currentlyEnabled(Ext_65816_Native) =
  hardwareCapability(Ext_65816) & E == 0b0
```

### Where They're Used

```sail
// In instruction encoding - guards which instructions can be decoded
mapping clause encdec = PHX_Implied()
  <-> 0xDA
  when currentlyEnabled(Ext_65C02)

// In instruction execution - no need to check again, encdec already filtered
function clause execute PHX_Implied() = {
  push(X);
  RETIRE_SUCCESS
}
```

### For 65xx Implementation

```sail
// Extensions enum
enum Extension = {
  Ext_6502,       // Base NMOS 6502
  Ext_65C02,      // CMOS additions (PHX, PHY, STZ, BRA, etc.)
  Ext_R65C02,     // Rockwell additions (BBR, BBS, RMB, SMB)
  Ext_W65C02,     // WDC additions (WAI, STP)
  Ext_65CE02,     // CSG 65CE02 (Z register, 16-bit branches, etc.)
  Ext_65816,      // 16-bit 65816 (emulation mode)
  Ext_65816_Native, // 65816 native mode features
  Ext_Decimal,    // Decimal mode support
}

// hardwareCapability - static config
scattered function hardwareCapability
function clause hardwareCapability(Ext_6502) = true  // Always supported
function clause hardwareCapability(Ext_65C02) = config cpu.variant >= 1
function clause hardwareCapability(Ext_R65C02) = config cpu.variant == 2
function clause hardwareCapability(Ext_W65C02) = config cpu.variant >= 1
function clause hardwareCapability(Ext_65CE02) = config cpu.variant == 3
function clause hardwareCapability(Ext_65816) = config cpu.variant >= 4
function clause hardwareCapability(Ext_Decimal) = config features.decimal_mode

// currentlyEnabled - for most 65xx, same as hardwareCapability
scattered function currentlyEnabled
function clause currentlyEnabled(ext) = hardwareCapability(ext)

// Exception: 65816 native mode requires E=0
function clause currentlyEnabled(Ext_65816_Native) =
  hardwareCapability(Ext_65816) & E == 0b0
```

---

## Modular File Organization

**Current State:** `mos6502.sail` is a single 926-line file.

**sail-riscv Pattern:** Uses a `.sail_project` file with modular dependencies:
```
prelude → core → sys → extensions → postlude → main
```

**Recommendation:** Split into multiple files:

```
65xx/
├── 65xx.sail_project        # Module dependencies
├── prelude/
│   └── prelude.sail         # Includes, operators, basic types
├── core/
│   ├── types.sail           # Type definitions, enums
│   ├── regs.sail            # Register definitions
│   ├── pc_access.sail       # PC manipulation
│   └── callbacks.sail       # External callbacks
├── sys/
│   ├── mem.sail             # Memory interface
│   ├── stack.sail           # Stack operations
│   └── interrupts.sail      # IRQ/NMI handling
├── instructions/
│   ├── insts_begin.sail     # Scattered union setup
│   ├── load_store.sail      # LDA, LDX, LDY, STA, STX, STY
│   ├── arithmetic.sail      # ADC, SBC
│   ├── logical.sail         # AND, ORA, EOR, BIT
│   ├── compare.sail         # CMP, CPX, CPY
│   ├── inc_dec.sail         # INC, DEC, INX, INY, DEX, DEY
│   ├── shift_rotate.sail    # ASL, LSR, ROL, ROR
│   ├── transfer.sail        # TAX, TXA, TAY, TYA, TSX, TXS
│   ├── stack_insts.sail     # PHA, PLA, PHP, PLP
│   ├── flags.sail           # CLC, SEC, CLI, SEI, etc.
│   ├── branch.sail          # BPL, BMI, BVC, BVS, BCC, BCS, BNE, BEQ
│   ├── jump.sail            # JMP, JSR, RTS, RTI
│   ├── misc.sail            # BRK, NOP
│   └── insts_end.sail       # End scattered union
├── postlude/
│   ├── fetch.sail           # Instruction fetch
│   ├── step.sail            # Execute cycle
│   └── model.sail           # Init/reset
└── variants/
    ├── 65c02.sail           # 65C02 extensions
    ├── 65ce02.sail          # 65CE02 extensions
    └── 65816.sail           # 65816 extensions
```

---

## Rich Type System

**Current State:** Uses bare `bits(N)` types.

**sail-riscv Pattern:** Uses newtypes and structured types:
```sail
newtype regidx = Regidx : bits(5)
newtype physaddr = Physaddr : bits(physaddr_bits)
type word_width = {1, 2, 4, 8}
```

**Recommendation:** Add typed wrappers for clarity:

```sail
// Types for 65xx
type byte = bits(8)
type addr8 = bits(8)    // Zero page address
type addr16 = bits(16)  // Full address

// Newtypes for type safety
newtype zpaddr = ZPAddr : bits(8)      // Zero page address
newtype absaddr = AbsAddr : bits(16)   // Absolute address
newtype reloff = RelOff : bits(8)      // Relative branch offset

// Status register as structured type
bitfield StatusReg : bits(8) = {
  N : 7,      // Negative
  V : 6,      // Overflow
  _unused : 5,
  B : 4,      // Break (only in pushed P)
  D : 3,      // Decimal
  I : 2,      // Interrupt disable
  Z : 1,      // Zero
  C : 0       // Carry
}

register P : StatusReg
```

---

## ExecutionResult Union

**Current State:** Returns `RETIRE_SUCCESS` enum.

**sail-riscv Pattern:** Uses a rich union for execution outcomes:
```sail
union ExecutionResult = {
  Retire_Success                 : unit,
  ExecuteAs                      : instruction,
  Enter_Wait                     : WaitReason,
  Illegal_Instruction            : unit,
  Trap                           : (Privilege, ctl_result, xlenbits),
  Memory_Exception               : (virtaddr, ExceptionType),
  // ... extension errors
}
```

**Recommendation:** Create richer execution result:

```sail
union ExecutionResult = {
  Retire_Success     : unit,
  Illegal_Opcode     : bits(8),       // For undocumented opcodes
  BRK_Interrupt      : unit,          // Software interrupt
  Halt               : unit,          // For WDC WAI/STP instructions
}

// Default for compatibility
let RETIRE_SUCCESS : ExecutionResult = Retire_Success()
```

---

## Callbacks for External Integration

**Current State:** No callbacks defined.

**sail-riscv Pattern:** Comprehensive callbacks in `core/callbacks.sail`:
```sail
val fetch_callback = pure {cpp: "fetch_callback"} : forall 'n, 'n in {16, 32}. (bits('n)) -> unit
val mem_write_callback = pure {cpp: "mem_write_callback"} : ...
val pc_write_callback = pure {cpp: "pc_write_callback"} : ...
val xreg_full_write_callback = pure {cpp: "xreg_full_write_callback"} : ...
```

**Recommendation:** Add callbacks for emulator/debugger integration:

```sail
// Callbacks for external integration (e.g., MAME, debugger)
val fetch_callback = pure {cpp: "fetch_callback"} : (bits(16), bits(8)) -> unit  // PC, opcode
function fetch_callback(_, _) = ()

val mem_read_callback = pure {cpp: "mem_read_callback"} : (bits(16), bits(8)) -> unit
function mem_read_callback(_, _) = ()

val mem_write_callback = pure {cpp: "mem_write_callback"} : (bits(16), bits(8)) -> unit
function mem_write_callback(_, _) = ()

val reg_write_callback = pure {cpp: "reg_write_callback"} : (string, bits(8)) -> unit
function reg_write_callback(_, _) = ()

val pc_write_callback = pure {cpp: "pc_write_callback"} : (bits(16)) -> unit
function pc_write_callback(_) = ()

val irq_callback = pure {cpp: "irq_callback"} : (bool, bits(16)) -> unit  // is_nmi, vector
function irq_callback(_, _) = ()
```

---

## Extension Support Infrastructure

**Current State:** Comment mentions "65C02, 65816 will be separate files."

**sail-riscv Pattern:** Uses `currentlyEnabled()` function with scattered clauses.

**Recommendation:** Add extension infrastructure (see [Hardware Capability vs Currently Enabled](#hardware-capability-vs-currently-enabled) for details):

```sail
// In core/extensions.sail
enum Extension = {
  Ext_6502,       // Base NMOS 6502
  Ext_65C02,      // CMOS 65C02 additions
  Ext_R65C02,     // Rockwell 65C02 (BBR, BBS, RMB, SMB)
  Ext_W65C02,     // WDC 65C02 (WAI, STP)
  Ext_65CE02,     // CSG 65CE02
  Ext_65816,      // 16-bit 65816
  Ext_Decimal,    // Decimal mode support
}

scattered function hardwareCapability : Extension -> bool
scattered function currentlyEnabled : Extension -> bool

// Default: base 6502 always supported
function clause hardwareCapability(Ext_6502) = true
function clause currentlyEnabled(Ext_6502) = true

// 65C02 instructions enabled if hardware supports
function clause hardwareCapability(Ext_65C02) = config extensions.Ext_65C02 : bool
function clause currentlyEnabled(Ext_65C02) = hardwareCapability(Ext_65C02)
```

Then in extension files:
```sail
// In variants/65c02.sail
union clause instruction = PHX_Implied : unit
union clause instruction = PHY_Implied : unit
union clause instruction = PLX_Implied : unit
union clause instruction = PLY_Implied : unit
union clause instruction = STZ_ZeroPage : bits(8)
// ... etc

function clause execute PHX_Implied() = {
  push(X);
  RETIRE_SUCCESS
}
```

---

## Fetch-Decode-Execute Separation

**Current State:** No fetch/decode/execute loop in the spec.

**sail-riscv Pattern:** Clear separation in `postlude/step.sail`:
- `fetch()` - returns `FetchResult` union
- `decode()` - via `encdec` mapping
- `execute()` - scattered function
- `try_step()` - main driver

**Recommendation:** Add execution framework:

```sail
// In postlude/fetch.sail
union FetchResult = {
  F_Ok     : (bits(8), nat),   // opcode, instruction length
  F_Error  : bits(16)          // faulting address
}

val fetch : unit -> FetchResult
function fetch() = {
  let opcode = readMem(PC);
  fetch_callback(PC, opcode);
  F_Ok(opcode, instructionLength(opcode))
}

// In postlude/step.sail
val try_step : nat -> bool
function try_step(step_no) = {
  // Check for pending interrupts first
  if checkAndHandleNMI() then return true;
  if checkAndHandleIRQ() then return true;

  match fetch() {
    F_Error(addr) => { /* handle fetch error */ false },
    F_Ok(opcode, len) => {
      NextPC = PC + len;
      let instr = decode(opcode);  // Your existing decode logic
      let result = execute(instr);
      match result {
        RETIRE_SUCCESS => { tick_pc(); true },
        _ => { /* handle other results */ false }
      }
    }
  }
}

val loop : unit -> unit
function loop() = {
  var step_no : nat = 0;
  while true do {
    if try_step(step_no) then step_no = step_no + 1;
  }
}
```

---

## Initialization and Reset

**Current State:** No init/reset functions.

**sail-riscv Pattern:** Clear init/reset separation in `postlude/model.sail`.

**Recommendation:**

```sail
// In postlude/model.sail
function reset() -> unit = {
  // Per 6502 datasheet reset sequence
  A = 0x00;
  X = 0x00;
  Y = 0x00;
  S = 0xFD;  // Stack pointer initialized to $FD after reset

  // Flags: I set, others undefined (we clear them)
  N = 0b0;
  V = 0b0;
  D = 0b0;
  I = 0b1;   // Interrupts disabled on reset
  Z = 0b0;
  C = 0b0;

  // Clear interrupt pending flags
  IRQPending = 0b0;
  NMIPending = 0b0;

  // Load reset vector
  PC = readMem16(0xFFFC);
  NextPC = PC;
}

function init_model() -> unit = {
  reset();
}
```

---

## to_str Overloads for Debugging

**sail-riscv Pattern:** Uses `to_str` overloads extensively:
```sail
overload to_str = {privLevel_to_str, interruptType_to_str, exceptionType_to_str, ...}
```

**Recommendation:**

```sail
// String conversion for debugging
function instruction_to_str(i : instruction) -> string =
  match i {
    LDA_Immediate(imm) => "lda #$" ^ hex_bits_str(imm),
    LDA_ZeroPage(addr) => "lda $" ^ hex_bits_str(addr),
    LDA_Absolute(addr) => "lda $" ^ hex_bits_str(addr),
    // ... etc
  }

function regs_to_str() -> string =
  "A=" ^ hex_bits_str(A) ^
  " X=" ^ hex_bits_str(X) ^
  " Y=" ^ hex_bits_str(Y) ^
  " S=" ^ hex_bits_str(S) ^
  " P=" ^ hex_bits_str(getP()) ^
  " PC=" ^ hex_bits_str(PC)

overload to_str = {instruction_to_str}
```

---

## Configuration Support

**sail-riscv Pattern:** Uses `config` values from JSON:
```sail
type base_E_enabled : Bool = config base.E
```

**Recommendation:** Add configuration for 65xx variants:

```sail
// Configuration values (set from external config)
type decimal_mode_supported : Bool = config features.decimal_mode
type variant : int = config cpu.variant  // 0=6502, 1=65C02, 2=R65C02, 3=65CE02, 4=65816

// Use in instructions
function clause execute ADC_Immediate(imm) = {
  if D == 0b1 & decimal_mode_supported then
    doADC_Decimal(imm)
  else
    doADC_Binary(imm);
  RETIRE_SUCCESS
}
```

---

## Summary

| Improvement | Priority | Effort | Benefit |
|-------------|----------|--------|---------|
| Modular file organization | High | Medium | Maintainability, extensibility |
| Extension infrastructure | High | Medium | 65C02/65CE02/65816 support |
| Callbacks | High | Low | Emulator integration |
| Fetch-decode-execute | Medium | Medium | Clean architecture |
| Rich type system | Medium | Low | Type safety, clarity |
| ExecutionResult union | Medium | Low | Better error handling |
| Configuration support | Medium | Medium | Runtime flexibility |
| Init/reset functions | Low | Low | Completeness |
| to_str overloads | Low | Low | Debugging |

---

## Current Implementation Status

**Status: REDESIGN COMPLETE** (January 2026)

The redesigned SAIL specification has been implemented following the patterns in this document.

### File Structure

```
llvm/lib/Target/MOS/Sail/
├── mos.sail_project      (10 lines)   - Build order
├── prelude.sail          (75 lines)   - Includes, operators, overloads
├── core.sail            (199 lines)   - Extensions, registers, PC access, callbacks, toStr
├── sys.sail             (114 lines)   - Memory, stack, interrupts
├── instructions.sail    (695 lines)   - All 150 instruction variants + helpers
├── model.sail           (442 lines)   - Fetch, decode, reset, init, step loop
└── variants/
    └── 65c02.sail        (95 lines)   - Placeholder for 65C02 extensions
```

**Total: ~1,630 lines** (split across 6 files + 1 variant placeholder)

### Implemented Features

| Feature | Status | File(s) |
|---------|--------|---------|
| Modular file organization | ✅ Complete | All files |
| Extension infrastructure (`hardwareCapability`/`currentlyEnabled`) | ✅ Complete | core.sail |
| Callbacks for external integration | ✅ Complete | core.sail |
| Fetch-decode-execute separation | ✅ Complete | model.sail |
| ExecutionResult union | ✅ Complete | core.sail |
| Init/reset functions | ✅ Complete | model.sail |
| `toStr` overloads for debugging | ✅ Complete | core.sail |
| LLVM naming conventions | ✅ Complete | All files |
| Full decode table (151 opcodes) | ✅ Complete | model.sail |
| JMP indirect bug (conditional on Ext_65C02) | ✅ Complete | instructions.sail |
| Decimal mode (conditional on Ext_Decimal) | ✅ Complete | instructions.sail |

### Naming Conventions (LLVM Style)

The implementation follows LLVM coding standards:

| Element | Convention | Examples |
|---------|------------|----------|
| Functions | lowerCamelCase | `setNZ`, `doADC`, `tryStep`, `opcodeLength` |
| Variables | UpperCamelCase | `Result`, `Addr`, `Opcode`, `NextPC` |
| Types/Enums | UpperCamelCase | `ExecutionResult`, `Extension`, `FetchResult` |
| Enum values | Prefix + UpperCamelCase | `ER_Success`, `Ext_65C02`, `FR_Ok`, `AM_Immediate` |

### Not Yet Implemented
- No `encdec` mappings (see Design Decisions below)
- No undocumented/illegal opcodes
- No cycle-accurate timing
- 65C02/65CE02/65816 instructions (placeholder file exists)

---

## Design Decisions and Quirks

### Why No `encdec` Mappings

The current implementation explicitly avoids SAIL's `encdec` mapping feature:

```sail
// Note: We don't use encdec mapping for 6502 because variable-length
// instructions don't fit SAIL's fixed-width mapping model well.
// TableGen already handles instruction encoding - we only need
// the execute semantics for the emulator.
```

This is because:
1. 6502 instructions are 1-3 bytes (variable length)
2. SAIL's `encdec` works best with fixed-width instruction words
3. The EmulatorEmitter in TableGen already handles opcode dispatch
4. We only need the `execute` clauses for semantic definition

### JMP Indirect Bug

The famous 6502 JMP ($xxFF) bug is correctly emulated:

```sail
function clause execute JMP_Indirect16(addr) = {
    let lo = readMem(addr);
    // Bug: high byte comes from same page, not addr+1
    let hi_addr : bits(16) = addr[15..8] @ ((addr[7..0]) + 1);
    let hi = readMem(hi_addr);
    setNextPC(hi @ lo);
    RETIRE_SUCCESS
}
```

The 65C02 fixes this bug - a redesigned implementation should make this behavior conditional on `hardwareCapability(Ext_6502)` vs `hardwareCapability(Ext_65C02)`.

### BCD Mode Undefined Behavior

On NMOS 6502, the N, V, and Z flags are undefined after BCD operations. The current implementation:
- Sets N and Z based on the result (like binary mode)
- Leaves V unchanged

The 65C02 defines these flags properly - another area where variant behavior differs.

### Interrupt Handling

- **IRQ** is level-triggered: `IRQPending` must be cleared by the device
- **NMI** is edge-triggered: `NMIPending` is cleared after handling
- Both push PC and P (with B=0), set I=1, then load vector

---

## 65xx Variant Differences

### 65C02 (CMOS)
New instructions:
- `PHX`, `PHY`, `PLX`, `PLY` - push/pull X and Y
- `STZ` - store zero (all addressing modes)
- `BRA` - unconditional branch (relative)
- `TRB`, `TSB` - test and reset/set bits
- `INC A`, `DEC A` - increment/decrement accumulator
- `JMP (abs,X)` - indexed indirect jump
- New addressing modes for some existing instructions

Bug fixes:
- JMP indirect page-wrap bug fixed
- BCD mode flags properly defined

### Rockwell 65C02 (R65C02)
Additional instructions:
- `BBR0-7`, `BBS0-7` - branch on bit reset/set
- `RMB0-7`, `SMB0-7` - reset/set memory bit

### WDC 65C02 (W65C02)
Additional instructions:
- `WAI` - wait for interrupt
- `STP` - stop the processor

### CSG 65CE02
Significant extensions:
- `Z` register (fourth index register)
- 16-bit stack pointer option
- 16-bit branch offsets
- New addressing modes using Z
- `BSR` - branch to subroutine

### WDC 65816
Major upgrade:
- 16-bit accumulator and index registers (native mode)
- 24-bit address space (16MB)
- Emulation mode (E flag) for 6502 compatibility
- Direct page relocatable
- Many new instructions and addressing modes

---

## Integration with llvm-mos

### EmulatorEmitter (TableGen)

The SAIL specification is consumed by `llvm/utils/TableGen/EmulatorEmitter.cpp` which:
1. Parses SAIL Jib IR (compiled from SAIL via isla-sail plugin)
2. Generates C++ emulator code using `std::variant` for union types
3. Provides mapping between TableGen opcodes and SAIL instruction variants

The generated emulator is used for:
- Testing compiled code via `llvm-mc --run`
- LLDB integration (debugging MOS programs)
- Validation against hardware behavior

### Multiple Execution Paths

Developers can use whichever path fits their needs:

1. **Pure SAIL path** - Call `ztryStep()` directly
   - SAIL handles fetch, decode, execute
   - Full SAIL semantics, no TableGen involvement
   - Best for: standalone emulators, formal verification

2. **MCDisassembler + SAIL execute path**
   - Use LLVM's MCDisassembler to decode bytes to `MCInst`
   - Map `MCInst` to `zinstruction` variant via `mcInstToSail()`
   - Call `zexecute(zinstruction)` for SAIL semantics
   - Best for: debuggers, testing compilers, mixed environments

3. **TableGen `Emulate` field path**
   - Write instruction semantics directly in TableGen's `Emulate` field
   - Use `$Variable` references for composition and inheritance
   - No SAIL involvement at all
   - Best for: existing LLVM targets, custom semantic requirements

### TableGen Emulate Field

The `Emulate` field allows instruction semantics to be defined directly in TableGen
with variable substitution for composition. When the EmulatorEmitter sees `$Foo`,
it looks up field `Foo` on the instruction record (following TableGen inheritance).
>>30116344
>>30116360
>Grok allows this
>But a spreading pussy? NYOOO YOU CAN'T
>>
￼ Anonymous 01/15/26(Thu)18:44:37 No.30117449▶
>>30116297
First I made the image of a bimbo puerto rican whore with the peurto rican flag bikini laying flat on the floor, then i said the man with the bat is using the bat to hit the stomach cause she is choking. She is totally unconscious
>>
￼ Anonym

**Key features:**
- Variables can reference other variables, creating dependency chains
- The emitter resolves dependencies and emits setup code in correct order
- Multi-line code blocks: all lines except the last are setup statements,
  the last line is the expression assigned to the variable

**Example: Addressing modes define reusable fields**

```tablegen
// In MOSInstrFormats.td (or equivalent for your target)
class AddressingMode<int size> {
  int OperandSize = size;
  code EA = [{}];      // Effective address computation
  code Value = [{}];   // How to read the operand value
}

def Immediate : AddressingMode<1> {
  let Value = [{ (uint8_t)Inst.getOperand(0).getImm() }];
}

def ZeroPage : AddressingMode<1> {
  let EA = [{ (uint16_t)Inst.getOperand(0).getImm() }];
  let Value = [{ read($EA) }];  // References $EA - dependency resolved
}

def AbsoluteX : AddressingMode<2> {
  let Base = [{ (uint16_t)Inst.getOperand(0).getImm() }];
  let EA = [{ (uint16_t)($Base + X) }];  // References $Base
  let Value = [{ read($EA) }];
}
```

**Example: Instructions inherit from addressing modes**

```tablegen
// DRY style - emulation code shared across all addressing mode variants
let Emulate = [{ A |= $Value; setNZ(A); }] in {
  def ORA_Immediate : Inst<0x09, "ora", Immediate>;  // $Value from Immediate
  defm ORA          : Op<0x05, "ora", ZeroPage>;     // $Value from ZeroPage
  defm ORA          : Op<0x1D, "ora", AbsoluteX>;    // $Value from AbsoluteX
}

let Emulate = [{ A &= $Value; setNZ(A); }] in {
  def AND_Immediate : Inst<0x29, "and", Immediate>;
  defm AND          : Op<0x25, "and", ZeroPage>;
}
```

**Generated output (GET_EMULATOR_CASES):**

```cpp
case MOS::ORA_ZeroPage: {
  auto EA = (uint16_t)Inst.getOperand(0).getImm();
  auto Value = read(EA);
  A |= Value;
  setNZ(A);
  break;
}

case MOS::ORA_AbsoluteX: {
  auto Base = (uint16_t)Inst.getOperand(0).getImm();
  auto EA = (uint16_t)(Base + X);
  auto Value = read(EA);
  A |= Value;
  setNZ(A);
  break;
}
```

The variable substitution is **completely generic** - any `$Foo` reference looks up
field `Foo` on the record. Targets define whatever fields make sense for their
architecture (e.g., `$Src`, `$Dst`, `$Offset`, `$Condition`, etc.).

### MCInst to SAIL Mapping

Since SAIL unions are represented as `std::variant`, we need a mapping function
rather than a switch on instruction types. The EmulatorEmitter generates:

```cpp
// In MOSGenEmulator.inc (GET_EMULATOR_IMPL section)
zinstruction mcInstToSail(const MCInst &Inst) {
  switch (Inst.getOpcode()) {
  case MOS::LDA_imm:
    return zLDA_Immediate{static_cast<uint8_t>(Inst.getOperand(0).getImm())};
  case MOS::LDA_zp:
    return zLDA_ZeroPage{static_cast<uint8_t>(Inst.getOperand(0).getImm())};
  case MOS::LDA_abs:
    return zLDA_Absolute{static_cast<uint16_t>(Inst.getOperand(0).getImm())};
  // ... all 151 opcodes
  default:
    llvm_unreachable("Unknown MOS opcode");
  }
}
```

The user's `execute(MCInst)` becomes trivial:

```cpp
void MOS::Context::execute(const MCInst &Inst) {
  zexecute(mcInstToSail(Inst));
}
```

### Mapping Strategy

The mapping between TableGen opcodes and SAIL variants can be determined by:

1. **Auto-derived by name matching** (default)
   - Strip `z` prefix from SAIL variant name: `zLDA_Immediate` → `LDA_Immediate`
   - Normalize to match TableGen naming: `LDA_Immediate` → `LDA_imm`
   - The EmulatorEmitter builds this mapping automatically

2. **Explicitly specified in TableGen** (for exceptions)
   ```tablegen
   def LDA_imm : MOSInst<...> {
     let SailInstr = "zLDA_Immediate";  // Explicit mapping
   }
   ```
   This allows overriding the auto-match for instructions with non-standard names.

### Generated Code Structure

The EmulatorEmitter generates three sections in `MOSGenEmulator.inc`:

```cpp
#ifdef GET_EMULATOR_TYPES
// Enum constants for simple enums
static constexpr int AM_Immediate = 0;
static constexpr int AM_ZeroPage = 1;
// ...

// Struct wrappers for union variants
struct zLDA_Immediate { uint8_t val; };
struct zLDA_ZeroPage { uint8_t val; };
// ...

// std::variant type aliases
using zinstruction = std::variant<zLDA_Immediate, zLDA_ZeroPage, ...>;
using zExecutionResult = std::variant<zER_Success, zER_IllegalOpcode, ...>;
#endif

#ifdef GET_EMULATOR_METHODS
// Helper functions from SAIL (setNZ, doADC, push, pop, etc.)
void zsetNZ(uint8_t val) { ... }
void zdoADC(uint8_t val) { ... }
// ...

// The execute function (uses std::visit internally)
zExecutionResult zexecute(zinstruction instr) { ... }
#endif

#ifdef GET_EMULATOR_IMPL
// MCInst to SAIL instruction mapping
zinstruction mcInstToSail(const MCInst &Inst) { ... }
#endif
```

### z-Prefix Convention

SAIL's Jib IR uses a `z` prefix on all identifiers to avoid collisions with
C++ reserved words and our own code. We preserve this prefix in generated code:

| SAIL Name | Generated C++ | Purpose |
|-----------|---------------|---------|
| `instruction` | `zinstruction` | Instruction union type |
| `execute` | `zexecute` | Execute function |
| `LDA_Immediate` | `zLDA_Immediate` | Union variant struct |
| `A`, `X`, `Y` | `zA`, `zX`, `zY` | Register aliases |
| `readMem` | `zreadMem` | Memory access wrapper |

The `emu::Context` base class provides z-prefixed wrappers for common operations:
```cpp
uint8_t zreadMem(uint64_t Addr) { return read(Addr); }
void zwriteMem(uint64_t Addr, uint8_t Value) { write(Addr, Value); }
```

And `MOS::Context` provides register aliases:
```cpp
uint8_t &zA = A;
uint8_t &zX = X;
bool &zC = C;
// etc.
```

### File Location

Current: `llvm/lib/Target/MOS/Sail/mos6502.sail`

Proposed (after redesign):
```
llvm/lib/Target/MOS/Sail/
├── 65xx.sail_project
├── prelude/
├── core/
├── sys/
├── instructions/
├── postlude/
└── variants/
```

### Build Integration

The SAIL files are processed during the LLVM build when the MOS target is enabled:

1. **SAIL → Jib IR**: Run `sail -plugin isla-sail -isla -o mos6502 *.sail`
   - This produces `mos6502.ir` (checked into repo)
   - Only needed when SAIL source changes: `ninja mos-sail-ir`

2. **Jib IR → C++**: Run `llvm-tblgen -gen-emulator -sail-ir=mos6502.ir`
   - This produces `MOSGenEmulator.inc`
   - Happens automatically during build

The EmulatorEmitter reads the SAIL Jib IR and generates:
- `MOSGenEmulator.inc` - types, helper functions, execute, mapping

---

## References

- sail-riscv repository: `~/git/sail-riscv`
- sail-riscv ReadingGuide: `~/git/sail-riscv/doc/ReadingGuide.md`
- Current MOS 6502 spec: `llvm/lib/Target/MOS/Sail/mos6502.sail`
- Sail language manual: https://alasdair.github.io/manual.html
- 6502 reference: http://www.obelisk.me.uk/6502/reference.html
- 65C02 additions: http://www.obelisk.me.uk/65C02/reference.html
- 65816 reference: https://www.westerndesigncenter.com/wdc/documentation/w65c816s.pdf