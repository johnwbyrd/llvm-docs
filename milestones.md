# Milestones for Debug Support PRs

This document describes the milestones for landing debug support in llvm-mos/llvm-mos.

---

## Milestone 1: Bug Fixes - SUBMITTED

**Description:** Blocking bug fixes that must land first.

**Contents:**
- [PR #535](https://github.com/llvm-mos/llvm-mos/pull/535): Fix legalizer verification for debug builds
- [PR #536](https://github.com/llvm-mos/llvm-mos/pull/536): Fix i32 depth argument for return/frame address builtins

**Dependencies:** None

**Unblocks:** Debug builds work, builtins can be implemented

---

## Milestone 2: Core Infrastructure

**Description:** Core LLVM/lld/LLDB changes that enable MOS debug support. These are all upstream candidates.

**Contents:**
- lld .debug_frame GC: Support garbage collection of .debug_frame sections - Needs review
- CFI expressions: Add CFI expression instruction support (LLVM MC) - Needs review
- AsmPrinter defer: Allow targets to defer handler initialization (LLVM CodeGen) - Needs review
- G_MERGE salvaging: Implement debug info salvaging for G_MERGE_VALUES (GlobalISel) - Needs review
- LLDB ABI extension: Add ABI extension points for custom register contexts - Needs review

**Dependencies:** None (all independent of each other)

**Unblocks:**
- lld .debug_frame GC -> MOS CFI emission can work with --gc-sections
- CFI expressions -> MOS can emit complex CFI expressions
- AsmPrinter defer -> MOS can run GlobalDCE after debug handler init
- G_MERGE salvaging -> Debug info preserved for merged values
- LLDB ABI extension -> MOS LLDB plugin can provide custom register context

---

## Milestone 3: MOS Debug Support

**Description:** MOS-specific DWARF and CFI support. After this milestone, debuggers can unwind MOS call stacks.

**Contents:**
- MOS DWARF/CFI: Add MOS DWARF register numbering and CFI support

**Dependencies:** lld .debug_frame GC, CFI expressions, AsmPrinter defer

**Unblocks:** Source-level debugging of MOS programs (compiler side)

---

## Milestone 4: MOS LLDB Plugin

**Description:** Complete LLDB ABI plugin for MOS. After this milestone, LLDB can debug MOS programs via GDB stub.

**Contents:**
- MOS LLDB plugin: Add MOS ABI plugin for LLDB

**Dependencies:** LLDB ABI extension

**Unblocks:** Source-level debugging of MOS programs (debugger side)

---

## Milestone 5: MOS Builtins

**Description:** Implementation of GCC builtins for stack introspection.

**Contents:**
- MOS builtins: Implement __builtin_return_address and __builtin_frame_address

**Dependencies:** MOS DWARF/CFI

**Unblocks:** Programs can inspect their own call stack

---

## Milestone 6: Test Infrastructure - SUBMITTED

**Description:** Test infrastructure and UNSUPPORTED markers. Can land any time.

**Contents:**
- [PR #537](https://github.com/llvm-mos/llvm-mos/pull/537): Add MOS lit test features and mark unsupported tests
- [PR #538](https://github.com/llvm-mos/llvm-mos/pull/538): Add jump table limit regression test

**Dependencies:** None

**Unblocks:** Clean test runs on MOS target

---

## Milestone 7: Distribution

**Description:** Add debugging tools to MOS distribution.

**Contents:**
- Distribution: Add debugging tools to MOS distribution

**Dependencies:** None (but logically comes last)

**Unblocks:** Users get LLDB out of the box

---

## Summary

| Milestone | PRs | Status | Dependencies | Key Outcome |
|-----------|-----|--------|--------------|-------------|
| 1. Bug Fixes | #535, #536 | Submitted | None | Debug builds work |
| 2. Core Infrastructure | 5 pending | Needs review | None | Extension points ready |
| 3. MOS Debug Support | 1 pending | Blocked | M2 | CFI emission works |
| 4. MOS LLDB Plugin | 1 pending | Blocked | M2 | LLDB can debug MOS |
| 5. MOS Builtins | 1 pending | Blocked | M3 | Stack introspection |
| 6. Test Infrastructure | #537, #538 | Submitted | None | Clean test suite |
| 7. Distribution | 1 pending | Blocked | M4 | LLDB in toolchain |

## Submitted PRs

| PR | Description | Status |
|----|-------------|--------|
| [#535](https://github.com/llvm-mos/llvm-mos/pull/535) | Fix legalizer verification for debug builds | Open |
| [#536](https://github.com/llvm-mos/llvm-mos/pull/536) | Fix i32 depth argument for return/frame address builtins | Open |
| [#537](https://github.com/llvm-mos/llvm-mos/pull/537) | Add MOS lit test features and mark unsupported tests | Open |
| [#538](https://github.com/llvm-mos/llvm-mos/pull/538) | Add jump table limit regression test | Open |

## Critical Path

The critical path to "LLDB can debug MOS programs" has two parallel tracks that must both complete:

```
Milestone 1 (Bug Fixes) <- SUBMITTED
    |
Milestone 2 (Core Infrastructure)
    |
    +-- Compiler Track:                    +-- Debugger Track:
    |   lld .debug_frame GC                |   LLDB ABI extension
    |   CFI expressions                    |           |
    |   AsmPrinter defer                   |   Milestone 4 (LLDB Plugin)
    |           |                          |   MOS LLDB plugin
    |   Milestone 3 (MOS Debug)            |           |
    |   MOS DWARF/CFI ---------------------+---> [LLDB can debug MOS]
    |           |
    |   Milestone 5 (Builtins)
    |   __builtin_return/frame_address

Milestone 6 (Test Infrastructure) <- SUBMITTED (parallel)
```

**Both tracks are critical:**
- Without MOS DWARF/CFI: No unwind info in binaries
- Without MOS LLDB plugin: No debugger to read the unwind info

## Next Steps

1. Wait for PRs #535, #536, #537, #538 to be reviewed and merged
2. Prepare core infrastructure PRs (Milestone 2) for submission
3. Once Milestone 2 merges, submit MOS-specific PRs (Milestones 3-5)
4. Finally, update distribution config (Milestone 7)
