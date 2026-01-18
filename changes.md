# Changes Analysis: main to feature/debug/v18

This document summarizes all file changes from main to HEAD, organized by PR.

---

## Already Merged (PRs #520-530)

These files were changed by PRs that have already been merged to main:

| File | PR |
|------|-----|
| llvm/lib/Transforms/Utils/SimplifyLibCalls.cpp | #520 |
| lldb/source/Utility/DataExtractor.cpp | #521 |
| lldb/tools/lldb-dap/Handler/LaunchRequestHandler.cpp | #522 |
| llvm/lib/CodeGen/GlobalISel/InlineAsmLowering.cpp | #523 |
| lldb/source/Utility/ArchSpec.cpp | #524 |
| clang/lib/Driver/ToolChains/MOSToolchain.cpp | #525 |
| lld/ELF/Arch/MOS.cpp | #526 |
| llvm/lib/Target/MOS/MCTargetDesc/MOSAsmBackend.cpp | #527 |
| llvm/lib/Target/MOS/MOSISelLowering.cpp | #528 |
| llvm/lib/Target/MOS/MOSISelLowering.h | #528 |
| llvm/lib/Target/MOS/MOSMachineFunctionInfo.h | #529 (clone only) |
| llvm/lib/Target/MOS/MOSLegalizerInfo.cpp | #530 (FP libcalls only) |

Also merged via PR #516 (not debug-related):
- .github/workflows/llvm-project-tests.yml
- llvm/lib/Target/MOS/AsmParser/MOSAsmParser.cpp
- llvm/lib/Target/MOS/MCTargetDesc/MOSMCExpr.cpp
- llvm/test/MC/MOS/modifiers.s

---

## Pending Changes by PR

### PR 12: Legalizer Terminal Actions

| File | Change |
|------|--------|
| llvm/lib/Target/MOS/MOSLegalizerInfo.cpp | Add `.unsupported()` to G_BSWAP and FP op chains |
| llvm/test/CodeGen/MOS/legalizer.mir | NEW: Test for legalizer rules |

---

### PR 13: i32 Depth Argument Fix

| File | Change |
|------|--------|
| clang/lib/CodeGen/CGBuiltin.cpp | Cast depth arg to i32 for returnaddress/frameaddress |

---

### PR 14: lld .debug_frame GC

| File | Change |
|------|--------|
| lld/ELF/Config.h | Add DebugFrameInputSection, DebugFrameSection declarations |
| lld/ELF/Driver.cpp | Collect DebugFrameInputSections, call combineDebugFrameSections() |
| lld/ELF/InputFiles.cpp | Create DebugFrameInputSection for .debug_frame |
| lld/ELF/InputSection.cpp | Implement DebugFrameInputSection::split() |
| lld/ELF/InputSection.h | Define DebugFrameInputSection class |
| lld/ELF/SyntheticSections.cpp | Implement DebugFrameSection synthetic section |
| lld/ELF/SyntheticSections.h | Declare DebugFrameSection, combineDebugFrameSections() |
| lld/ELF/Writer.cpp | Finalize .debug_frame early |

---

### PR 15: CFI Expression Support

| File | Change |
|------|--------|
| llvm/include/llvm/MC/MCDwarf.h | Add OpDefCfaExpression, OpExpression, OpValExpression |
| llvm/lib/MC/MCDwarf.cpp | Emit CFI expression instructions |
| llvm/lib/CodeGen/AsmPrinter/AsmPrinterDwarf.cpp | Print CFI expressions |
| llvm/lib/CodeGen/CFIInstrInserter.cpp | Handle expression types (no-op) |
| llvm/lib/CodeGen/MachineOperand.cpp | MIR printing for CFI expressions |
| llvm/lib/CodeGen/MIRParser/MILexer.h | Token types for CFI keywords |
| llvm/lib/CodeGen/MIRParser/MILexer.cpp | Lex CFI keywords |
| llvm/lib/CodeGen/MIRParser/MIParser.cpp | Parse CFI instructions |
| llvm/lib/DWARFCFIChecker/DWARFCFIState.cpp | Warn for unsupported expressions |

---

### PR 16: AsmPrinter Defer Init

| File | Change |
|------|--------|
| llvm/include/llvm/CodeGen/AsmPrinter.h | Add shouldCallBeginModule(), callBeginModule() |
| llvm/lib/CodeGen/AsmPrinter/AsmPrinter.cpp | Implement deferred initialization |

---

### PR 17: G_MERGE_VALUES Salvaging

| File | Change |
|------|--------|
| llvm/lib/CodeGen/CodeGenCommonISel.cpp | Add salvageDebugInfo for G_MERGE_VALUES |
| llvm/lib/CodeGen/GlobalISel/Utils.cpp | Call salvageDebugInfo in eraseInstrs() |
| llvm/test/CodeGen/X86/GlobalISel/x86-calllowering-dbg-trunc.ll | Update test expectations |

