# RISC-V Emulation Support in LLVM

This document describes a plan for adding emulation support to the RISC-V target in LLVM, leveraging the existing EmulatorEmitter infrastructure developed for MOS.

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Composition Strategies](#composition-strategies)
4. [Implementation Plan](#implementation-plan)
5. [Phase 1: Infrastructure](#phase-1-infrastructure)
6. [Phase 2: RV32I Base Instructions](#phase-2-rv32i-base-instructions)
7. [Phase 3: Extensions](#phase-3-extensions)
8. [Phase 4: System Features](#phase-4-system-features)
9. [SAIL Integration (Optional)](#sail-integration-optional)
10. [Testing Strategy](#testing-strategy)
11. [Open Questions](#open-questions)

---

## Overview

### Goal

Enable `llvm-mc --triple=riscv32 --run program.elf` to execute RISC-V programs, using the same emulator infrastructure as MOS.

### Key Insight

The EmulatorEmitter is **target-agnostic**. It processes TableGen's `Emulate` field via `$Variable` substitution to generate C++ switch cases. RISC-V can use this same mechanism - the only question is how to define `Emulate` for each instruction.

### Composition Over Specification

There are multiple ways to define `Emulate`:

| Approach | Example | When to Use |
|----------|---------|-------------|
| Hand-written | `X[$rd] = X[$rs1] + X[$rs2];` | Simple instructions |
| Format classes | `class ALU_rr<op>` composing `$Operation` | Groups of similar instructions |
| SAIL calls | `zexecute(zRTYPE{...})` | Complex semantics, formal verification needed |
| Mixed | Hand-written with SAIL helpers | Best of both worlds |

**The EmulatorEmitter doesn't care how you got there.** It just sees the final `Emulate` string and generates code.

---

## Architecture

### Component Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                         TableGen                                 │
│                                                                  │
│  RISCVInstrInfo.td                                              │
│       │                                                          │
│       ▼                                                          │
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐            │
│  │ RVInstR     │   │ RVInstI     │   │ RVInstU     │  ...       │
│  │ (format)    │   │ (format)    │   │ (format)    │            │
│  └──────┬──────┘   └──────┬──────┘   └──────┬──────┘            │
│         │                 │                 │                    │
│         └─────────────────┴─────────────────┘                    │
│                           │                                      │
│                           ▼                                      │
│                    ┌─────────────┐                               │
│                    │  Emulate    │  Final composed string        │
│                    └──────┬──────┘                               │
│                           │                                      │
└───────────────────────────┼──────────────────────────────────────┘
                            │
                            ▼
                     EmulatorEmitter
                            │
                            ▼
                  RISCVGenEmulator.inc
                            │
                            ▼
┌───────────────────────────────────────────────────────────────────┐
│                      RISCV::Context                               │
│                                                                   │
│  uint32_t X[32];        // General purpose registers              │
│  uint32_t PC;           // Program counter                        │
│  // ... CSRs, privilege mode, etc.                                │
│                                                                   │
│  #define GET_EMULATOR_IMPL                                        │
│  #include "RISCVGenEmulator.inc"                                  │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

### File Structure

```
llvm/lib/Target/RISCV/
├── RISCVInstrInfo.td          # Add Emulate fields
├── RISCVInstrFormatsEmu.td    # NEW: Emulation format classes
├── Emulator/
│   ├── CMakeLists.txt
│   ├── RISCVContext.h         # Context class declaration
│   └── RISCVContext.cpp       # Context implementation
└── Sail/                       # Optional SAIL integration
    └── riscv.ir               # Jib IR from sail-riscv
```

---

## Composition Strategies

### Strategy 1: Format-Based Composition (Recommended)

Define emulation behavior in format classes, then inherit:

```tablegen
//===-- RISCVInstrFormatsEmu.td - Emulation mixins --------*- tablegen -*-===//

// Operand extraction helpers
class RVEmuOperands {
  // Register operands - extract register number from MCInst
  code rd  = [{ (Inst.getOperand(0).getReg() - RISCV::X0) }];
  code rs1 = [{ (Inst.getOperand(1).getReg() - RISCV::X0) }];
  code rs2 = [{ (Inst.getOperand(2).getReg() - RISCV::X0) }];

  // Immediate operands - position varies by format
  code imm12 = [{ Inst.getOperand(2).getImm() }];
  code imm20 = [{ Inst.getOperand(1).getImm() }];
}

// R-type: rd = rs1 op rs2
class RVEmuRType<code operation> : RVEmuOperands {
  let Emulate = [{
    uint32_t lhs = X[$rs1];
    uint32_t rhs = X[$rs2];
    X[$rd] = }] # operation # [{;
  }];
}

// I-type arithmetic: rd = rs1 op imm
class RVEmuIType<code operation> : RVEmuOperands {
  let Emulate = [{
    uint32_t lhs = X[$rs1];
    int32_t imm = signExtend($imm12, 12);
    X[$rd] = }] # operation # [{;
  }];
}

// U-type: rd = imm << 12 (optionally + PC)
class RVEmuUType<bit addPC = 0> : RVEmuOperands {
  let Emulate = !if(addPC,
    [{ X[$rd] = PC + ($imm20 << 12); }],
    [{ X[$rd] = $imm20 << 12; }]
  );
}

// Load: rd = memory[rs1 + imm]
class RVEmuLoad<int width, bit signExt = 1> : RVEmuOperands {
  let Emulate = [{
    uint32_t addr = X[$rs1] + signExtend($imm12, 12);
    X[$rd] = }] # !if(signExt, "signExtend(", "zeroExtend(") #
    [{read}] # width # [{(addr), }] # width # [{);
  }];
}

// Store: memory[rs1 + imm] = rs2
class RVEmuStore<int width> : RVEmuOperands {
  let Emulate = [{
    uint32_t addr = X[$rs1] + signExtend($imm12, 12);
    write}] # width # [{(addr, X[$rs2]);
  }];
}

// Branch: if (condition) PC = PC + imm
class RVEmuBranch<string cond> : RVEmuOperands {
  code branchImm = [{ Inst.getOperand(2).getImm() }];
  let Emulate = [{
    if (}] # cond # [{)
      NextPC = PC + signExtend($branchImm, 13);
  }];
}
```

### Using the Format Classes

```tablegen
//===-- RISCVInstrInfo.td - Add emulation to instructions -----*- tablegen -*-===//

// Arithmetic R-type
def ADD  : ALU_rr<...>, RVEmuRType<[{ lhs + rhs }]>;
def SUB  : ALU_rr<...>, RVEmuRType<[{ lhs - rhs }]>;
def AND  : ALU_rr<...>, RVEmuRType<[{ lhs & rhs }]>;
def OR   : ALU_rr<...>, RVEmuRType<[{ lhs | rhs }]>;
def XOR  : ALU_rr<...>, RVEmuRType<[{ lhs ^ rhs }]>;
def SLL  : ALU_rr<...>, RVEmuRType<[{ lhs << (rhs & 0x1F) }]>;
def SRL  : ALU_rr<...>, RVEmuRType<[{ lhs >> (rhs & 0x1F) }]>;
def SRA  : ALU_rr<...>, RVEmuRType<[{ (int32_t)lhs >> (rhs & 0x1F) }]>;
def SLT  : ALU_rr<...>, RVEmuRType<[{ (int32_t)lhs < (int32_t)rhs ? 1 : 0 }]>;
def SLTU : ALU_rr<...>, RVEmuRType<[{ lhs < rhs ? 1 : 0 }]>;

// Arithmetic I-type
def ADDI  : ALU_ri<...>, RVEmuIType<[{ lhs + imm }]>;
def ANDI  : ALU_ri<...>, RVEmuIType<[{ lhs & imm }]>;
def ORI   : ALU_ri<...>, RVEmuIType<[{ lhs | imm }]>;
def XORI  : ALU_ri<...>, RVEmuIType<[{ lhs ^ imm }]>;
def SLTI  : ALU_ri<...>, RVEmuIType<[{ (int32_t)lhs < imm ? 1 : 0 }]>;
def SLTIU : ALU_ri<...>, RVEmuIType<[{ lhs < (uint32_t)imm ? 1 : 0 }]>;

// Shifts with immediate
def SLLI : ALU_ri<...>, RVEmuOperands {
  let Emulate = [{ X[$rd] = X[$rs1] << ($imm12 & 0x1F); }];
}
def SRLI : ALU_ri<...>, RVEmuOperands {
  let Emulate = [{ X[$rd] = X[$rs1] >> ($imm12 & 0x1F); }];
}
def SRAI : ALU_ri<...>, RVEmuOperands {
  let Emulate = [{ X[$rd] = (int32_t)X[$rs1] >> ($imm12 & 0x1F); }];
}

// U-type
def LUI   : RVInstU<...>, RVEmuUType<0>;  // rd = imm << 12
def AUIPC : RVInstU<...>, RVEmuUType<1>;  // rd = PC + (imm << 12)

// Loads
def LB  : Load_ri<...>, RVEmuLoad<8, 1>;   // sign-extended byte
def LBU : Load_ri<...>, RVEmuLoad<8, 0>;   // zero-extended byte
def LH  : Load_ri<...>, RVEmuLoad<16, 1>;  // sign-extended half
def LHU : Load_ri<...>, RVEmuLoad<16, 0>;  // zero-extended half
def LW  : Load_ri<...>, RVEmuLoad<32, 1>;  // word

// Stores
def SB : Store_rri<...>, RVEmuStore<8>;
def SH : Store_rri<...>, RVEmuStore<16>;
def SW : Store_rri<...>, RVEmuStore<32>;

// Branches
def BEQ  : Branch<...>, RVEmuBranch<"X[$rs1] == X[$rs2]">;
def BNE  : Branch<...>, RVEmuBranch<"X[$rs1] != X[$rs2]">;
def BLT  : Branch<...>, RVEmuBranch<"(int32_t)X[$rs1] < (int32_t)X[$rs2]">;
def BGE  : Branch<...>, RVEmuBranch<"(int32_t)X[$rs1] >= (int32_t)X[$rs2]">;
def BLTU : Branch<...>, RVEmuBranch<"X[$rs1] < X[$rs2]">;
def BGEU : Branch<...>, RVEmuBranch<"X[$rs1] >= X[$rs2]">;

// Jumps
def JAL : RVInstJ<...>, RVEmuOperands {
  code jimm = [{ Inst.getOperand(1).getImm() }];
  let Emulate = [{
    X[$rd] = PC + 4;
    NextPC = PC + signExtend($jimm, 21);
  }];
}

def JALR : RVInstI<...>, RVEmuOperands {
  let Emulate = [{
    uint32_t target = (X[$rs1] + signExtend($imm12, 12)) & ~1;
    X[$rd] = PC + 4;
    NextPC = target;
  }];
}
```

### Strategy 2: Hand-Written (For Complex Cases)

Some instructions are complex enough that composition doesn't help:

```tablegen
def FENCE : RVInstI<...> {
  let Emulate = [{
    // Memory fence - no-op in simple emulator
    // Could add memory barrier for multi-threaded emulation
  }];
}

def ECALL : RVInstI<...> {
  let Emulate = [{
    handleTrap(TrapCause::ECALL_FROM_M);
  }];
}

def EBREAK : RVInstI<...> {
  let Emulate = [{
    handleTrap(TrapCause::BREAKPOINT);
  }];
}

def MRET : RVInstR<...> {
  let Emulate = [{
    // Restore privilege mode and PC from CSRs
    PrivilegeMode = (mstatus >> 11) & 0x3;
    NextPC = mepc;
    // Update mstatus.MIE from mstatus.MPIE
    mstatus = (mstatus & ~0x8) | ((mstatus >> 4) & 0x8);
  }];
}
```

### Strategy 3: SAIL Integration (For Formal Verification)

If you want to use sail-riscv semantics:

```tablegen
// Mixin that calls into SAIL-generated code
class RVSailRType<string op> : RVEmuOperands {
  let Emulate = [{
    zexecute(zRTYPE{(uint8_t)$rs2, (uint8_t)$rs1, (uint8_t)$rd, z}] # op # [{});
  }];
}

// Use SAIL for formally verified semantics
def ADD : ALU_rr<...>, RVSailRType<"ADD">;
def SUB : ALU_rr<...>, RVSailRType<"SUB">;
```

This requires generating SAIL types and `zexecute()` from `sail-riscv` Jib IR.

---

## Implementation Plan

### Prerequisites

- [ ] Existing EmulatorEmitter infrastructure (from MOS work)
- [ ] `emu::Context` base class
- [ ] `emu::System` and `emu::Memory` classes
- [ ] `llvm-mc --run` support

### Phases Overview

| Phase | Scope | Instructions | Effort |
|-------|-------|--------------|--------|
| 1 | Infrastructure | 0 | 1 week |
| 2 | RV32I base | 47 | 2 weeks |
| 3a | M extension | 8 | 2-3 days |
| 3b | A extension | 11 | 1 week |
| 3c | C extension | ~50 | 1-2 weeks |
| 4 | CSRs + traps | N/A | 2 weeks |
| 5 | F/D extensions | ~50 | 3-4 weeks |

---

## Phase 1: Infrastructure

### 1.1 Create RISCV::Context Class

```cpp
// llvm/lib/Target/RISCV/Emulator/RISCVContext.h

#ifndef LLVM_LIB_TARGET_RISCV_EMULATOR_RISCVCONTEXT_H
#define LLVM_LIB_TARGET_RISCV_EMULATOR_RISCVCONTEXT_H

#include "llvm/Emulator/Context.h"
#include "llvm/MC/MCDisassembler/MCDisassembler.h"
#include "llvm/MC/MCInstrInfo.h"

namespace llvm {
namespace RISCV {

class Context : public emu::Context {
public:
  // General purpose registers (x0 is hardwired to 0)
  uint32_t X[32] = {0};

  // Program counter
  uint32_t PC = 0;
  uint32_t NextPC = 0;

  // Privilege mode (0=User, 1=Supervisor, 3=Machine)
  uint8_t PrivilegeMode = 3;  // Start in M-mode

  // Key CSRs (add more as needed)
  uint32_t mstatus = 0;
  uint32_t mtvec = 0;
  uint32_t mepc = 0;
  uint32_t mcause = 0;
  uint32_t mtval = 0;
  uint32_t mie = 0;
  uint32_t mip = 0;

  // Cycle counter
  uint64_t Cycles = 0;

  Context(emu::System &Sys, const MCDisassembler &Dis,
          const MCInstrInfo &MII);

  bool step() override;
  void reset() override;

  // Register access (x0 always returns 0)
  uint32_t readReg(unsigned Reg) const {
    return Reg == 0 ? 0 : X[Reg];
  }

  void writeReg(unsigned Reg, uint32_t Value) {
    if (Reg != 0) X[Reg] = Value;
  }

  // CSR access
  uint32_t readCSR(unsigned CSR);
  void writeCSR(unsigned CSR, uint32_t Value);

  // Trap handling
  void handleTrap(uint32_t Cause, uint32_t TVal = 0);

private:
  const MCDisassembler &Disassembler;
  const MCInstrInfo &InstrInfo;

  // Execute a decoded instruction
  void execute(const MCInst &Inst);

  // Helper functions
  static int32_t signExtend(uint32_t Value, unsigned Bits) {
    uint32_t SignBit = 1U << (Bits - 1);
    return (Value ^ SignBit) - SignBit;
  }

  // Memory access helpers
  uint8_t read8(uint32_t Addr) { return read(Addr); }
  uint16_t read16(uint32_t Addr) {
    return read(Addr) | (read(Addr + 1) << 8);
  }
  uint32_t read32(uint32_t Addr) {
    return read(Addr) | (read(Addr + 1) << 8) |
           (read(Addr + 2) << 16) | (read(Addr + 3) << 24);
  }

  void write8(uint32_t Addr, uint8_t Val) { write(Addr, Val); }
  void write16(uint32_t Addr, uint16_t Val) {
    write(Addr, Val & 0xFF);
    write(Addr + 1, (Val >> 8) & 0xFF);
  }
  void write32(uint32_t Addr, uint32_t Val) {
    write(Addr, Val & 0xFF);
    write(Addr + 1, (Val >> 8) & 0xFF);
    write(Addr + 2, (Val >> 16) & 0xFF);
    write(Addr + 3, (Val >> 24) & 0xFF);
  }

  // Include generated emulator code
  #define GET_EMULATOR_IMPL
  #include "RISCVGenEmulator.inc"
  #undef GET_EMULATOR_IMPL
};

} // namespace RISCV
} // namespace llvm

#endif
```

### 1.2 Implement step() and execute()

```cpp
// llvm/lib/Target/RISCV/Emulator/RISCVContext.cpp

#include "RISCVContext.h"
#include "llvm/MC/MCInst.h"

using namespace llvm;
using namespace llvm::RISCV;

Context::Context(emu::System &Sys, const MCDisassembler &Dis,
                 const MCInstrInfo &MII)
    : emu::Context(Sys), Disassembler(Dis), InstrInfo(MII) {
  reset();
}

void Context::reset() {
  std::fill(std::begin(X), std::end(X), 0);
  PC = 0;  // Or reset vector address
  NextPC = 0;
  PrivilegeMode = 3;
  Cycles = 0;
  // Reset CSRs...
}

bool Context::step() {
  // Fetch instruction bytes
  uint8_t Bytes[4];
  for (int i = 0; i < 4; i++)
    Bytes[i] = read(PC + i);

  // Decode
  MCInst Inst;
  uint64_t Size;
  ArrayRef<uint8_t> Code(Bytes, 4);

  auto Status = Disassembler.getInstruction(Inst, Size, Code, PC, nulls());
  if (Status != MCDisassembler::Success) {
    handleTrap(2);  // Illegal instruction
    return false;
  }

  // Set up NextPC (may be modified by branches/jumps)
  NextPC = PC + Size;

  // Execute
  execute(Inst);

  // Commit PC
  PC = NextPC;

  // x0 is always 0
  X[0] = 0;

  Cycles++;
  return true;
}

void Context::execute(const MCInst &Inst) {
  switch (Inst.getOpcode()) {
  #define GET_EMULATOR_CASES
  #include "RISCVGenEmulator.inc"
  #undef GET_EMULATOR_CASES

  default:
    handleTrap(2);  // Illegal instruction
    break;
  }
}

void Context::handleTrap(uint32_t Cause, uint32_t TVal) {
  mepc = PC;
  mcause = Cause;
  mtval = TVal;
  // Save previous privilege mode to mstatus.MPP
  mstatus = (mstatus & ~0x1800) | (PrivilegeMode << 11);
  // Clear mstatus.MIE, save to mstatus.MPIE
  mstatus = (mstatus & ~0x80) | ((mstatus & 0x8) << 4);
  mstatus &= ~0x8;
  // Jump to trap handler
  PrivilegeMode = 3;  // Enter M-mode
  NextPC = mtvec & ~0x3;  // Direct mode
}
```

### 1.3 Add TableGen Generation

```cmake
# In llvm/lib/Target/RISCV/CMakeLists.txt

tablegen(LLVM RISCVGenEmulator.inc -gen-emulator)
```

### 1.4 Create Emulation Format Classes

Create `llvm/lib/Target/RISCV/RISCVInstrFormatsEmu.td` with the format classes shown above.

---

## Phase 2: RV32I Base Instructions

### Instruction Breakdown

| Category | Instructions | Count |
|----------|-------------|-------|
| Arithmetic R-type | ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND | 10 |
| Arithmetic I-type | ADDI, SLTI, SLTIU, XORI, ORI, ANDI, SLLI, SRLI, SRAI | 9 |
| Load | LB, LH, LW, LBU, LHU | 5 |
| Store | SB, SH, SW | 3 |
| Branch | BEQ, BNE, BLT, BGE, BLTU, BGEU | 6 |
| Jump | JAL, JALR | 2 |
| Upper immediate | LUI, AUIPC | 2 |
| System | ECALL, EBREAK, FENCE, FENCE.I | 4 |
| CSR | CSRRW, CSRRS, CSRRC, CSRRWI, CSRRSI, CSRRCI | 6 |
| **Total** | | **47** |

### Implementation Approach

1. Add `RVEmuOperands` base class with operand extraction
2. Add format-specific mixins (`RVEmuRType`, `RVEmuIType`, etc.)
3. Add `Emulate` to each instruction definition
4. Test incrementally with simple programs

### Validation

```bash
# Assemble and run a simple test
cat > test.s << 'EOF'
  .globl _start
_start:
  li a0, 42       # Load immediate 42 into a0
  li a7, 93       # Exit syscall number
  ecall           # Exit with code 42
EOF

llvm-mc -triple=riscv32 -filetype=obj test.s -o test.o
ld.lld test.o -o test
llvm-mc --triple=riscv32 --run test
echo $?  # Should print 42
```

---

## Phase 3: Extensions

### 3a. M Extension (Multiply/Divide)

| Instruction | Operation |
|-------------|-----------|
| MUL | rd = rs1 * rs2 (low 32 bits) |
| MULH | rd = (rs1 * rs2) >> 32 (signed) |
| MULHSU | rd = (rs1 * rs2) >> 32 (signed × unsigned) |
| MULHU | rd = (rs1 * rs2) >> 32 (unsigned) |
| DIV | rd = rs1 / rs2 (signed) |
| DIVU | rd = rs1 / rs2 (unsigned) |
| REM | rd = rs1 % rs2 (signed) |
| REMU | rd = rs1 % rs2 (unsigned) |

```tablegen
class RVEmuMulDiv<code operation> : RVEmuOperands {
  let Emulate = [{
    int64_t lhs = (int32_t)X[$rs1];
    int64_t rhs = (int32_t)X[$rs2];
    uint64_t ulhs = X[$rs1];
    uint64_t urhs = X[$rs2];
    X[$rd] = }] # operation # [{;
  }];
}

def MUL    : RVEmuMulDiv<[{ (uint32_t)(lhs * rhs) }]>;
def MULH   : RVEmuMulDiv<[{ (uint32_t)((lhs * rhs) >> 32) }]>;
def MULHSU : RVEmuMulDiv<[{ (uint32_t)((lhs * (int64_t)urhs) >> 32) }]>;
def MULHU  : RVEmuMulDiv<[{ (uint32_t)((ulhs * urhs) >> 32) }]>;
def DIV    : RVEmuMulDiv<[{ rhs == 0 ? -1 : (lhs == INT32_MIN && rhs == -1) ? lhs : lhs / rhs }]>;
def DIVU   : RVEmuMulDiv<[{ urhs == 0 ? UINT32_MAX : ulhs / urhs }]>;
def REM    : RVEmuMulDiv<[{ rhs == 0 ? lhs : (lhs == INT32_MIN && rhs == -1) ? 0 : lhs % rhs }]>;
def REMU   : RVEmuMulDiv<[{ urhs == 0 ? ulhs : ulhs % urhs }]>;
```

### 3b. A Extension (Atomics)

Atomics require special memory ordering semantics:

```tablegen
class RVEmuAtomic<code operation> : RVEmuOperands {
  let Emulate = [{
    uint32_t addr = X[$rs1];
    uint32_t old = read32(addr);
    uint32_t src = X[$rs2];
    uint32_t result = }] # operation # [{;
    write32(addr, result);
    X[$rd] = old;
  }];
}

def AMOSWAP_W : RVEmuAtomic<[{ src }]>;
def AMOADD_W  : RVEmuAtomic<[{ old + src }]>;
def AMOXOR_W  : RVEmuAtomic<[{ old ^ src }]>;
def AMOAND_W  : RVEmuAtomic<[{ old & src }]>;
def AMOOR_W   : RVEmuAtomic<[{ old | src }]>;
def AMOMIN_W  : RVEmuAtomic<[{ (int32_t)old < (int32_t)src ? old : src }]>;
def AMOMAX_W  : RVEmuAtomic<[{ (int32_t)old > (int32_t)src ? old : src }]>;
def AMOMINU_W : RVEmuAtomic<[{ old < src ? old : src }]>;
def AMOMAXU_W : RVEmuAtomic<[{ old > src ? old : src }]>;

// LR/SC need reservation tracking
def LR_W : ... {
  let Emulate = [{
    uint32_t addr = X[$rs1];
    Reservation = addr;
    ReservationValid = true;
    X[$rd] = read32(addr);
  }];
}

def SC_W : ... {
  let Emulate = [{
    uint32_t addr = X[$rs1];
    if (ReservationValid && Reservation == addr) {
      write32(addr, X[$rs2]);
      X[$rd] = 0;  // Success
    } else {
      X[$rd] = 1;  // Failure
    }
    ReservationValid = false;
  }];
}
```

### 3c. C Extension (Compressed)

Compressed instructions are 16-bit encodings of common operations. The emulation is the same as the base instruction - only the encoding differs.

LLVM's MCDisassembler already handles the decoding, so `C.ADD` decodes to an MCInst that we can handle the same as `ADD`. May need to verify operand positions match.

---

## Phase 4: System Features

### 4.1 CSR Access

```cpp
uint32_t Context::readCSR(unsigned CSR) {
  switch (CSR) {
  case 0x300: return mstatus;
  case 0x301: return misa;
  case 0x304: return mie;
  case 0x305: return mtvec;
  case 0x340: return mscratch;
  case 0x341: return mepc;
  case 0x342: return mcause;
  case 0x343: return mtval;
  case 0x344: return mip;
  case 0xC00: return Cycles & 0xFFFFFFFF;  // cycle
  case 0xC80: return Cycles >> 32;          // cycleh
  // ... more CSRs
  default:
    handleTrap(2);  // Illegal instruction
    return 0;
  }
}
```

### 4.2 CSR Instructions

```tablegen
def CSRRW : ... {
  let Emulate = [{
    unsigned csr = Inst.getOperand(2).getImm();
    uint32_t old = readCSR(csr);
    writeCSR(csr, X[$rs1]);
    X[$rd] = old;
  }];
}

def CSRRS : ... {
  let Emulate = [{
    unsigned csr = Inst.getOperand(2).getImm();
    uint32_t old = readCSR(csr);
    if ($rs1 != 0) writeCSR(csr, old | X[$rs1]);
    X[$rd] = old;
  }];
}

def CSRRC : ... {
  let Emulate = [{
    unsigned csr = Inst.getOperand(2).getImm();
    uint32_t old = readCSR(csr);
    if ($rs1 != 0) writeCSR(csr, old & ~X[$rs1]);
    X[$rd] = old;
  }];
}
```

### 4.3 Interrupt Handling

```cpp
bool Context::step() {
  // Check for pending interrupts before executing
  if (checkInterrupts()) {
    handleInterrupt();
    return true;
  }

  // Normal instruction execution...
}

bool Context::checkInterrupts() {
  // Check mstatus.MIE and pending interrupts
  if (!(mstatus & 0x8)) return false;
  uint32_t pending = mip & mie;
  return pending != 0;
}
```

---

## SAIL Integration (Optional)

If formal verification is desired, sail-riscv can be integrated:

### 1. Generate Jib IR from sail-riscv

```bash
cd ~/git/sail-riscv
sail -plugin isla-sail -isla \
  -isla_preserve execute \
  -isla_preserve step \
  -o riscv.ir \
  $(cat model/main.sail.list)
```

### 2. Add to LLVM Build

```cmake
tablegen(LLVM RISCVGenEmulator.inc -gen-emulator
         -sail-ir=${CMAKE_CURRENT_SOURCE_DIR}/Sail/riscv.ir)
```

### 3. Create SAIL Mixins

```tablegen
class RVSailRType<string op> : RVEmuOperands {
  let Emulate = [{
    zexecute(zRTYPE{(uint8_t)$rs2, (uint8_t)$rs1, (uint8_t)$rd, z}] # op # [{});
  }];
}

def ADD : ALU_rr<...>, RVSailRType<"ADD">;
```

### Considerations

- sail-riscv is ~8000 lines of SAIL → large Jib IR
- May need to subset (just RV32I initially)
- Configuration complexity (`xlen`, extensions)
- Memory model integration

---

## Testing Strategy

### Unit Tests

Test each instruction in isolation:

```
llvm/test/MC/RISCV/Emulator/
├── add.s
├── sub.s
├── load-store.s
├── branch.s
├── jump.s
├── csr.s
└── ...
```

Example:
```asm
# RUN: llvm-mc -triple=riscv32 -filetype=obj %s -o %t.o
# RUN: ld.lld %t.o -o %t
# RUN: llvm-mc --triple=riscv32 --run %t | FileCheck %s

# CHECK: a0 = 0x0000002a

.globl _start
_start:
  li a0, 21
  li a1, 21
  add a0, a0, a1    # a0 = 42
  ebreak            # Stop and dump registers
```

### Integration Tests

Run real programs:

```bash
# Compile C program with RISC-V GCC or clang
riscv32-unknown-elf-gcc -O2 -nostdlib test.c -o test

# Run in emulator
llvm-mc --triple=riscv32 --run test
```

### Validation Against Reference

Use [riscv-tests](https://github.com/riscv/riscv-tests):

```bash
# Run official RISC-V test suite
for test in rv32ui-p-*; do
  llvm-mc --triple=riscv32 --run $test
done
```

### SingleStepTests

Similar to 6502 SingleStepTests, could generate/use RISC-V instruction test vectors.

---

## Open Questions

### 1. RV32 vs RV64

Initial implementation targets RV32. RV64 support requires:
- 64-bit registers and operations
- Additional instructions (ADDIW, etc.)
- Address space changes

Could parameterize with templates or separate Context classes.

### 2. Privilege Modes

Initial implementation targets M-mode only. Adding U/S modes requires:
- PMP (Physical Memory Protection)
- Page table walking (Sv32/Sv39)
- More CSRs

### 3. Floating Point

F/D extensions add significant complexity:
- 32 floating-point registers
- Floating-point CSR (fcsr)
- IEEE 754 compliance (NaN boxing, rounding modes)
- Exception handling

Consider using softfloat library or SAIL for correctness.

### 4. Vector Extension

The V extension is very large (~300+ instructions) and would require significant work.

### 5. Performance

For simple emulation, interpreted execution is fine. For performance:
- Could add basic block caching
- Could generate native code (JIT)
- But that's a much larger project

---

## Phase 5: RV64 Support

Running Linux requires RV64. This is a significant but mechanical extension.

### 5.1 Context Changes

```cpp
class Context : public emu::Context {
public:
  // 64-bit registers
  uint64_t X[32] = {0};
  uint64_t PC = 0;
  uint64_t NextPC = 0;

  // 64-bit CSRs
  uint64_t mstatus = 0;
  uint64_t mtvec = 0;
  uint64_t mepc = 0;
  // ... etc

  // Configuration
  static constexpr unsigned XLEN = 64;

  // Memory access
  uint64_t read64(uint64_t Addr) {
    return read32(Addr) | ((uint64_t)read32(Addr + 4) << 32);
  }
  void write64(uint64_t Addr, uint64_t Val) {
    write32(Addr, Val & 0xFFFFFFFF);
    write32(Addr + 4, Val >> 32);
  }
};
```

### 5.2 Additional RV64I Instructions

| Instruction | Operation |
|-------------|-----------|
| LWU | Load word unsigned (zero-extend to 64 bits) |
| LD | Load doubleword |
| SD | Store doubleword |
| ADDIW | Add immediate word (32-bit result sign-extended) |
| SLLIW | Shift left logical immediate word |
| SRLIW | Shift right logical immediate word |
| SRAIW | Shift right arithmetic immediate word |
| ADDW | Add word |
| SUBW | Subtract word |
| SLLW | Shift left logical word |
| SRLW | Shift right logical word |
| SRAW | Shift right arithmetic word |

```tablegen
class RVEmuRTypeW<code operation> : RVEmuOperands {
  let Emulate = [{
    uint32_t lhs = X[$rs1];
    uint32_t rhs = X[$rs2];
    int32_t result = }] # operation # [{;
    X[$rd] = signExtend64(result, 32);  // Sign-extend 32→64
  }];
}

def ADDW : RVEmuRTypeW<[{ lhs + rhs }]>;
def SUBW : RVEmuRTypeW<[{ lhs - rhs }]>;
def SLLW : RVEmuRTypeW<[{ lhs << (rhs & 0x1F) }]>;
def SRLW : RVEmuRTypeW<[{ lhs >> (rhs & 0x1F) }]>;
def SRAW : RVEmuRTypeW<[{ (int32_t)lhs >> (rhs & 0x1F) }]>;
```

### 5.3 RV64M and RV64A Extensions

Similar pattern - add 64-bit variants:

| Extension | Additional Instructions |
|-----------|------------------------|
| RV64M | MULW, DIVW, DIVUW, REMW, REMUW |
| RV64A | LR.D, SC.D, AMO*.D |

---

## Phase 6: Supervisor Mode and Virtual Memory

**This is where Linux becomes possible.**

### 6.1 Privilege Modes

RISC-V has three privilege modes:

| Mode | Level | Description |
|------|-------|-------------|
| M (Machine) | 3 | Highest privilege, bare metal |
| S (Supervisor) | 1 | OS kernel |
| U (User) | 0 | User applications |

Linux runs in S-mode, applications in U-mode. M-mode is typically firmware (OpenSBI/BBL).

### 6.2 Supervisor CSRs

```cpp
// Supervisor-mode CSRs
uint64_t sstatus = 0;    // Supervisor status
uint64_t sie = 0;        // Supervisor interrupt enable
uint64_t stvec = 0;      // Supervisor trap vector
uint64_t sscratch = 0;   // Supervisor scratch
uint64_t sepc = 0;       // Supervisor exception PC
uint64_t scause = 0;     // Supervisor trap cause
uint64_t stval = 0;      // Supervisor trap value
uint64_t sip = 0;        // Supervisor interrupt pending
uint64_t satp = 0;       // Supervisor address translation and protection

uint64_t readCSR(unsigned CSR) {
  switch (CSR) {
  // Machine mode
  case 0x300: return mstatus;
  case 0x301: return misa;
  case 0x302: return medeleg;    // Exception delegation
  case 0x303: return mideleg;    // Interrupt delegation
  // ... more M-mode CSRs

  // Supervisor mode
  case 0x100: return sstatus;
  case 0x104: return sie;
  case 0x105: return stvec;
  case 0x140: return sscratch;
  case 0x141: return sepc;
  case 0x142: return scause;
  case 0x143: return stval;
  case 0x144: return sip;
  case 0x180: return satp;

  // User mode counters
  case 0xC00: return Cycles;         // cycle
  case 0xC01: return Time;           // time
  case 0xC02: return InstRet;        // instret
  // ...
  }
}
```

### 6.3 Trap Delegation

M-mode can delegate traps to S-mode:

```cpp
void handleTrap(uint64_t Cause, uint64_t TVal) {
  bool isInterrupt = Cause & (1ULL << 63);
  uint64_t exceptionCode = Cause & ~(1ULL << 63);

  // Check if trap should be delegated to S-mode
  bool delegate = false;
  if (PrivilegeMode <= 1) {  // Currently in S or U mode
    if (isInterrupt) {
      delegate = (mideleg >> exceptionCode) & 1;
    } else {
      delegate = (medeleg >> exceptionCode) & 1;
    }
  }

  if (delegate) {
    // Trap to S-mode
    sepc = PC;
    scause = Cause;
    stval = TVal;
    // Update sstatus.SPP with previous privilege
    sstatus = (sstatus & ~0x100) | ((PrivilegeMode & 1) << 8);
    // Save and clear sstatus.SIE
    sstatus = (sstatus & ~0x20) | ((sstatus & 0x2) << 4);
    sstatus &= ~0x2;
    PrivilegeMode = 1;  // Enter S-mode
    NextPC = stvec & ~0x3;
  } else {
    // Trap to M-mode (existing code)
    mepc = PC;
    mcause = Cause;
    mtval = TVal;
    // ... (existing M-mode trap handling)
  }
}
```

### 6.4 Virtual Memory (Sv39/Sv48)

Linux on RV64 uses Sv39 (39-bit virtual addresses) or Sv48 (48-bit).

#### SATP Register Format (Sv39)

```
63    60 59          44 43                              0
┌────────┬──────────────┬────────────────────────────────┐
│  MODE  │     ASID     │              PPN               │
└────────┴──────────────┴────────────────────────────────┘
  4 bits     16 bits              44 bits

MODE:
  0 = Bare (no translation)
  8 = Sv39
  9 = Sv48
```

#### Page Table Entry Format (Sv39)

```
63    54 53          28 27          19 18          10 9  8 7 6 5 4 3 2 1 0
┌────────┬──────────────┬──────────────┬──────────────┬────┬─┬─┬─┬─┬─┬─┬─┬─┐
│Reserved│    PPN[2]    │    PPN[1]    │    PPN[0]    │RSW │D│A│G│U│X│W│R│V│
└────────┴──────────────┴──────────────┴──────────────┴────┴─┴─┴─┴─┴─┴─┴─┴─┘
  10 bits     26 bits        9 bits        9 bits      2   1 1 1 1 1 1 1 1

V = Valid
R = Readable
W = Writable
X = Executable
U = User-accessible
G = Global
A = Accessed
D = Dirty
```

#### Address Translation Implementation

```cpp
// Sv39 virtual address breakdown
struct Sv39VA {
  uint64_t offset : 12;  // Page offset
  uint64_t vpn0 : 9;     // VPN[0]
  uint64_t vpn1 : 9;     // VPN[1]
  uint64_t vpn2 : 9;     // VPN[2]
  uint64_t reserved : 25;
};

enum class AccessType { Read, Write, Execute };

struct TranslationResult {
  bool valid;
  uint64_t physAddr;
  uint64_t pageFault;  // Exception code if !valid
};

TranslationResult translateAddress(uint64_t vaddr, AccessType access) {
  // Check if translation is enabled
  uint64_t mode = (satp >> 60) & 0xF;
  if (mode == 0 || PrivilegeMode == 3) {
    // Bare mode or M-mode: no translation
    return {true, vaddr, 0};
  }

  // Sv39: 3-level page table walk
  uint64_t vpn[3] = {
    (vaddr >> 12) & 0x1FF,
    (vaddr >> 21) & 0x1FF,
    (vaddr >> 30) & 0x1FF
  };

  uint64_t ptBase = (satp & 0xFFFFFFFFFFF) << 12;  // PPN from satp
  uint64_t pte;
  int level;

  for (level = 2; level >= 0; level--) {
    uint64_t pteAddr = ptBase + vpn[level] * 8;
    pte = read64Physical(pteAddr);

    // Check valid bit
    if (!(pte & 1)) {
      return {false, 0, pageFaultCode(access)};
    }

    // Check if leaf PTE (R, W, or X set)
    if (pte & 0xE) {
      break;  // Leaf PTE found
    }

    // Non-leaf: follow to next level
    ptBase = ((pte >> 10) & 0xFFFFFFFFFFF) << 12;
  }

  if (level < 0) {
    return {false, 0, pageFaultCode(access)};
  }

  // Permission checks
  bool U = (pte >> 4) & 1;
  bool R = (pte >> 1) & 1;
  bool W = (pte >> 2) & 1;
  bool X = (pte >> 3) & 1;

  // Check user/supervisor access
  if (PrivilegeMode == 0 && !U) {
    return {false, 0, pageFaultCode(access)};
  }
  if (PrivilegeMode == 1 && U && !(sstatus & SSTATUS_SUM)) {
    return {false, 0, pageFaultCode(access)};
  }

  // Check R/W/X permissions
  switch (access) {
  case AccessType::Read:
    if (!R && !(X && (mstatus & MSTATUS_MXR))) {
      return {false, 0, 13};  // Load page fault
    }
    break;
  case AccessType::Write:
    if (!W) {
      return {false, 0, 15};  // Store page fault
    }
    break;
  case AccessType::Execute:
    if (!X) {
      return {false, 0, 12};  // Instruction page fault
    }
    break;
  }

  // Build physical address
  uint64_t ppn = (pte >> 10) & 0xFFFFFFFFFFF;
  uint64_t pageOffset = vaddr & 0xFFF;
  uint64_t physAddr;

  // Handle superpages
  switch (level) {
  case 2:  // 1 GiB page
    physAddr = (ppn & ~0x3FFFF) << 12 | (vaddr & 0x3FFFFFFF);
    break;
  case 1:  // 2 MiB page
    physAddr = (ppn & ~0x1FF) << 12 | (vaddr & 0x1FFFFF);
    break;
  case 0:  // 4 KiB page
    physAddr = ppn << 12 | pageOffset;
    break;
  }

  // Update A and D bits
  if (!(pte & PTE_A) || (access == AccessType::Write && !(pte & PTE_D))) {
    pte |= PTE_A;
    if (access == AccessType::Write) pte |= PTE_D;
    write64Physical(pteAddr, pte);
  }

  return {true, physAddr, 0};
}
```

### 6.5 TLB (Translation Lookaside Buffer)

For performance, cache recent translations:

```cpp
struct TLBEntry {
  uint64_t vpn;       // Virtual page number
  uint64_t ppn;       // Physical page number
  uint64_t asid;      // Address space ID
  uint8_t perm;       // Permission bits (R/W/X/U)
  uint8_t level;      // Page size (0=4K, 1=2M, 2=1G)
  bool valid;
  bool global;
};

static constexpr size_t TLB_SIZE = 64;
TLBEntry tlb[TLB_SIZE];

TranslationResult translateWithTLB(uint64_t vaddr, AccessType access) {
  uint64_t vpn = vaddr >> 12;
  uint64_t asid = (satp >> 44) & 0xFFFF;

  // TLB lookup
  for (auto &entry : tlb) {
    if (entry.valid &&
        (entry.global || entry.asid == asid) &&
        matchVPN(entry, vpn)) {
      // TLB hit - check permissions and return
      if (checkPermissions(entry, access)) {
        return {true, buildPhysAddr(entry, vaddr), 0};
      } else {
        return {false, 0, pageFaultCode(access)};
      }
    }
  }

  // TLB miss - do full page table walk
  auto result = translateAddress(vaddr, access);
  if (result.valid) {
    // Insert into TLB
    insertTLB(vaddr, result.physAddr, ...);
  }
  return result;
}

// SFENCE.VMA invalidates TLB entries
void sfenceVMA(uint64_t vaddr, uint64_t asid) {
  if (vaddr == 0 && asid == 0) {
    // Flush entire TLB
    for (auto &entry : tlb) entry.valid = false;
  } else if (vaddr == 0) {
    // Flush all entries for ASID
    for (auto &entry : tlb) {
      if (entry.asid == asid && !entry.global) entry.valid = false;
    }
  } else if (asid == 0) {
    // Flush specific page across all ASIDs
    for (auto &entry : tlb) {
      if (matchVPN(entry, vaddr >> 12)) entry.valid = false;
    }
  } else {
    // Flush specific page for specific ASID
    for (auto &entry : tlb) {
      if (entry.asid == asid && matchVPN(entry, vaddr >> 12)) {
        entry.valid = false;
      }
    }
  }
}
```

### 6.6 Memory Access with Translation

```cpp
uint8_t read(uint64_t vaddr) override {
  auto result = translateWithTLB(vaddr, AccessType::Read);
  if (!result.valid) {
    handleTrap(result.pageFault, vaddr);
    return 0;  // Won't reach here if trap taken
  }
  return readPhysical(result.physAddr);
}

void write(uint64_t vaddr, uint8_t value) override {
  auto result = translateWithTLB(vaddr, AccessType::Write);
  if (!result.valid) {
    handleTrap(result.pageFault, vaddr);
    return;
  }
  writePhysical(result.physAddr, value);
}

uint32_t fetchInstruction(uint64_t vaddr) {
  auto result = translateWithTLB(vaddr, AccessType::Execute);
  if (!result.valid) {
    handleTrap(result.pageFault, vaddr);
    return 0;
  }
  return read32Physical(result.physAddr);
}
```

---

## Phase 7: Interrupts and Timers

Linux requires timer interrupts for scheduling.

### 7.1 Interrupt Sources

| Interrupt | Code | Description |
|-----------|------|-------------|
| SSI | 1 | Supervisor software interrupt |
| MSI | 3 | Machine software interrupt |
| STI | 5 | Supervisor timer interrupt |
| MTI | 7 | Machine timer interrupt |
| SEI | 9 | Supervisor external interrupt |
| MEI | 11 | Machine external interrupt |

### 7.2 Timer Implementation

```cpp
// Memory-mapped timer registers (CLINT)
static constexpr uint64_t CLINT_BASE = 0x2000000;
static constexpr uint64_t MTIME_ADDR = CLINT_BASE + 0xBFF8;
static constexpr uint64_t MTIMECMP_ADDR = CLINT_BASE + 0x4000;

uint64_t mtime = 0;      // Current time
uint64_t mtimecmp = 0;   // Timer compare

void tickTimer() {
  mtime++;

  // Check for timer interrupt
  if (mtime >= mtimecmp) {
    mip |= (1 << 7);  // Set MTIP
  } else {
    mip &= ~(1 << 7); // Clear MTIP
  }

  // Delegate to supervisor timer if configured
  if ((mideleg >> 5) & 1) {
    if (mip & (1 << 7)) {
      sip |= (1 << 5);  // Set STIP
    }
  }
}

bool step() override {
  tickTimer();

  // Check for pending interrupts
  if (checkInterrupts()) {
    handleInterrupt();
    return true;
  }

  // Normal execution...
}

bool checkInterrupts() {
  uint64_t pending;

  if (PrivilegeMode == 3) {
    // M-mode: check mstatus.MIE
    if (!(mstatus & 0x8)) return false;
    pending = mip & mie & ~mideleg;
  } else if (PrivilegeMode == 1) {
    // S-mode: check sstatus.SIE or higher-priority M-mode interrupts
    bool sie = (sstatus & 0x2);
    pending = ((mip & mie & ~mideleg) |  // M-mode interrupts always
               (sie ? (sip & sie) : 0)); // S-mode if enabled
  } else {
    // U-mode: all enabled interrupts can fire
    pending = (mip & mie & ~mideleg) | (sip & sie);
  }

  return pending != 0;
}
```

### 7.3 CLINT Memory-Mapped Registers

```cpp
uint64_t readCLINT(uint64_t addr) {
  if (addr == MTIME_ADDR) return mtime;
  if (addr == MTIME_ADDR + 4) return mtime >> 32;
  if (addr >= MTIMECMP_ADDR && addr < MTIMECMP_ADDR + 8) {
    // Per-hart mtimecmp (we only have 1 hart)
    return mtimecmp >> ((addr - MTIMECMP_ADDR) * 8);
  }
  return 0;
}

void writeCLINT(uint64_t addr, uint64_t value, unsigned size) {
  if (addr >= MTIMECMP_ADDR && addr < MTIMECMP_ADDR + 8) {
    unsigned shift = (addr - MTIMECMP_ADDR) * 8;
    uint64_t mask = ((1ULL << (size * 8)) - 1) << shift;
    mtimecmp = (mtimecmp & ~mask) | ((value << shift) & mask);
    // Clear timer interrupt when mtimecmp written
    mip &= ~(1 << 7);
  }
}
```

---

## Phase 8: Device Emulation (Already Done!)

**Good news: We already have comprehensive semihosting infrastructure that provides everything Linux needs.**

### 8.1 Existing Semihosting Infrastructure

The `emu::Semihost` class already implements the full ARM semihosting protocol:

```
llvm/lib/Emulator/Semihost/
├── Semihost.cpp              # Main device implementation
├── zbc_protocol.h            # RIFF wire protocol
├── zbc_backend.h             # Backend vtable interface
├── zbc_ansi_secure.c         # Sandboxed file I/O
├── zbc_ansi_insecure.c       # Unrestricted file I/O
├── zbc_ansi_console.c        # Console-only backend
└── ...
```

### 8.2 What Semihosting Already Provides

| Category | Operations | Status |
|----------|------------|--------|
| **Console I/O** | SH_SYS_WRITEC, SH_SYS_WRITE0, SH_SYS_READC | ✅ Done |
| **File I/O** | OPEN, CLOSE, READ, WRITE, SEEK, FLEN, REMOVE, RENAME | ✅ Done |
| **Time** | CLOCK, TIME, ELAPSED, TICKFREQ | ✅ Done |
| **Timer IRQ** | SH_SYS_TIMER_CONFIG (configurable Hz) | ✅ Done |
| **Exit** | SH_SYS_EXIT, SH_SYS_EXIT_EXTENDED | ✅ Done |
| **System** | GET_CMDLINE, HEAPINFO, SYSTEM, ERRNO | ✅ Done |

### 8.3 Memory-Mapped Interface

The semihost device maps to a 32-byte region:

```
Offset  Register      Description
0x00    SIGNATURE     "SEMIHOST" magic (read-only)
0x08    RIFF_PTR      Pointer to RIFF buffer in guest memory
0x18    DOORBELL      Write triggers semihost call
0x19    STATUS        Bit 0: response ready / timer pending
```

### 8.4 Three Security Modes

```cpp
// Sandboxed - file ops restricted to sandbox directory
auto Semihost = emu::Semihost::create(Sys, "/sandbox/dir");

// Unrestricted - full filesystem access (trusted code only)
auto Semihost = emu::Semihost::createInsecure(Sys);

// Console-only - stdin/stdout/stderr, no filesystem
auto Semihost = emu::Semihost::createConsoleOnly(Sys);
```

### 8.5 Timer Interrupt Support

Semihosting already supports periodic timer interrupts:

```cpp
// Guest configures timer via SH_SYS_TIMER_CONFIG
// Host tracks cycles and fires IRQ at configured rate
// STATUS register bit 0 set before IRQ assertion
// Guest acknowledges by writing 0 to STATUS
```

This means **Linux's timer interrupt requirements are already met** - we just need to wire it up to the RISC-V timer infrastructure.

### 8.6 Integration for RISC-V

For RISC-V, we need minimal glue:

```cpp
class RISCVSemihost : public emu::Semihost {
  RISCV::Context &Ctx;

public:
  void onTimerIRQ() override {
    // Set supervisor timer interrupt pending
    Ctx.sip |= (1 << 5);  // STIP
  }

  void onExit(unsigned reason, unsigned code) override {
    Ctx.Halted = true;
    Ctx.ExitCode = code;
  }
};
```

### 8.7 What We DON'T Need to Write

| Traditional Device | Why Not Needed |
|-------------------|----------------|
| UART 16550 | Semihost console I/O works |
| VirtIO block | Semihost file I/O works |
| PLIC | Semihost timer IRQ + ecall for others |
| RTC | Semihost TIME/CLOCK |

### 8.8 Linux Boot Strategy with Semihosting

Instead of emulating a full "virt" machine, we can boot Linux using a **semihosting-aware setup**:

1. **Use OpenSBI with semihosting** - OpenSBI already has semihosting console support
2. **Kernel with semihosting earlycon** - `earlycon=sbi` uses SBI calls → OpenSBI → semihost
3. **initramfs from semihost file** - Load via semihost READ
4. **Timer via semihost** - Configure periodic IRQ

```bash
llvm-mc --triple=riscv64 --run \
  --semihost-sandbox=/path/to/rootfs \
  fw_payload.elf  # OpenSBI + Linux payload
```

### 8.9 Comparison: Traditional vs Semihosting

| Aspect | Traditional QEMU-style | Semihosting |
|--------|----------------------|-------------|
| Console | UART 16550 + interrupt | Direct host I/O |
| Disk | VirtIO + descriptor rings | File read/write |
| Timer | CLINT mtime/mtimecmp | Timer config syscall |
| Complexity | ~2000 lines | ~100 lines glue |
| Performance | Extra MMIO overhead | Direct host calls |
| Debugging | Hardware-like | Easy host tracing |

**The semihosting approach is simpler, faster, and already implemented.**

---

## Phase 9: Booting Linux

### 9.1 The Problem: Linux Can't Talk to Hardware Directly

Linux expects certain things to exist:
- A way to print text to a console
- A timer that fires periodically (for scheduling)
- A way to read files (for loading the root filesystem)

Normally these come from hardware devices (UART, timer chip, disk controller). But we have semihosting instead, which provides all these capabilities through a memory-mapped interface to the host.

**The question is: how does Linux use semihosting?**

### 9.2 Two Approaches

#### Approach A: Patch Linux Directly

We could modify the Linux kernel to call semihosting directly:
- Add a semihosting console driver
- Add a semihosting timer driver
- Add a semihosting block device

**Pros:** Simple, direct
**Cons:** Requires maintaining kernel patches

#### Approach B: Thin Shim in M-mode

Recall from Phase 6 that RISC-V has privilege modes: M (machine), S (supervisor), U (user). Linux runs in S-mode. There's a standard interface for S-mode software to request services from M-mode software.

We could write a small M-mode program that:
- Intercepts service requests from Linux
- Translates them to semihosting calls
- Returns results to Linux

**Pros:** No kernel patches needed - use standard Linux
**Cons:** Need to write the shim

### 9.3 Choosing an Approach

Approach B is better because:
1. We can use an unmodified Linux kernel
2. The "service request" interface is simple (details below)
3. The shim is small (~500 lines)

### 9.4 The Service Request Interface

When S-mode code needs M-mode services, it uses the `ECALL` instruction. This is similar to how user programs make system calls - it's just a trap that transfers control to a higher privilege level.

```
Linux (S-mode)                    Our Shim (M-mode)
      │                                 │
      │  ECALL (request console write)  │
      ├────────────────────────────────►│
      │                                 │──► semihost write
      │◄────────────────────────────────┤
      │  (return)                       │
```

The requests are numbered. The ones Linux needs:

| Request | Purpose |
|---------|---------|
| 0 | Set timer (for scheduling) |
| 1 | Console putchar |
| 2 | Console getchar |

That's it. Linux uses these three to boot with a minimal console.

### 9.5 The Shim Implementation

```cpp
void handleServiceRequest() {
  uint64_t request = X[17];  // a7 register holds request number
  uint64_t arg0 = X[10];     // a0 holds first argument

  switch (request) {
  case 0:  // Set timer
    // Configure semihost timer to fire at requested time
    semihostTimerConfig(arg0);
    break;

  case 1:  // Console putchar
    semihostWriteChar(arg0);
    break;

  case 2:  // Console getchar
    X[10] = semihostReadChar();  // Return value in a0
    break;
  }

  // Return to S-mode
  PC = mepc + 4;  // Skip past the ECALL instruction
}
```

### 9.6 Memory Map

```
0x80000000 - 0x80000FFF  Shim code (4 KB)
0x80001000 - 0x8FFFFFFF  Linux + RAM (255 MB)
0xFFFFFCE0 - 0xFFFFFCFF  Semihost device (32 bytes)
```

### 9.7 Boot Sequence

1. **Emulator loads shim** at 0x80000000
2. **Emulator loads Linux kernel** at 0x80001000
3. **Start execution** at 0x80000000 (shim entry)
4. **Shim initializes:**
   - Sets up trap handler for service requests
   - Delegates other traps to S-mode
   - Jumps to Linux at 0x80001000
5. **Linux boots:**
   - Uses service requests for console output
   - Uses service requests for timer
   - Eventually reaches userspace

### 9.8 Device Tree

Linux needs a "device tree" describing available hardware:

```dts
/dts-v1/;

/ {
    compatible = "llvm-emu,riscv";
    model = "LLVM Emulator";

    cpus {
        cpu@0 {
            compatible = "riscv";
            riscv,isa = "rv64imafdc";
            mmu-type = "riscv,sv39";
        };
    };

    memory@80001000 {
        device_type = "memory";
        reg = <0x0 0x80001000 0x0 0x0FF00000>;  // 255 MB
    };

    chosen {
        bootargs = "console=hvc0 earlycon";
    };
};
```

The `console=hvc0` tells Linux to use the hypervisor console (our service request interface).

### 9.9 Running Linux

```bash
llvm-mc --triple=riscv64 --run \
  --load=0x80000000:shim.bin \
  --load=0x80001000:Image \
  --load=0x88000000:initramfs.cpio \
  --dtb=0x87000000:device.dtb \
  --semihost-sandbox=/path/to/rootfs \
  --entry=0x80000000
```

### 9.10 Summary

| Component | What it does | Size |
|-----------|--------------|------|
| Shim | Translates service requests → semihosting | ~500 lines |
| Device tree | Describes memory layout to Linux | ~30 lines |
| Linux kernel | Unmodified, stock kernel | - |
| Semihosting | Already implemented (Phase 8) | 0 new lines |

---

## Summary: Road to Linux

| Phase | Description | Effort | Cumulative |
|-------|-------------|--------|------------|
| 1 | Infrastructure | 1 week | 1 week |
| 2 | RV32I (47 insns) | 2 weeks | 3 weeks |
| 3a | M extension (8 insns) | 3 days | 3.5 weeks |
| 3b | A extension (11 insns) | 1 week | 4.5 weeks |
| 3c | C extension (~50 insns) | 1 week | 5.5 weeks |
| 4 | CSRs + basic traps | 2 weeks | 7.5 weeks |
| 5 | RV64 support | 2 weeks | 9.5 weeks |
| 6 | Virtual memory (Sv39) | 3 weeks | 12.5 weeks |
| 7 | Interrupts + semihost glue | 1 week | 13.5 weeks |
| 8 | ~~Device emulation~~ | ~~3 weeks~~ **0** | **Already done!** |
| 9 | Boot integration | 1 week | 14.5 weeks |
| **Total** | **~15 weeks** | | **~3.5 months** |

### What Semihosting Saved Us

| Eliminated Work | Effort Saved |
|-----------------|--------------|
| UART 16550 implementation | 1 week |
| VirtIO block device | 2 weeks |
| PLIC interrupt controller | 1 week |
| CLINT timer (partial) | 0.5 week |
| **Total savings** | **~4.5 weeks** |

### Critical Path (Revised)

```
RV32I ──► RV64 ──► S-mode CSRs ──► Virtual Memory ──► Semihost glue ──► Linux
                                                           │
                                              (Already have console, file I/O, timer)
```

### Milestones

| Milestone | Can Run |
|-----------|---------|
| Phase 2 complete | Simple bare-metal RV32 programs |
| Phase 4 complete | M-mode firmware, trap handlers |
| Phase 5 complete | 64-bit programs |
| Phase 6 complete | Programs with virtual memory |
| Phase 7 complete | Timer-driven programs (via semihost) |
| Phase 9 complete | **Linux kernel boot** |

### What SAIL Buys You

For phases 1-5 (instructions), SAIL is optional - hand-written or composed `Emulate` works fine.

For phases 6-7 (virtual memory, traps), SAIL's formal spec is valuable because:
- Page table walking has many edge cases
- Privilege transitions are subtle
- sail-riscv is the reference implementation

Recommendation: Use SAIL for `translateAddress()`, `handleTrap()`, and privilege mode transitions. The device emulation is already done via semihosting.

---

## References

- [RISC-V Privileged Specification](https://riscv.org/specifications/privileged-isa/)
- [RISC-V Unprivileged Specification](https://riscv.org/specifications/)
- [sail-riscv](https://github.com/riscv/sail-riscv) - Official RISC-V SAIL model
- [OpenSBI](https://github.com/riscv-software-src/opensbi) - M-mode firmware
- [riscv-tests](https://github.com/riscv/riscv-tests) - Official test suite
- [QEMU RISC-V](https://www.qemu.org/docs/master/system/riscv/virt.html) - Reference for virt machine
