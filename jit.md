# Fast Emulator via Binary Translation

## Overview

Create a tool that transpiles target binaries (e.g., 6502 ELF) to optimized native code for fast execution.

**Two emulation modes:**
1. `llvm-mc --run` - Slow interpreter, good for debugging/tracing
2. `llvm-emu` - Fast execution via binary translation

## Why Binary Translation, Not JIT

### The Problem with Traditional JIT

Traditional trace-based JIT (interpret cold code, compile hot traces) requires:
- Hot path detection and execution counting
- Trace recording infrastructure
- Interpreter fallback for cold code
- Cache management and invalidation
- Two completely separate code paths (interpreter + JIT)

### The Problem with ORC-based JIT

ORC needs LLVM IR as input. To get IR from SAIL semantics, we would either:
- Emit IR directly from SAIL (hard - Jib is imperative, LLVM IR is SSA)
- Use clang to compile C++ to IR

If we're using clang anyway, why not use it for the whole program?

### Binary Translation Advantages

- **Simpler**: No runtime compilation decisions or hot path detection
- **Whole-program optimization**: Clang/LLVM sees everything at once
- **Single source of truth**: Semantic methods written once in C++, called by generated code
- **Full optimization**: O2/O3 applied to the entire translated program
- **Portable output**: Generated C++ can be compiled for any host platform

## Architecture

```
Target ELF → Disassemble → Generate C++ → Clang (in-process) → Native code → Execute
```

This is **ahead-of-time binary translation**, not JIT. The entire target program is transpiled before any guest code executes.

## The Tool: `llvm-emu`

```bash
# Generate portable C++ to stdout
llvm-emu program.elf

# Generate C++ to file
llvm-emu program.elf -o program.cpp

# Compile to native binary (invoke clang internally)
llvm-emu program.elf -o program

# Compile and run immediately
llvm-emu program.elf --run
```

## Generated Code Structure

### Main Program

```cpp
#include "MOSSemantics.h"  // SAIL-generated semantic methods

void run_program(Context *ctx) {
L0200:
  ctx->LDA_imm(0x42);
  ctx->SEC();
  ctx->SBC_imm(1);
  ctx->STA_zp(0x10);
  if (!ctx->Z) goto L0200;  // BNE becomes C++ goto
  ctx->LDA_imm(0x42);
  ctx->STA_abs(0x1000);
  // ... entire program as C++ ...
}
```

### Semantic Methods (Single Source of Truth)

From SAIL-generated code:
```cpp
void Context::LDA_imm(uint8_t imm) {
  A = imm;
  N = (A >> 7);
  Z = (A == 0);
}

void Context::ADC_imm(uint8_t imm) {
  uint16_t sum = A + imm + C;
  V = ~(A ^ imm) & (A ^ sum) & 0x80;
  C = sum > 0xFF;
  A = sum & 0xFF;
  N = (A >> 7);
  Z = (A == 0);
}
```

These methods already exist in `MOSContext.cpp` (generated from SAIL). The binary translator just calls them.

## Using Clang as a Library

Clang is designed to be used as a library (clang-tidy, clangd, and Cling all do this).

```cpp
std::unique_ptr<Module> compileToModule(StringRef CppSource) {
  CompilerInstance CI;
  CI.createDiagnostics();

  // Setup invocation
  auto Invocation = std::make_shared<CompilerInvocation>();
  CompilerInvocation::CreateFromArgs(*Invocation, {"-O2", "-x", "c++"}, CI.getDiagnostics());
  CI.setInvocation(Invocation);

  // Set source
  auto Buffer = MemoryBuffer::getMemBuffer(CppSource);
  CI.getSourceManager().setMainFileID(
    CI.getSourceManager().createFileID(std::move(Buffer)));

  // Compile to LLVM IR
  EmitLLVMOnlyAction Action;
  CI.ExecuteAction(Action);

  return Action.takeModule();  // Ready for ORC or direct execution
}
```

This is ~50-100 lines of setup boilerplate, but well-documented.

## Control Flow Translation

### Direct Branches

```cpp
// 6502:
//   BNE $0210
//   LDA #$FF
//   JMP $0220
// $0210:
//   LDA #$00
// $0220:
//   ...

// Becomes:
L0200:
  ctx->LDA_zp(0x10);
  if (!ctx->Z) goto L0210;  // BNE
  ctx->LDA_imm(0xFF);
  goto L0220;               // JMP
L0210:
  ctx->LDA_imm(0x00);
L0220:
  // ...
```

### Indirect Jumps (JMP ($addr))

Destination not known at transpile time. Options:

1. **Switch table** (preferred for most cases):
   ```cpp
   switch(ctx->readMem16(addr)) {
     case 0x200: goto L0200;
     case 0x210: goto L0210;
     // ... all possible targets
   }
   ```

2. **Restrict to pure code**: Most LLVM-emitted code doesn't use indirect jumps

3. **Fallback**: Exit to interpreter for that instruction

### Interrupts

Insert checks at strategic points (function entries, loop back-edges):
```cpp
L0200:
  if (ctx->checkInterrupts()) return;  // Exit to handle IRQ
  ctx->LDA_zp(0x10);
  // ...
```

## Self-Modifying Code

For **LLVM-emitted code**: Not a concern. Mark ELF sections as "pure" and skip SMC handling entirely.

For **legacy/hand-written code**: Either:
- Fall back to the slow interpreter (`llvm-mc --run`)
- Detect writes to code region and invalidate/retranslate

Since the primary use case is running compiler output, SMC is a non-issue.

## Files to Create/Modify

1. **New tool**: `llvm/tools/llvm-emu/`
   - `llvm-emu.cpp` - Main driver
   - ELF loading and disassembly
   - C++ code generation
   - Clang integration for in-process compilation

2. **Semantic methods**: Already exist in `MOSContext.cpp` (SAIL-generated)
   - May need to factor out into a standalone header

3. **Shared headers**: `MOSSemantics.h`
   - Context struct definition
   - Method declarations
   - Memory access interface

## Dependencies

- `libclang` and clang libraries (for in-process compilation)
- `LLVMOrcJIT` (for in-memory execution)
- Existing: `LLVMMCDisassembler`, `LLVMMC`, `LLVMObject`

## Performance Expectations

- **Interpreter** (`llvm-mc --run`): ~50-100 host cycles per guest instruction
- **Translated code**: ~5-15 host cycles per guest instruction
- **Translation time**: One-time cost, amortized over entire execution

The key insight: no runtime compilation decisions. Translate everything up front, run everything fast.

## Implementation Order

1. **Standalone C++ output**
   - Disassemble ELF to instruction stream
   - Generate C++ that calls semantic methods
   - User compiles with their own clang
   - Test correctness against interpreter

2. **In-process clang compilation**
   - Link clang libraries
   - Compile generated C++ to LLVM Module
   - Execute via ORC

3. **Native binary output**
   - Write compiled code to object file
   - Link to create standalone executable

## Open Questions

1. **Indirect jump handling**: Switch table vs interpreter fallback?
2. **Interrupt granularity**: Every basic block? Configurable?
3. **Multi-target**: Start with MOS only, or design for multiple targets?

## Comparison: Interpreter vs Translator

| Aspect | `llvm-mc --run` | `llvm-emu` |
|--------|-----------------|-----------|
| Startup time | Instant | Translation overhead |
| Execution speed | Slow (~50-100 cycles/insn) | Fast (~5-15 cycles/insn) |
| Debugging | Full trace support | Limited |
| SMC support | Full | Limited/None |
| Use case | Debugging, testing | Production runs |
