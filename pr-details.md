# PR Creation Details

This document describes the PRs for debug support.

## Source and Target

- **Source:** feature/debug/v19 branch
- **Target:** Individual PR branches based on upstream/main
- **Repo:** llvm-mos/llvm-mos

---

## Submitted PRs (4 PRs)

These PRs have been created and are awaiting review.

---

### PR #535: Fix legalizer verification for debug builds

**URL:** https://github.com/llvm-mos/llvm-mos/pull/535
**Branch:** `pr/legalizer-terminal-actions`
**Status:** Open

**Files:**
```
llvm/lib/Target/MOS/MOSLegalizerInfo.cpp
```

**Summary:**
Fix LegalizerInfo verification failures in debug builds after upstream commit 018a5dc14371. Add `.unsupported()` terminal actions to G_BSWAP and floating-point op rule chains.

---

### PR #536: Fix i32 depth argument for return/frame address builtins

**URL:** https://github.com/llvm-mos/llvm-mos/pull/536
**Branch:** `pr/clang-i32-depth-arg`
**Status:** Open

**Files:**
```
clang/lib/CodeGen/CGBuiltin.cpp
```

**Summary:**
Cast depth argument to i32 before calling llvm.returnaddress/llvm.frameaddress intrinsics. Fixes IR generation on 16-bit targets (MOS, AVR, MSP430). Upstream candidate.

---

### PR #537: Add MOS lit test features and mark unsupported tests

**URL:** https://github.com/llvm-mos/llvm-mos/pull/537
**Branch:** `pr/mos-test-infrastructure`
**Status:** Open

**Files:**
```
llvm/test/lit.cfg.py
llvm/test/CodeGen/Generic/*.ll (21 files)
llvm/test/DebugInfo/Generic/*.ll (6 files)
llvm/test/DebugInfo/debug-bool-const-location.ll
llvm/test/DebugInfo/fixed-point.ll
llvm/test/Feature/optnone-llc.ll
llvm/unittests/DebugInfo/DWARF/DwarfUtils.cpp
```

**Summary:**
Add MOS-specific lit feature flags and UNSUPPORTED markers for tests using features MOS doesn't support. Fix DwarfUtils.cpp to handle 16-bit architectures.

---

### PR #538: Add jump table limit regression test

**URL:** https://github.com/llvm-mos/llvm-mos/pull/538
**Branch:** `pr/mos-jump-table-test`
**Status:** Open

**Files:**
```
llvm/test/CodeGen/MOS/jump-table-limit.ll
```

**Summary:**
Regression test for PR #528 (jump table 255-entry limit). Verifies 256-entry switch compiles correctly.

---

## Need Review Before Submitting (5 PRs)

These need additional work before submission.

| Future PR | Commit | Description | Concern |
|-----------|--------|-------------|---------|
| lld .debug_frame GC | `6cf8c20401c9` | Support garbage collection of .debug_frame | Needs tests |
| CFI expressions | `6d9dcc94d395` | Add CFI expression instruction support | Needs tests |
| AsmPrinter defer | `6f0cd1d2b319` | Allow targets to defer handler init | Needs docs/test |
| G_MERGE salvaging | `7dbed40f35c4` | Debug info salvaging for G_MERGE_VALUES | Verify X86 test |
| LLDB ABI extension | `2c060e634796` | ABI extension points for register contexts | Needs justification |

---

## Depend on Earlier PRs (4 PRs)

| Future PR | Commit | Description | Depends On |
|-----------|--------|-------------|------------|
| MOS DWARF/CFI | `e2354dea9f32` | MOS DWARF register numbering and CFI | lld, CFI, AsmPrinter |
| MOS LLDB plugin | `0b524f6c09ce` | MOS ABI plugin for LLDB | LLDB ABI extension |
| MOS builtins | `c70991451668` | __builtin_return/frame_address tests | MOS DWARF/CFI |
| Distribution | `a762f8bf4573` | Add debugging tools to distribution | MOS LLDB plugin |

---

## Files NOT to Submit

- `lldb/source/Symbol/DWARFCallFrameInfo.cpp` - debug logging only
