# Integrating Formal ISA Specifications with EmulateInstruction

## Executive Summary

LLDB's `EmulateInstruction` infrastructure requires significant manual effort to implement for each architecture. By leveraging formal ISA specifications (SAIL), we can automate the mechanical aspects while preserving the semantic classification that makes EmulateInstruction valuable.

This document proposes a service layer that provides instruction metadata and context classification, allowing EmulateInstruction implementations to focus solely on ABI-specific policy rather than instruction-by-instruction execution logic.

---

## Current State of EmulateInstruction

### Purpose

EmulateInstruction serves three main use cases:
1. **CFI Generation** - Synthesize Call Frame Information from assembly when DWARF is missing
2. **Single-Step Prediction** - Predict branch targets for software single-stepping
3. **Breakpoint Emulation** - Execute instructions in place of breakpoint traps

The key output is a `ContextType` classification that tells the unwind infrastructure *why* a memory or register operation occurred:

| ContextType | Meaning |
|-------------|---------|
| `eContextPushRegisterOnStack` | Saving a callee-saved register |
| `eContextPopRegisterOffStack` | Restoring a saved register |
| `eContextAdjustStackPointer` | Allocating/deallocating stack space |
| `eContextSetFramePointer` | Establishing frame pointer |
| `eContextRestoreStackPointer` | Tearing down frame |

### Implementation Burden

Current implementations require:

1. **Manual pseudocode translation** - Developers copy ISA manual pseudocode into comments, then hand-translate to C++
2. **Per-instruction handlers** - Each instruction pattern needs a dedicated emulation function
3. **Significant code volume** - ARM: 14,492 lines, ARM64: 1,223 lines, MIPS: 5,000+ lines
4. **Ongoing maintenance** - New ISA extensions require manual updates

Example from `EmulateInstructionARM.cpp`:

```cpp
#if 0
    // ARM pseudo code...
    if (ConditionPassed())
    {
        EncodingSpecificOperations();
        NullCheckIfThumbEE(13);
        address = SP - 4*BitCount(registers);
        for (i = 0 to 14)
        {
            if (registers<i> == '1')
                // ... continues for 20+ lines
#endif
// Followed by 50+ lines of C++ translation
```

This pattern repeats **119 times** in the ARM implementation alone.

### The Key Insight

Despite the complexity, the actual context classification logic is remarkably simple. From `EmulateInstructionARM.cpp`:

```cpp
// For stores:
if (n == 13)  // Is base register SP?
  context.type = eContextPushRegisterOnStack;
else
  context.type = eContextRegisterStore;

// For loads:
if (n == 13)  // Is base register SP?
  context.type = eContextPopRegisterOffStack;
else
  context.type = eContextRegisterLoad;
```

The semantic decision is simply: **"Is this memory operation relative to the stack pointer?"**

Everything else - decoding, operand extraction, effect computation - is mechanical and derivable from the ISA specification.

---

## What Formal Specifications Provide

### SAIL: A Formal ISA Description Language

SAIL is a language for describing instruction set architectures with formal semantics. It is used by ARM, RISC-V, and other architecture vendors to specify their ISAs precisely.

From a SAIL specification, we can generate:
- **Executable emulation code** - Correct by construction
- **Instruction metadata** - What each instruction reads, writes, and modifies
- **Addressing mode information** - How effective addresses are computed

### The llvm::emu Framework

The llvm-mos project includes `llvm::emu`, an emulator framework that:
- Executes SAIL-generated instruction semantics
- Provides cycle-accurate simulation
- Supports reverse debugging via undo journaling
- Integrates with LLDB via ProcessSimulator

This infrastructure already exists and is tested. The question is: can it serve EmulateInstruction's needs?

---

## Proposed Integration

### Layer 1: Static Instruction Metadata

Generate a lookup table from the SAIL specification containing:

```cpp
struct InstructionEmulateInfo {
  // Memory access characteristics
  bool ReadsMemory;
  bool WritesMemory;

  // Stack interaction
  bool UsesStackPointer;      // Addressing relative to SP
  bool ModifiesStackPointer;  // Changes SP value

  // For instructions with unambiguous context
  ContextType StaticContext;  // eContextInvalid if runtime check needed

  // Affected register (for push/pop tracking)
  std::optional<unsigned> AffectedRegister;
};
```

For many instructions, the context is **statically determinable**:

| Instruction Class | Static Context | Rationale |
|-------------------|----------------|-----------|
| Push (PHA, PUSH, etc.) | `eContextPushRegisterOnStack` | Always writes to SP-relative address |
| Pop (PLA, POP, etc.) | `eContextPopRegisterOffStack` | Always reads from SP-relative address |
| Call (JSR, BL, CALL) | `eContextAbsoluteBranchRegister` | Always a call |
| Return (RTS, RET) | `eContextAbsoluteBranchRegister` | Always a return |
| SP arithmetic | `eContextAdjustStackPointer` | Modifies SP directly |

For other instructions (general load/store), the context depends on the effective address at runtime.

### Layer 2: Context Classification API

```cpp
namespace llvm::emu {

struct ContextClassification {
  EmulateInstruction::ContextType Type;
  std::optional<unsigned> AffectedRegister;
  std::optional<int64_t> StackDelta;
  std::optional<uint64_t> BranchTarget;
};

/// Classify an instruction for EmulateInstruction.
///
/// For statically-classifiable instructions, returns immediately.
/// For ambiguous instructions, uses EffectiveAddr to determine
/// if the access is stack-relative.
ContextClassification classifyForEmulate(
    const MCInst &Inst,
    std::optional<uint64_t> EffectiveAddr = std::nullopt,
    uint64_t StackPointerReg = 0,
    uint64_t StackBase = 0,
    uint64_t StackSize = 0);

} // namespace llvm::emu
```

