# Adding SAIL-Based Emulation to Your LLVM Target

## Overview

The EmulatorEmitter TableGen backend generates C++ emulator code from SAIL specifications. This lets you get a complete instruction emulator for free if your architecture has a SAIL model.

**Why SAIL?** Major architectures already have officially maintained SAIL specs:
- **RISC-V**: sail-riscv (maintained by RISC-V Foundation)
- **AArch64**: sail-arm (maintained by ARM)
- **x86**: sail-x86 (community)

The EmulatorEmitter is **100% target-agnostic**. It works for any architecture.

---

## Quick Start: What You Need

To add SAIL-based emulation to your target:

1. **A SAIL specification** (`your_arch.sail`)
2. **Jib IR file** generated from SAIL (`your_arch.ir`)
3. **A Context class** that provides register aliases and memory access

---

## Step 1: Write Your SAIL Specification

Your SAIL model defines CPU semantics. Key elements:

```sail
// Registers
register A : bits(8)
register PC : bits(16)
register N : bits(1)  // Negative flag

// Instruction union - one variant per instruction
union instruction = {
  LDA_Immediate : bits(8),
  LDA_ZeroPage : bits(8),
  JMP_Absolute : bits(16),
  // ...
}

// Execute function - dispatches by instruction type
function execute(instr : instruction) -> unit = {
  match instr {
    LDA_Immediate(imm) => { A = imm; setNZ(A) },
    LDA_ZeroPage(addr) => { A = readMem(addr); setNZ(A) },
    JMP_Absolute(addr) => { PC = addr },
    // ...
  }
}

// Helper functions
function setNZ(val : bits(8)) -> unit = {
  N = val[7..7];
  Z = if val == 0x00 then 0b1 else 0b0;
}
```

---

## Step 2: Generate Jib IR

Use isla-sail to compile SAIL to Jib IR:

```bash
sail -plugin ${ISLA_PLUGIN} -isla \
  -isla_preserve execute \
  -isla_preserve checkAndHandleIRQ \
  -o your_arch.ir \
  your_arch.sail
```

The `-isla_preserve` flag ensures standalone functions are included (by default, only code reachable from `execute` is emitted).

Place the `.ir` file in `llvm/lib/Target/YourTarget/Sail/`.

---

## Step 3: Configure TableGen

In your target's `CMakeLists.txt`, add the emulator generation:

```cmake
tablegen(LLVM YourTargetGenEmulator.inc -gen-emulator
         -sail-ir=${CMAKE_CURRENT_SOURCE_DIR}/Sail/your_arch.ir)
```

This generates `YourTargetGenEmulator.inc` with three sections:

| Section | Contents |
|---------|----------|
| `GET_EMULATOR_TYPES` | Enums, struct wrappers, `std::variant` type aliases |
| `GET_EMULATOR_METHODS` | Helper functions as class methods |
| `GET_EMULATOR_IMPL` | Switch cases for instruction dispatch |

---

## Step 4: Create Your Context Class

The Context class bridges SAIL-generated code with your emulator runtime.

```cpp
// YourTargetContext.h
#include "llvm/Emulator/Context.h"
#include <variant>

namespace YourTarget {

// Pull in SAIL-generated types (enums, instruction union)
#define GET_EMULATOR_TYPES
#include "YourTargetGenEmulator.inc"
#undef GET_EMULATOR_TYPES

class Context : public emu::Context {
public:
  // Your registers (use whatever names make sense)
  uint8_t A = 0;
  uint16_t PC = 0;
  bool N = false;
  bool Z = false;

  // SAIL register aliases - SAIL code uses z-prefixed names
  uint8_t &zA = A;
  uint16_t &zPC = PC;
  bool &zN = N;
  bool &zZ = Z;

  // Memory access - SAIL calls zreadMem/zwriteMem
  uint8_t zreadMem(uint16_t addr) { return read(addr); }
  void zwriteMem(uint16_t addr, uint8_t val) { write(addr, val); }

  // Pull in SAIL-generated helper functions
#define GET_EMULATOR_METHODS
#include "YourTargetGenEmulator.inc"
#undef GET_EMULATOR_METHODS

  // Your step() implementation
  bool step() override;
};

} // namespace YourTarget
```

### Why Z-Prefixes?

SAIL's Jib IR uses z-encoding for all identifiers (`zA`, `zPC`, `zreadMem`). The EmulatorEmitter preserves these prefixes to avoid collisions with your own code. Your Context provides aliases that map z-prefixed names to your actual registers.

---

## Step 5: Implement step()

Your `step()` function can use SAIL-generated code in several ways:

### Option A: Use SAIL's Full Execution Loop

If your SAIL model has `tryStep()` or similar:

```cpp
bool Context::step() {
  return ztryStep();  // SAIL handles fetch, decode, execute
}
```

### Option B: Use LLVM's MCDisassembler + SAIL Execute

```cpp
bool Context::step() {
  // Fetch and decode using LLVM
  MCInst Inst;
  uint64_t Size;
  ArrayRef<uint8_t> Code = getCodeAt(PC);
  Disassembler->getInstruction(Inst, Size, Code, PC, nulls());

  // Convert MCInst to SAIL instruction variant
  zinstruction SailInst = mcInstToSail(Inst);

  // Execute using SAIL-generated code
  zexecute(SailInst);

  PC += Size;
  return true;
}
```

### Option C: Hybrid Approach

Use SAIL for complex instructions, custom code for simple ones:

```cpp
void Context::execute(const MCInst &Inst) {
  switch (Inst.getOpcode()) {
  case NOP:
    // Trivial - no need for SAIL
    break;
  default:
    // Use SAIL for everything else
    zexecute(mcInstToSail(Inst));
  }
}
```

---

## Function Types in Generated Code

The emitter generates two kinds of functions:

### Primitive Functions (Builtins)

These are SAIL library operations that the emitter implements directly:

```cpp
// Arithmetic
uint64_t zadd_bits(uint64_t a, uint64_t b) { return a + b; }

// Bit operations
uint64_t zsubrange_bits(uint64_t val, int64_t hi, int64_t lo) {
  return (val >> lo) & ((1ULL << (hi - lo + 1)) - 1);
}

// Type conversions
int64_t zsail_signed(uint64_t val) { return (int64_t)val; }
```

### SAIL-Defined Functions

Functions written in your SAIL spec are translated to C++:

```cpp
// From SAIL: function setNZ(val) = { N = val[7]; Z = val == 0 }
void zsetNZ(uint8_t zval) {
  zN = (zval >> 7) & 1;
  zZ = zval == 0;
}
```

---

## Design Principles

When implementing emulator features, prefer existing machinery:

1. **LLVM machinery first** - MCDisassembler for decode, TableGen for instruction metadata
2. **SAIL machinery second** - CPU semantics (execution, flags, IRQ handling)
3. **Custom code last** - Only for glue between LLVM and SAIL

This keeps CPU behavior in SAIL where it can be formally verified, while leveraging LLVM's mature infrastructure for everything else.

---

## Troubleshooting

### Missing Functions

If you get undefined references to SAIL functions, ensure they're preserved:

```bash
sail -isla_preserve functionName ...
```

### Type Mismatches

SAIL's `%bv` (untyped bitvector) defaults to `uint64_t`. If you need specific widths, declare them explicitly in your SAIL spec.

### Register Aliases Not Working

Make sure your Context class defines aliases for ALL registers used by SAIL code:

```cpp
// If SAIL uses zFoo, you need:
YourType &zFoo = Foo;
```