---

### PR 18: LLDB ABI Extension Points

| File | Change |
|------|--------|
| lldb/include/lldb/Target/ABI.h | Add CreateRegisterContextForThread, ProvidesRegisterInfoOverride, GetCanonicalRegisterInfo |
| lldb/source/Plugins/Process/gdb-remote/ProcessGDBRemote.cpp | Check for ABI register info override |
| lldb/source/Plugins/Process/gdb-remote/ThreadGDBRemote.cpp | Check for ABI-provided register context |
| lldb/source/Plugins/Process/gdb-remote/ThreadGDBRemote.h | Add GetRegisterInfoSP() |

**DO NOT INCLUDE:**
| lldb/source/Symbol/DWARFCallFrameInfo.cpp | Debug logging only - REVERT |

---

### PR 19: MOS DWARF/CFI Support

| File | Change |
|------|--------|
| llvm/lib/Target/MOS/MOSRegisterInfo.td | DWARF register numbers, add PC register |
| llvm/lib/Target/MOS/MCTargetDesc/MOSMCAsmInfo.cpp | Set CalleeSaveStackSlotSize, ExceptionsType |
| llvm/lib/Target/MOS/MCTargetDesc/MOSMCTargetDesc.cpp | Initial CFI frame state, RA register setup |
| llvm/lib/Target/MOS/MOSFrameLowering.cpp | CFI emission, getFrameIndexReference, stack diagnostics |
| llvm/lib/Target/MOS/MOSFrameLowering.h | Declare new methods |
| llvm/lib/Target/MOS/MOSAsmPrinter.cpp | Override shouldCallBeginModule, null check for streamer |
| llvm/lib/TargetParser/Triple.cpp | Add MOS to getDefaultExceptionHandling |
| llvm/test/CodeGen/MOS/large-stack-frame.ll | NEW: Stack size limit test |
| llvm/test/CodeGen/MOS/prologepilog-ir.mir | NEW: CFI emission MIR test |
| llvm/test/CodeGen/MOS/prologepilog.mir | NEW: CFI emission MIR test |
| llvm/test/CodeGen/MOS/zp-alloc.ll | Updated CHECK lines for CFI |

---

### PR 20: MOS LLDB Plugin

| File | Change |
|------|--------|
| lldb/source/Plugins/ABI/CMakeLists.txt | Add MOS to ABI plugins |
| lldb/source/Plugins/ABI/MOS/ABISysV_mos.cpp | NEW: Main ABI implementation |
| lldb/source/Plugins/ABI/MOS/ABISysV_mos.h | NEW: Header |
| lldb/source/Plugins/ABI/MOS/CMakeLists.txt | NEW: Build config |
| lldb/source/Plugins/ABI/MOS/MOSImaginaryRegisters.cpp | NEW: Imaginary register definitions |
| lldb/source/Plugins/ABI/MOS/MOSImaginaryRegisters.h | NEW: Header |
| lldb/source/Plugins/ABI/MOS/MOSRegisterContext.cpp | NEW: Custom register context |
| lldb/source/Plugins/ABI/MOS/MOSRegisterContext.h | NEW: Header |

---

### PR 21: MOS Builtins

| File | Change |
|------|--------|
| llvm/lib/Target/MOS/MOSFrameLowering.cpp | Return address capture in prologue, CFI fixes |
| llvm/lib/Target/MOS/MOSFrameLowering.h | Add getHardwareStackBase declaration |
| llvm/lib/Target/MOS/MOSLegalizerInfo.cpp | Custom lowering for G_RETURNADDRESS, G_FRAMEADDRESS |
| llvm/lib/Target/MOS/MOSMachineFunctionInfo.h | Add getReturnAddrFrameIndex |
| llvm/lib/Target/MOS/MOSSubtarget.h | Add getHardwareStackBase |
| clang/test/CodeGen/MOS/builtin-frame-address.c | NEW: Clang test |
| llvm/test/CodeGen/MOS/frame-pointer-cfi.ll | NEW: CFI test for frame pointer |

---

### PR 22: Test Infrastructure

