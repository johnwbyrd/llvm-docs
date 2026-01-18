# Halt Opcode Support for llvm-mc Emulator

## Overview

Allow targets to declare certain instructions as "halt instructions" that gracefully end emulation. Users can override with a regex pattern for flexibility.

## Design Goals

1. **Fast by default**: TableGen `HaltEmulation` flag checked via TSFlags bit (single bit test)
2. **User override**: `--run-halt-pattern=<regex>` for flexibility when needed
3. **Disable option**: `--run-halt-pattern=none` disables all instruction-based halting
4. **Architecture agnostic**: Works regardless of instruction encoding

## Performance Hierarchy

| Mode | Performance | Use Case |
|------|-------------|----------|
| TableGen flag (default) | Fastest | Normal operation - single bit test per instruction |
| `--run-halt-pattern=none` | Fast | Disable halt checking entirely |
| `--run-halt-pattern=<regex>` | Slowest | User needs custom halt behavior |

## Command-Line Interface

```
--run-halt-pattern=<regex>   Override TableGen defaults with regex matching
--run-halt-pattern=none      Disable instruction-based halting entirely
(no option)                  Use TableGen HaltEmulation flags (default, fast)
```

Examples:
- (default) - use TableGen flags (BRK halts on 6502, STP halts on 65C02, etc.)
- `--run-halt-pattern="brk|stp"` - override to halt on BRK or STP
- `--run-halt-pattern="hlt|int3"` - x86 style halts
- `--run-halt-pattern=none` - never halt on instruction (rely on semihosting/cycle limit)

---

## Current Code Structure

### TSFlags Layout (MOSInstrFormats.td lines 204-253)

```
Bits 0-3:   65816 M/X flag requirements
Bits 4-11:  Base cycle count (8 bits, 0-255)
Bits 12-15: Page cross penalty cycles (4 bits, 0-15)
Bits 16-29: Flag effects (2 bits each, 7 flags)
Bits 30+:   AVAILABLE for HaltEmulation
```

The next available bit is **bit 30**.

### Current BRK Definition (MOSInstr6502.td lines 20-32)

```tablegen
// BRK - Break (software interrupt)
// Pushes PC+2 and P (with B flag set), then loads IRQ/BRK vector
let Cycles6502 = 7, FlagB = 2, FlagI = 2,
    Emulate = [{
  uint16_t ret = PC + 2;
  push((ret >> 8) & 0xFF);
  push(ret & 0xFF);
  push(getP() | 0x30);  // B and unused flag set
  I = true;
  PC = read(0xFFFE) | (read(0xFFFF) << 8);
  PCModified = true;
}] in
def BRK_Implied    : MOSInst<0x00, "brk", Implicit>, TraitUnconditionalBranch;
```

### MOSContext::step() (MOSContext.cpp lines 66-143)

Key variables available in step():
- `MCInst Inst` - the decoded instruction
- `const MCInstrDesc &Desc = InstrInfo->get(Inst.getOpcode())`
- `uint64_t TSFlags = Desc.TSFlags`
- `PC`, `Halted`, `ExitCode_` - CPU state

The halt check should go **after** execute() returns (line 119), before cycle accumulation.

### TSFlags Accessors (MOSMCTargetDesc.h lines 86-212)

Already has pattern for adding accessors:
```cpp
namespace TSFlagBits {
  constexpr unsigned CyclesShift = 4;
  constexpr uint64_t CyclesMask = 0xFFULL << CyclesShift;
  // ... etc
}

inline unsigned getCycles(uint64_t TSFlags) {
  return (TSFlags & TSFlagBits::CyclesMask) >> TSFlagBits::CyclesShift;
}
```

---

## Implementation Plan

### Step 1: Add HaltEmulation to TSFlags (MOSInstrFormats.td)

Add to `class Inst<string asmstr>` around line 254:

```tablegen
  //=========================================================================
  // Emulator Halt Flag (bit 30)
  //=========================================================================
  // When set, executing this instruction halts the emulator.
  bit HaltEmulation = 0;
  let TSFlags{30} = HaltEmulation;
```

### Step 2: Add TSFlags Accessor (MOSMCTargetDesc.h)

Add to `namespace TSFlagBits` around line 128:

```cpp
  // Halt emulation flag
  constexpr unsigned HaltEmulationShift = 30;
  constexpr uint64_t HaltEmulationMask = 1ULL << HaltEmulationShift;
```

Add accessor function around line 181:

```cpp
/// Returns true if executing this instruction should halt the emulator.
inline bool getHaltEmulation(uint64_t TSFlags) {
  return (TSFlags & TSFlagBits::HaltEmulationMask) != 0;
}
```

### Step 3: Mark BRK as Halt Instruction (MOSInstr6502.td)

Change line 22 from:
```tablegen
let Cycles6502 = 7, FlagB = 2, FlagI = 2,
```

To:
```tablegen
let Cycles6502 = 7, FlagB = 2, FlagI = 2, HaltEmulation = 1,
```

### Step 4: Add Halt Check to MOSContext::step() (MOSContext.cpp)

Add after `execute(Inst);` (after line 119), before cycle accumulation:

```cpp
  // Execute the instruction
  PCModified = false;
  DidPageCross = false;
  uint16_t PrePC = PC;
  execute(Inst);

  // Check for halt instruction (fast path - single bit test)
  const MCInstrDesc &Desc = InstrInfo->get(Inst.getOpcode());
  uint64_t TSFlags = Desc.TSFlags;
  if (MOS::getHaltEmulation(TSFlags)) {
    halt(0);  // Exit code 0 for normal halt
    return true;
  }

  // Accumulate cycles from instruction TSFlags
  unsigned BaseCycles = MOS::getCycles(TSFlags);
  // ... rest unchanged
```

**Note:** The `Desc` and `TSFlags` variables are already computed below for cycle counting. Move them up and reuse.

### Step 5: Add Command-Line Override (llvm-mc.cpp)

Add option around line 273:

```cpp
static cl::opt<std::string>
    RunHaltPattern("run-halt-pattern",
                   cl::desc("Override halt instructions with regex pattern "
                            "('none' to disable, omit for TableGen defaults)"),
                   cl::cat(MCCategory));
```

### Step 6: Wire Override to Context (llvm-mc.cpp RunObject function)

Add after creating emulator (after line 454):

```cpp
  // Configure halt pattern override (only if user specified)
  if (RunHaltPattern.getNumOccurrences() > 0)
    Emu->setHaltPattern(RunHaltPattern);
```

### Step 7: Add Override Support to emu::Context Base Class

**File: llvm/include/llvm/Emulator/Context.h**

Add members:
```cpp
protected:
  // Halt pattern override
  std::optional<llvm::Regex> HaltPatternOverride;
  bool HaltCheckingDisabled = false;

public:
  /// Set halt pattern override. Empty = use TableGen defaults.
  /// "none" = disable halt checking. Anything else = regex pattern.
  void setHaltPattern(StringRef Pattern);

  /// Check if we need mnemonic string for halt check (slow path active)
  bool needsMnemonicForHalt() const { return HaltPatternOverride.has_value(); }
```

**File: llvm/lib/Emulator/Context.cpp**

```cpp
void Context::setHaltPattern(StringRef Pattern) {
  if (Pattern.empty()) {
    // Empty = use TableGen defaults
    HaltPatternOverride.reset();
    HaltCheckingDisabled = false;
  } else if (Pattern == "none") {
    // Disable all halt checking
    HaltPatternOverride.reset();
    HaltCheckingDisabled = true;
  } else {
    // User-specified regex
    HaltPatternOverride.emplace(Pattern);
    HaltCheckingDisabled = false;
  }
}
```

### Step 8: Update MOSContext to Use Override (MOSContext.cpp)

Replace the simple halt check with:

```cpp
  // Check for halt instruction
  const MCInstrDesc &Desc = InstrInfo->get(Inst.getOpcode());
  uint64_t TSFlags = Desc.TSFlags;

  if (!HaltCheckingDisabled) {
    if (HaltPatternOverride) {
      // Slow path: regex match against mnemonic
      // getMnemonic() returns pair<const char*, uint64_t> where first is the mnemonic
      if (InstPrinter) {
        auto [Mnemonic, Bits] = InstPrinter->getMnemonic(Inst);
        if (Mnemonic && HaltPatternOverride->match(Mnemonic)) {
          halt(0);
          return true;
        }
      }
    } else {
      // Fast path: just check TSFlags bit
      if (MOS::getHaltEmulation(TSFlags)) {
        halt(0);
        return true;
      }
    }
  }
```

---

## Testing

### Test 1: Default behavior (TableGen flags)

```bash
cat > /tmp/test_halt.s << 'EOF'
.text
_start:
  lda #$42
  brk
EOF

llvm-mc --triple=mos -filetype=obj -o /tmp/test.o --run --trace /tmp/test_halt.s
# Should halt after BRK (TableGen HaltEmulation=1), exit code 0
echo $?  # Should print 0
```

### Test 2: Override with regex

```bash
# Halt on NOP instead of BRK
llvm-mc --triple=mos --run --run-halt-pattern="nop" --trace /tmp/test_halt.s
# Should NOT halt on BRK (override active), hits cycle limit
echo $?  # Should print 1 (cycle limit error)
```

### Test 3: Disable halt checking

```bash
llvm-mc --triple=mos --run --run-halt-pattern=none --run-max-cycles=100 --trace /tmp/test_halt.s
# Should hit cycle limit, not halt on BRK
echo $?  # Should print 1 (cycle limit error)
```

---

## Migration Notes

- Default behavior changes: BRK will halt by default (via TableGen flag)
- Programs using BRK as software interrupt need `--run-halt-pattern=none`
- This is the expected behavior for simple test programs

## Halt Instructions by Architecture

For reference, common halt instructions to mark with `HaltEmulation = 1`:

| Architecture | Instructions |
|--------------|--------------|
| 6502         | BRK |
| 65C02        | BRK, STP |
| 65816        | BRK, STP |
| x86          | HLT |
| ARM          | BKPT, WFI, WFE |
| RISC-V       | EBREAK |
| Z80          | HALT |
| 68000        | STOP, TRAP |

## Future Extensions

1. **Halt with exit code**: Read exit code from register (e.g., A) on halt
2. **Multiple halt modes**: Distinguish between "halt" and "break" (debugger pause)
3. **Conditional halts**: Halt only if condition met
