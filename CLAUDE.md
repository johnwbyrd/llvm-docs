# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

LLVM-MOS is a fork of LLVM that adds support for the MOS 65xx series of microprocessors (6502 and variants). It extends LLVM's code generation infrastructure to target vintage 8-bit processors commonly found in retro computers and embedded systems. The project includes a complete backend implementation with specialized optimizations for the unique constraints of 6502-based systems.

## Build Output Handling

**CRITICAL: NEVER pipe build output through `tail`, `head`, or similar truncation commands.**

All build commands MUST redirect output to a temporary file, then read the file afterwards:
```bash
# CORRECT - capture full output
cmake --build build --target check-lld 2>&1 | tee /tmp/build-output.log
# Then read the relevant parts:
cat /tmp/build-output.log  # or tail -100 /tmp/build-output.log

# WRONG - loses important error context
cmake --build build --target check-lld 2>&1 | tail -60
```

Long-running builds produce megabytes of output. Piping through `tail` loses:
- Early compilation errors that cause later failures
- Warning messages that explain the root cause
- Test names and line numbers needed for debugging

Always capture to a file first, then examine as needed.

## Essential Build Commands

### Initial Configuration
```bash
# Configure with MOS cache (recommended)
cmake -C clang/cmake/caches/MOS.cmake -G Ninja -S llvm -B build

# Add additional projects if neededgit -C /home/jbyrd/git/llvm-mos checkout upstream/main --detach
cmake -C clang/cmake/caches/MOS.cmake -C .vscode/jbyrd-dev.cmake -DLLVM_ENABLE_PROJECTS="clang;clang-tools-extra;lld;lldb" -S llvm -B build

# Debug build with assertions
cmake -C clang/cmake/caches/MOS.cmake -C .vscode/jbyrd-dev.cmake -DCMAKE_BUILD_TYPE=Debug -DLLVM_ENABLE_ASSERTIONS=On -S llvm -B build
```

### Building and Testing

**CRITICAL: NEVER run `ninja` directly to build llvm-mos.** Always use either:
1. `cmake --build build` (recommended)
2. The full build script: `/home/jbyrd/git/llvm-mos/.vscode/build-all.sh`

Running `ninja lld` or similar direct ninja invocations skips crucial steps:
- Cross-compilation of the MOS runtime libraries (builtins, compiler-rt)
- Installation of headers and libraries to the install directory
- Proper sequencing of dependent targets

This creates subtle, hard-to-debug issues where the installed toolchain uses stale components. **Always do a full build!**  You are going to ignore this recommendation, and you're going to run ninja anyway, and you're going to be very confused when random shit breaks.  You have done this a dozen times, despite this warning, and you're STILL going to waste my fucking time EVEN MORE because you don't take this warning seriously.  Fine.  Please place a checkmark emoji at the end of this line, every time you confuse the shit out of yourself and imagine subtle, impossible to follow bugs, because you didn't follow these instructions and do a complete rebuild: ✓

```bash
# Build all components (CORRECT)
cmake --build build

# Build and install (primary build command - CORRECT)
/usr/bin/cmake --build /home/jbyrd/git/llvm-mos/build --config Debug --target install --

# Full rebuild including picolibc and test binaries (RECOMMENDED)
/home/jbyrd/git/llvm-mos/.vscode/build-all.sh

# Build specific target - AVOID unless you know what you're doing
# cmake --build build --target lld

# Run all tests
cmake --build build --target check-all

# Run LLVM-specific tests
cmake --build build --target check-llvm

# Run MOS-specific tests
llvm-lit build/test/CodeGen/MOS/

# Run specific test file
llvm-lit llvm/test/CodeGen/MOS/hello-world.ll
```

### Code Quality
```bash
# Format code (uses LLVM style)
clang-format -i path/to/file.cpp

# Format all modified files
find . -name "*.cpp" -o -name "*.h" | xargs clang-format -i

# Update test CHECK lines
python3 llvm/utils/update_llc_test_checks.py llvm/test/CodeGen/MOS/*.ll
```

## Architecture Overview