| File | Change |
|------|--------|
| llvm/test/lit.cfg.py | Add MOS feature flags |
| llvm/test/CodeGen/Generic/2002-04-16-StackFrameSizeAlignment.ll | UNSUPPORTED: small-address-space |
| llvm/test/CodeGen/Generic/2007-04-08-MultipleFrameIndices.ll | UNSUPPORTED: limited-inline-asm |
| llvm/test/CodeGen/Generic/2007-04-27-InlineAsm-X-Dest.ll | UNSUPPORTED: limited-inline-asm |
| llvm/test/CodeGen/Generic/2007-04-27-LargeMemObject.ll | UNSUPPORTED: limited-inline-asm |
| llvm/test/CodeGen/Generic/2007-12-17-InvokeAsm.ll | UNSUPPORTED: no-invoke-support |
| llvm/test/CodeGen/Generic/2009-11-16-BadKillsCrash.ll | UNSUPPORTED: no-invoke-support |
| llvm/test/CodeGen/Generic/2012-06-08-APIntCrash.ll | UNSUPPORTED: no-vector-legalization |
| llvm/test/CodeGen/Generic/MachineBranchProb.ll | UNSUPPORTED: no-selectiondag-debug |
| llvm/test/CodeGen/Generic/add-with-overflow.ll | UNSUPPORTED: global-isel-only |
| llvm/test/CodeGen/Generic/allow-check.ll | UNSUPPORTED: global-isel-only |
| llvm/test/CodeGen/Generic/denormal-fp-math-cl-opt.ll | UNSUPPORTED: global-isel-only |
| llvm/test/CodeGen/Generic/donothing.ll | UNSUPPORTED: global-isel-only |
| llvm/test/CodeGen/Generic/extractelement-shuffle.ll | UNSUPPORTED: global-isel-only |
| llvm/test/CodeGen/Generic/fpowi-promote.ll | UNSUPPORTED: global-isel-only |
| llvm/test/CodeGen/Generic/inline-asm-mem-clobber.ll | UNSUPPORTED: limited-inline-asm |
| llvm/test/CodeGen/Generic/pr24662.ll | UNSUPPORTED: global-isel-only |
| llvm/test/CodeGen/Generic/select-cc.ll | UNSUPPORTED: global-isel-only |
| llvm/test/CodeGen/Generic/selectiondag-dump-filter.ll | UNSUPPORTED: no-selectiondag-debug |
| llvm/test/CodeGen/Generic/v-split.ll | UNSUPPORTED: no-vector-legalization |
| llvm/test/CodeGen/Generic/vector-casts.ll | UNSUPPORTED: no-vector-legalization |
| llvm/test/CodeGen/Generic/vector.ll | UNSUPPORTED: no-vector-legalization |
| llvm/test/DebugInfo/Generic/debug-label-mi.ll | UNSUPPORTED: no-selectiondag-debug |
| llvm/test/DebugInfo/Generic/debug-label-opt.ll | UNSUPPORTED: no-selectiondag-debug |
| llvm/test/DebugInfo/Generic/directives-only.ll | UNSUPPORTED: no-selectiondag-debug |
| llvm/test/DebugInfo/Generic/extended-loc-directive.ll | UNSUPPORTED: no-selectiondag-debug |
| llvm/test/DebugInfo/Generic/linear-dbg-value.ll | UNSUPPORTED: no-selectiondag-debug |
| llvm/test/DebugInfo/Generic/multiline.ll | UNSUPPORTED: no-selectiondag-debug |
| llvm/test/DebugInfo/debug-bool-const-location.ll | UNSUPPORTED: target=mos |
| llvm/test/DebugInfo/fixed-point.ll | UNSUPPORTED: target=mos |
| llvm/test/Feature/optnone-llc.ll | UNSUPPORTED: global-isel-only |
| llvm/unittests/DebugInfo/DWARF/DwarfUtils.cpp | Return UnknownArch for 16-bit archs |

---

### PR 23: Jump Table Test

| File | Change |
|------|--------|
| llvm/test/CodeGen/MOS/jump-table-limit.ll | NEW: 256-entry switch test |

---

### PR 24: Distribution

| File | Change |
|------|--------|
| clang/cmake/caches/MOS.cmake | Add lldb, lldb-dap, llvm-config, etc. to distribution |

---

## Files to NOT Submit

| File | Reason |
|------|--------|
| lldb/source/Symbol/DWARFCallFrameInfo.cpp | Debug logging only |

---

## Files with Multiple PRs

Some files are modified by multiple PRs. When creating PR branches, extract only the relevant changes:

| File | PRs | Notes |
|------|-----|-------|
| llvm/lib/Target/MOS/MOSLegalizerInfo.cpp | 12, 21 | PR 12: terminal actions; PR 21: builtin lowering |
| llvm/lib/Target/MOS/MOSFrameLowering.cpp | 19, 21 | PR 19: CFI emission; PR 21: return addr capture |
| llvm/lib/Target/MOS/MOSFrameLowering.h | 19, 21 | PR 19: getFrameIndexReference; PR 21: getHardwareStackBase |
| llvm/lib/Target/MOS/MOSMachineFunctionInfo.h | (merged), 21 | #529: clone(); PR 21: getReturnAddrFrameIndex |
| llvm/lib/Target/MOS/MOSAsmPrinter.cpp | 19 | shouldCallBeginModule + null check |