### Layer 3: Optional Execution Service

For implementations that need actual values (not just classification):

```cpp
namespace llvm::emu {

struct InstructionEffects {
  SmallVector<std::pair<unsigned, uint64_t>, 4> RegisterWrites;
  SmallVector<std::pair<uint64_t, uint8_t>, 8> MemoryWrites;
  std::optional<int> StackPointerDelta;
  std::optional<uint64_t> BranchTarget;
};

/// Execute instruction and report effects.
/// Uses SAIL-generated semantics for correctness.
InstructionEffects executeAndObserve(
    Context &Ctx,
    const MCInst &Inst);

} // namespace llvm::emu
```

### Layer 4: EmulateInstruction Base Class

An optional base class that uses all the above:

```cpp
namespace llvm::emu {

/// Base EmulateInstruction that delegates to llvm::emu.
/// Subclasses only implement ABI-specific policy.
class EmulateInstructionFromSAIL : public EmulateInstruction {
protected:
  /// Override to customize context classification for your ABI.
  /// Default implementation uses classifyForEmulate().
  virtual ContextType classifyMemoryAccess(
      const InstructionEffects &Effects,
      uint64_t Address,
      bool IsWrite);

public:
  bool EvaluateInstruction(uint32_t options) override;
  // ... other EmulateInstruction methods implemented
};

} // namespace llvm::emu
```

A complete EmulateInstruction implementation becomes:

```cpp
class EmulateInstructionMOS : public EmulateInstructionFromSAIL {
  ContextType classifyMemoryAccess(
      const InstructionEffects &E, uint64_t Addr, bool IsWrite) override {
    // Hardware stack: $100-$1FF
    if (Addr >= 0x100 && Addr < 0x200) {
      return IsWrite ? eContextPushRegisterOnStack
                     : eContextPopRegisterOffStack;
    }
    // Soft stack: check against soft SP register
    if (Addr == getSoftStackPointer()) {
      return eContextAdjustStackPointer;
    }
    return IsWrite ? eContextRegisterStore : eContextRegisterLoad;
  }
};
```

**50 lines of ABI policy vs. 14,492 lines of instruction mechanics.**

---

## Benefits

### For New Architectures

| Traditional Approach | With llvm::emu |
|---------------------|----------------|
| Months of development | Days to weeks |
| Hand-translate every instruction | Generate from SAIL |
| Debug subtle encoding errors | Correct by construction |
| Maintain parallel with ISA updates | Regenerate from spec |

### For Existing Architectures

Existing implementations continue to work unchanged. Migration can be incremental:

1. **Validation** - Use llvm::emu as a test oracle for existing handlers
2. **Gap filling** - Use llvm::emu for instructions not yet implemented
3. **Full migration** - Replace hand-written handlers when confident

### For Maintainers

- No more hand-translating pseudocode from architecture manuals
- Single source of truth (SAIL specification)
- Automatic coverage of ISA extensions
- Reduced code review burden (generated code, not hand-written)

---

## Implementation Path

### Phase 1: Proof of Concept (MOS)

1. Generate instruction metadata table from MOS SAIL spec
2. Implement `classifyForEmulate()` for MOS
3. Create `EmulateInstructionMOS` using the framework
4. Validate against existing DWARF-based unwinding

### Phase 2: Validation Service

1. Package as a library usable by any EmulateInstruction implementation
2. Provide test oracle functionality for existing ARM/ARM64/RISC-V implementations
3. Document API and integration patterns

### Phase 3: Community Engagement

1. RFC to lldb-dev mailing list
2. Gather feedback on API design
3. Identify interested architecture maintainers

### Phase 4: Broader Adoption

1. RISC-V (has official SAIL spec)
2. ARM (has official SAIL spec)
3. Other architectures as SAIL specs become available

---

## Non-Goals

This proposal explicitly does **not** aim to:

- **Replace EmulateInstruction** - The semantic classification layer remains valuable
- **Deprecate existing implementations** - They work and are well-tested
- **Force migration** - Adoption should be voluntary and incremental
- **Change the EmulateInstruction interface** - Consumers remain unaffected

---

## Conclusion

EmulateInstruction implementations currently require significant manual effort that is error-prone and difficult to maintain. By providing instruction metadata and optional execution services from formal specifications, we can:

1. Reduce new architecture implementation from months to days
2. Eliminate hand-translation of ISA pseudocode
3. Provide correctness guarantees from formal specifications
4. Allow developers to focus on ABI semantics rather than instruction mechanics

The infrastructure already exists in llvm::emu. This proposal packages it for EmulateInstruction's specific needs while respecting the existing architecture and maintainers' autonomy.

---

## References

- [SAIL Language](https://github.com/rems-project/sail) - Formal ISA description language
- [llvm::emu Framework](llvm/include/llvm/Emulator/) - Emulator infrastructure in llvm-mos
- [EmulateInstruction.h](lldb/include/lldb/Core/EmulateInstruction.h) - LLDB interface
- [ARM SAIL Specification](https://github.com/rems-project/sail-arm) - Official ARM ISA in SAIL
- [RISC-V SAIL Specification](https://github.com/riscv/sail-riscv) - Official RISC-V ISA in SAIL