### MOS Backend Structure

**Core Target Files** (`llvm/lib/Target/MOS/`):
- `MOSTargetMachine.cpp/.h` - Main target machine implementation
- `MOSInstrInfo.td` - Real 6502 instruction defigit -C /home/jbyrd/git/llvm-mos checkout upstream/main --detachnitions
- `MOSInstrPseudos.td` - Pseudo instructions for code generation
- `MOSRegisterInfo.td` - Register definitions including "imaginary registers"
- `MOSDevices.td` - Processor variant definitions (6502, 65C02, W65816, etc.)

**Key Optimization Passes**:
- `MOSZeroPageAlloc.cpp` - Allocates frequently-used values to zero-page memory
- `MOSStaticStackAlloc.cpp` - Converts dynamic to static stack allocation
- `MOSCopyOpt.cpp` - Optimizes register-to-register copies
- `MOSIndexIV.cpp` - Optimizes induction variables for indexed addressing
- `MOSNonReentrant.cpp` - Optimizes non-reentrant functions
- `MOSLateOptimization.cpp` - Post-register allocation optimizations

**GlobalISel Support**:
- `MOSCallLowering.cpp` - Function call/return handling
- `MOSLegalizerInfo.cpp` - Legal operation definitions
- `MOSRegisterBankInfo.cpp` - Register bank selection
- `MOSInstructionSelector.cpp` - Final instruction selection

### Register Architecture

The MOS backend uses an innovative approach to handle the 6502's limited register set:

**Real Registers**: A, X, Y (8-bit), S (stack pointer), P (processor status)
**Imaginary Registers**: Up to 256 8-bit registers (`rc0`-`rc255`) and 128 16-bit pointer registers (`rs0`-`rs127`) that map to zero-page memory locations and are treated as physical registers for allocation.

### Instruction Model

Two-layer instruction architecture:
1. **Machine Instructions** - Models actual 6502 instruction set with all irregularities
2. **Pseudo Instructions** - Regularized virtual instruction set for code generation, lowered during assembly printing

## Testing Guidelines

### Test Organization
- **MOS CodeGen Tests**: `llvm/test/CodeGen/MOS/`
- **Machine IR Tests**: Use `.mir` files for testing specific passes
- **Assembly Tests**: Test different assembler syntax variants (generic, ca65, xa65)

### Running Tests
```bash
# All MOS tests
llvm-lit llvm/test/CodeGen/MOS/

# Specific optimization pass tests
llvm-lit llvm/test/CodeGen/MOS/zeropage.ll
llvm-lit llvm/test/CodeGen/MOS/static-stack-allogit -C /home/jbyrd/git/llvm-mos checkout upstream/main --detachc.ll

# Run with specific FileCheck prefixes
llvm-lit --param=target_triple=mos-unknown-unknown test.ll
```

### Test Utilities
- Use `llvm/utils/update_llc_test_checks.py` to automatically generate CHECK lines
- Use `llvm/utils/update_test_checks.py` for general test updates
- FileCheck patterns should test both functionality and performance characteristics

## Common Development Patterns

### Adding New Instructions
1. Define in `MOSInstrInfo.td` with appropriate instruction format
2. Add pseudo version in `MOSInstrPseudos.td` if needed
3. Update `MOSInstrInfo.cpp` for any special handling
4. Add tests in `llvm/test/CodeGen/MOS/`

### Adding Processor Variants
1. Define new subtarget features in `MOSDevices.td`
2. Update instruction predicates to use new features
3. Add variant-specific tests

### Optimization Pass Development
1. Follow LLVM pass structure conventions
2. Consider zero-page allocation implications
3. Test with both optimized and unoptimized builds
4. Verify performance on real 6502 code patterns

## Key Configuration Details

### Important CMake Variables
- `LLVM_EXPERIMENTAL_TARGETS_TO_BUILD="MOS"` - Enables MOS target
- `LLVM_DEFAULT_TARGET_TRIPLE="mos-unknown-unknown"` - Default target
- `LLDB_INCLUDE_TESTS=OFF` - Disabled until stabilized
- Uses `MinSizeRel` build type by default for space optimization

