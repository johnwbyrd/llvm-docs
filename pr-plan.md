# PR Plan for Debug Support Changes

This document outlines the PRs to submit to llvm-mos/llvm-mos, organized by readiness.

**Source:** feature/debug/v19 branch
**Target:** llvm-mos/llvm-mos main branch (via upstream remote)

---

## Already Merged PRs

These PRs have been merged to main and require no further action:

| PR | Description |
|----|-------------|
| [#520](https://github.com/llvm-mos/llvm-mos/pull/520) | Fix null pointer dereference in SimplifyLibCalls |
| [#521](https://github.com/llvm-mos/llvm-mos/pull/521) | Fix DataExtractor crash on empty buffer |
| [#522](https://github.com/llvm-mos/llvm-mos/pull/522) | Add launch validation to lldb-dap |
| [#523](https://github.com/llvm-mos/llvm-mos/pull/523) | Add FIXMEs for GlobalISel inline asm limitations |
| [#524](https://github.com/llvm-mos/llvm-mos/pull/524) | Fix MOS address size in ArchSpec |
| [#525](https://github.com/llvm-mos/llvm-mos/pull/525) | Don't pass --gc-sections for relocatable links |
| [#526](https://github.com/llvm-mos/llvm-mos/pull/526) | Handle R_MOS_NONE relocation |
| [#527](https://github.com/llvm-mos/llvm-mos/pull/527) | Handle MCExpr::Specifier in MOSAsmBackend |
| [#528](https://github.com/llvm-mos/llvm-mos/pull/528) | Fix jump table size limit and getNumRegisters |
| [#529](https://github.com/llvm-mos/llvm-mos/pull/529) | Implement MOSFunctionInfo::clone() |
| [#530](https://github.com/llvm-mos/llvm-mos/pull/530) | Expand floating-point libcall support |

---

## Submitted PRs (Awaiting Review)

These PRs have been created and are awaiting review.

### PR #535: Fix legalizer verification for debug builds

**URL:** https://github.com/llvm-mos/llvm-mos/pull/535
**Branch:** `pr/legalizer-terminal-actions`

**Files:**
- llvm/lib/Target/MOS/MOSLegalizerInfo.cpp

**Summary:** Add `.unsupported()` terminal actions to legalizer rule chains. Without this, debug builds crash during target initialization with "ill-defined LegalizerInfo" error.

---

### PR #536: Fix i32 depth argument for return/frame address builtins

**URL:** https://github.com/llvm-mos/llvm-mos/pull/536
**Branch:** `pr/clang-i32-depth-arg`

**Files:**
- clang/lib/CodeGen/CGBuiltin.cpp

**Summary:** The `llvm.returnaddress` and `llvm.frameaddress` intrinsics require an i32 depth argument, but clang uses `unsigned int` which may be 16-bit on MOS, AVR, and MSP430. Upstream candidate.

---

### PR #537: Add MOS lit test features and mark unsupported tests

**URL:** https://github.com/llvm-mos/llvm-mos/pull/537
**Branch:** `pr/mos-test-infrastructure`

**Files:**
- llvm/test/lit.cfg.py
- llvm/test/CodeGen/Generic/*.ll (21 files)
- llvm/test/DebugInfo/Generic/*.ll (6 files)
- llvm/test/DebugInfo/*.ll (2 files)
- llvm/test/Feature/optnone-llc.ll
- llvm/unittests/DebugInfo/DWARF/DwarfUtils.cpp

**Summary:** Add MOS-specific lit feature flags and UNSUPPORTED markers to tests using features MOS doesn't support.

---

### PR #538: Add jump table limit regression test

**URL:** https://github.com/llvm-mos/llvm-mos/pull/538
**Branch:** `pr/mos-jump-table-test`

**Files:**
- llvm/test/CodeGen/MOS/jump-table-limit.ll

**Summary:** Regression test for already-merged PR #528. Verifies 256-entry switch compiles correctly.

---

## Need Review Before Submitting

These PRs need additional review, testing, or refinement.

### lld .debug_frame GC: Support garbage collection of .debug_frame sections

**Commit:** `6cf8c20401c9`
**Status:** Needs review

**Files:**
- lld/ELF/Config.h
- lld/ELF/Driver.cpp
- lld/ELF/InputFiles.cpp
- lld/ELF/InputSection.cpp
- lld/ELF/InputSection.h
- lld/ELF/SyntheticSections.cpp
- lld/ELF/SyntheticSections.h
- lld/ELF/Writer.cpp

**Concerns:**
- Large change (~450 lines)
- Should have lld tests to verify behavior
- May need lld maintainer review

---

### CFI expressions: Add CFI expression instruction support

**Commit:** `6d9dcc94d395`
**Status:** Needs review

**Files:**
- llvm/include/llvm/MC/MCDwarf.h
- llvm/lib/MC/MCDwarf.cpp
- llvm/lib/CodeGen/AsmPrinter/AsmPrinterDwarf.cpp
- llvm/lib/CodeGen/CFIInstrInserter.cpp
- llvm/lib/CodeGen/MachineOperand.cpp
- llvm/lib/CodeGen/MIRParser/MILexer.h
- llvm/lib/CodeGen/MIRParser/MILexer.cpp
- llvm/lib/CodeGen/MIRParser/MIParser.cpp
- llvm/lib/DWARFCFIChecker/DWARFCFIState.cpp

**Concerns:**
- Core LLVM MC/CodeGen change
- Needs tests demonstrating the new functionality
- May benefit from upstream LLVM review

---

### AsmPrinter defer: Allow targets to defer AsmPrinter handler initialization

**Commit:** `6f0cd1d2b319`
**Status:** Needs review

**Files:**
- llvm/include/llvm/CodeGen/AsmPrinter.h
- llvm/lib/CodeGen/AsmPrinter/AsmPrinter.cpp

**Concerns:**
- Adds new virtual method to AsmPrinter
- Needs documentation or test showing the use case

---

### G_MERGE salvaging: Implement debug info salvaging for G_MERGE_VALUES

**Commit:** `7dbed40f35c4`
**Status:** Needs review

**Files:**
- llvm/lib/CodeGen/CodeGenCommonISel.cpp
- llvm/lib/CodeGen/GlobalISel/Utils.cpp
- llvm/test/CodeGen/X86/GlobalISel/x86-calllowering-dbg-trunc.ll

**Concerns:**
- Has X86 test update - should verify test passes
- Otherwise fairly self-contained

---

### LLDB ABI extension: Add LLDB ABI extension points for custom register contexts

**Commit:** `2c060e634796`
**Status:** Needs review

**Files:**
- lldb/include/lldb/Target/ABI.h
- lldb/source/Plugins/Process/gdb-remote/ProcessGDBRemote.cpp
- lldb/source/Plugins/Process/gdb-remote/ThreadGDBRemote.cpp
- lldb/source/Plugins/Process/gdb-remote/ThreadGDBRemote.h

**Concerns:**
- Core LLDB change
- May benefit from justification/documentation

---

## Depend on Earlier PRs

These PRs have dependencies and cannot be submitted until prerequisites merge.

### MOS DWARF/CFI: Add MOS DWARF register numbering and CFI support

**Commit:** `e2354dea9f32`
**Status:** Depends on lld .debug_frame GC, CFI expressions, AsmPrinter defer

**Files:**
- llvm/lib/Target/MOS/MOSRegisterInfo.td
- llvm/lib/Target/MOS/MCTargetDesc/MOSMCAsmInfo.cpp
- llvm/lib/Target/MOS/MCTargetDesc/MOSMCTargetDesc.cpp
- llvm/lib/Target/MOS/MOSFrameLowering.cpp
- llvm/lib/Target/MOS/MOSFrameLowering.h
- llvm/lib/Target/MOS/MOSAsmPrinter.cpp
- llvm/lib/TargetParser/Triple.cpp
- llvm/test/CodeGen/MOS/*.ll, *.mir

---

### MOS LLDB plugin: Add MOS ABI plugin for LLDB

**Commit:** `0b524f6c09ce`
**Status:** Depends on LLDB ABI extension

**Files:**
- lldb/source/Plugins/ABI/CMakeLists.txt
- lldb/source/Plugins/ABI/MOS/* (8 new files)

---

### MOS builtins: Add tests for __builtin_return_address and __builtin_frame_address

**Commit:** `c70991451668`
**Status:** Depends on MOS DWARF/CFI

**Files:**
- clang/test/CodeGen/MOS/builtin-frame-address.c
- llvm/test/CodeGen/MOS/frame-pointer-cfi.ll
- llvm/lib/Target/MOS/MOSLegalizerInfo.cpp
- llvm/lib/Target/MOS/MOSMachineFunctionInfo.h
- llvm/lib/Target/MOS/MOSSubtarget.h

---

### Distribution: Add debugging tools to MOS distribution

**Commit:** `a762f8bf4573`
**Status:** Depends on MOS LLDB plugin (logically)

**Files:**
- clang/cmake/caches/MOS.cmake

---

## Summary

| Status | PRs | Count |
|--------|-----|-------|
| Merged | #520-530 | 11 |
| Submitted | #535, #536, #537, #538 | 4 |
| Needs review | lld, CFI, AsmPrinter, G_MERGE, LLDB ABI | 5 |
| Has dependencies | MOS DWARF/CFI, LLDB plugin, builtins, distribution | 4 |

**Total: 24 PRs (11 merged, 4 submitted, 9 pending)**

## Files NOT to Submit

- `lldb/source/Symbol/DWARFCallFrameInfo.cpp` - contains debug logging only