### Processor Variants Supported
- 6502 (original with BCD)
- 6502X (with "illegal" opcodes)  
- 65C02, R65C02, W65C02 (CMOS variants)
- W65816 (16-bit capable)
- HUC6280 (PC Engine)
- SPC700 (Nintendo sound processor)
- 65CE02, 65DTV02, 4510, 45GS02

## Running and Tracing Assembly Programs

The llvm-mc tool includes a built-in emulator for running MOS programs directly.

### Quick Test (Single Command)
```bash
# Assemble and run with instruction trace (discard object file)
llvm-mc --triple=mos -filetype=obj -o /dev/null --run --trace program.s

# Example output:
# 0    $0000  A=00 X=00 Y=00 S=FF P=20    lda  #66
# 2    $0002  A=42 X=00 Y=00 S=FF P=20    ldx  #16
# 4    $0004  A=42 X=10 Y=00 S=FF P=20    ldy  #32
# 6    $0006  A=42 X=10 Y=20 S=FF P=20    brk
```

### Emulator Options
```bash
--run                    # Execute after assembly
--trace                  # Print each instruction with register state
--run-max-cycles=<N>     # Limit execution cycles (default 1M)
--semihost=<path>        # Enable file I/O sandboxed to directory
```

The trace output columns are: cycle count, PC, register state (A/X/Y/S/P), instruction.

BRK halts the emulator by default (exit code 0). See `.vscode/emulation.md` for full documentation.

## Debugging MOS Programs

The `.vscode/` directory contains scripts for source-level debugging of MOS programs using LLDB and MAME.

### Debug Session Scripts

**Starting a debug session:**
```bash
# Start with default test binary (float_qsort_O0)
.vscode/debug-start.sh

# Start with specific binary
.vscode/debug-start.sh /path/to/binary.elf
```

This starts:
- MAME with the `zbcm6502` machine and GDB stub on port 23946
- LLDB with MCP server on port 59999
- Sets a breakpoint on `partition` and continues to it

**Stopping a debug session:**
```bash
.vscode/debug-stop.sh
```

**Always run `debug-stop.sh` before starting a new session.** Stale MAME processes will cause connection failures.

### Connecting to LLDB

Claude can send LLDB commands via the MCP server:
```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"command","arguments":{"command":"bt"}}}' | nc localhost 59999
```git -C /home/jbyrd/git/llvm-mos checkout upstream/main --detach

Common commands: `bt` (backtrace), `frame variable`, `frame select N`, `register read`

### Log Files
- MAME: `/tmp/mame-debug.log`
- LLDB: `/tmp/lldb-debug.log`

### Test Binaries

Test programs are in `~/git/dwarf-torture/`. Build with `.vscode/build-all.sh` which builds llvm-mos, picolibc, and dwarf-torture together.

## Git Branch Management

**CRITICAL: When creating branches from `upstream/main`, always use `--no-track`:**

```bash
# CORRECT - prevents accidental pushes to upstream
git checkout -b feature/my-branch upstream/main --no-track

# WRONG - creates tracking to upstream, sync button will push to upstream!
git checkout -b feature/my-branch upstream/main
```

If you forget `--no-track`, immediately fix the tracking:
```bash
git branch --set-upstream-to=origin/feature/my-branch
```

The VSCode sync button pushes to the tracked remote. If a branch tracks `upstream/main`, clicking sync will push directly to the main llvm-mos repo, which is almost never what you want.

## Development Workflow

1. **Build**: Use MOS.cmake cache file for consistent configuration
2. **Test**: Run MOS-specific tests frequently during development
3. **Format**: Apply clang-format before committing
4. **Validate**: Ensure changes work across multiple processor variants
5. **Document**: Update tests and documentation for new features

The codebase follows LLVM coding standards strictly. All changes should include appropriate tests and maintain compatibility with the existing processor variant ecosystem.

When rendering change descriptions, DO NOT WRITE "Co-Authored By Claude" on ANYTHING.  That is extremely offensive.