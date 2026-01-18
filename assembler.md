# MOS Assembler Enhancements

This document analyzes assembler features to add to llvm-mos, split into two categories:
1. **General MOS features** - Useful for all llvm-mos users
2. **ca65 compatibility mode** - For cc65 interoperability

---

## Goals

1. **Primary:** Assemble cc65 C compiler output (`cl65 -S`)
2. **Stretch:** Assemble cc65 runtime library source files
3. **Bonus:** Add generally useful features to the MOS assembler

---

## Integration Workflow (cc65 → llvm-mos)

```bash
# Step 1: cc65 compiles C to ca65 assembly (stops before assembler)
~/git/cc65/bin/cl65 -S -t c64 -o output.s input.c

# Step 2: llvm-mc assembles ca65 assembly to ELF object
llvm-mc -triple=mos -x ca65 output.s -filetype=obj -o output.o

# Step 3: lld links ELF objects
ld.lld output.o runtime.o -o output
```

---

## Directive Census (cc65 Runtime Library)

Usage counts from `libsrc/runtime/*.s`, `libsrc/common/*.s`, `asminc/*.inc`:

| Directive | Count | Category |
|-----------|-------|----------|
| `.charmap` | 1280 | Character encoding |
| `.proc`/`.endproc` | 130 each | Procedures |
| `.if`/`.else`/`.endif` | 84/77/93 | Conditionals |
| `.struct`/`.endstruct` | 42 each | Data structures |
| `.code` | 39 | Segments |
| `.elseif` | 35 | Conditionals |
| `.macro`/`.endmacro` | 25 each | Macros |
| `.bss` | 20 | Segments |
| `.global` | 18 | Symbols |
| `.include` | 15 | File inclusion |
| `.data` | 15 | Segments |
| `.define` | 10 | Text substitution |
| `.enum`/`.endenum` | 10 each | Enumerations |
| `.rodata` | 8 | Segments |
| `.export` | 7 | Symbols |
| `.segment` | 6 | Segments |
| `.import` | 6 | Symbols |
| `.globalzp` | 5 | Symbols |
| `.repeat`/`.endrepeat` | 4 each | Loops |
| `.importzp` | 4 | Symbols |

---

# Part 1: General MOS Parser Features

These features benefit all llvm-mos users, not just cc65 compatibility. They should be added to the main MOS assembler parser.

---

## 1.1 Character Encoding (`.charmap`)

### Why General
- Commodore systems use PETSCII, not ASCII
- Atari systems use ATASCII
- Apple II has its own character set
- **Any llvm-mos user targeting these platforms needs correct string encoding**
- This isn't ca65-specific - it's a fundamental 6502 development need

### What It Does
Maps source character codes to target character codes for string literals:
```asm
; Map ASCII lowercase to PETSCII
.charmap $61, $01    ; 'a' -> PETSCII $01
.charmap $62, $02    ; 'b' -> PETSCII $02
; ...

.byte "hello"        ; Assembles to PETSCII, not ASCII
```

### Implementation
- **Difficulty:** Medium
- **Approach:**
  1. Add `uint8_t CharMap[256]` to MOS assembler state, initialized to identity
  2. Add `.charmap` directive handler to update the table
  3. Hook string literal parsing to apply translation
  4. Affects `.byte "..."`, `.asciiz "..."`, and similar directives

### Complexity Details
- LLVM's `AsmParser` has `parseEscapedString()` that handles string literals
- We need to intercept after escape processing but before byte emission
- May need to override string directive handlers in `MOSAsmParser`
- Alternative: Handle `.byte`, `.asciiz` entirely in MOS parser when strings present

### Predefined Character Maps
Could ship predefined maps as include files:
- `petscii.inc` - Commodore PETSCII
- `atascii.inc` - Atari ATASCII
- `apple2.inc` - Apple II character set

Or provide a `.charmap_petscii` / `.charmap_atascii` shortcut directive.

---

## 1.2 Data Structures (`.struct` / `.endstruct`)

### Why General
- Useful for defining hardware register layouts (VIC-II, SID, CIA, POKEY, etc.)
- Standard feature in many assemblers (MASM, NASM, ca65, etc.)
- Not ca65-specific at all - just good assembler functionality
- Makes assembly code more readable and maintainable

### What It Does
```asm
.struct VIC
    sprite0_x   .byte       ; offset 0
    sprite0_y   .byte       ; offset 1
    sprite1_x   .byte       ; offset 2
    sprite1_y   .byte       ; offset 3
    ; ... etc
    border      .byte       ; offset 32 ($20)
    background  .byte       ; offset 33 ($21)
.endstruct

; Usage:
lda VIC_BASE + VIC::border    ; Load border color
sta VIC_BASE + VIC::background

; Size:
lda #.sizeof(VIC)             ; Get structure size
```

### Symbols Created
- `structname::fieldname` = byte offset of field
- `.sizeof(structname)` = total size of struct

### Field Types
| Type | Size | Notes |
|------|------|-------|
| `.byte` | 1 | Single byte |
| `.word` | 2 | 16-bit little-endian |
| `.addr` | 2 | Same as `.word` (address) |
| `.dword` | 4 | 32-bit |
| `.res N` | N | Reserved bytes |

### Implementation
- **Difficulty:** Hard
- **Approach:**
  1. Track struct definitions in a map: `structname` → `{fields, total_size}`
  2. Each field: `{name, offset, size}`
  3. When parsing `structname::fieldname`, look up and return offset value
  4. Implement `.sizeof()` as expression function

### Data Structures Needed
```cpp
struct StructField {
    StringRef Name;
    int64_t Offset;
    int64_t Size;
};

struct StructDef {
    StringRef Name;
    std::vector<StructField> Fields;
    int64_t TotalSize;
};

// In MOSAsmParser:
StringMap<StructDef> StructDefs;
```

### Scoped Symbol Syntax (`::`)
- Need to handle `foo::bar` in expression parsing
- When encountering `identifier::identifier`, look up in struct definitions
- If found, substitute the offset value

### Nested Structs and Unions
ca65 supports nested structs and `.union`/`.endunion`:
```asm
.struct CIA
    PRA     .byte
    PRB     .byte
    .union
        .struct
            TALO    .byte
            TAHI    .byte
        .endstruct
        TA      .word
    .endunion
.endstruct
```

**Recommendation:** Start without union support, add later if needed.

---

## 1.3 Enumerations (`.enum` / `.endenum`)

### Why General
- Standard feature for defining related constants
- More readable than manual `.set` sequences
- Not ca65-specific

### What It Does
```asm
.enum JoyDirection
    NONE            ; = 0
    UP              ; = 1
    DOWN            ; = 2
    LEFT            ; = 3
    RIGHT           ; = 4
.endenum

lda joy_state
cmp #JoyDirection::UP
beq handle_up
```

### Implementation
- **Difficulty:** Medium
- **Approach:**
  1. Parse enum name
  2. For each identifier, assign next sequential value (or explicit value if given)
  3. Create symbols as `enumname::membername` = value
  4. Track enum for potential `.sizeof()` support

### Simpler Than Structs
- No offset calculation needed
- Just sequential value assignment
- Can reuse `::` scoped symbol infrastructure from structs

---

## 1.4 Repeat Loops (`.repeat` / `.endrepeat`)

### Why General
- Useful for generating tables, unrolled loops
- Standard assembler feature

### What It Does
```asm
.repeat 8, i
    lda table + i
    sta dest + i
.endrepeat
; Expands to 8 load/store pairs
```

### Implementation
- **Difficulty:** Easy
- **LLVM equivalent:** `.rept` / `.endr`
- Just need to alias the directive names
- LLVM's `.rept` already exists

---

## 1.5 Assertions (`.assert`)

### Why General
- Useful for catching assembly-time errors
- Validates assumptions about addresses, sizes, etc.

### What It Does
```asm
.assert * < $C000, error, "Code too large for RAM"
.assert .sizeof(buffer) = 256, error, "Buffer must be 256 bytes"
```

### Implementation
- **Difficulty:** Easy
- **LLVM equivalent:** Conditional `.error` / `.warning`
- Parse expression, evaluate, emit error/warning if false

---

## 1.6 Local Label Scoping

### Why General
- Prevents label collisions in larger projects
- More readable than numeric labels (`1:`, `1b`, `1f`)
- Common need in assembly programming

### ca65 Syntax
ca65 uses `@label` for local labels scoped to `.proc`:
```asm
.proc foo
    @loop:
        dex
        bne @loop
.endproc
```

### Alternative: Generic Scopes
Instead of ca65's `@` syntax, could use a more general scoping mechanism:
```asm
.scope foo
    .local loop
    loop:
        dex
        bne loop
.endscope
```

### Implementation Options

**Option A: Support `@label` in general parser**
- Requires lexer changes to recognize `@` as label prefix
- Transform to `.Lscope_label` internally
- Simpler for users

**Option B: Use LLVM's existing local label mechanism**
- LLVM has `.L` prefix for local symbols
- Less convenient but already works

**Option C: Add general `.scope`/`.endscope` with `.local`**
- More verbose but more explicit
- Works with existing lexer

**Recommendation:** Add `@label` support to general parser - it's widely understood syntax.

### Implementation
- **Difficulty:** Medium
- **Approach:**
  1. Track current scope name (from `.proc`, `.scope`, or function label)
  2. When lexer sees `@identifier`, transform to `.L{scope}_{identifier}`
  3. Requires lexer modification in MOS target

---

# Part 2: ca65 Compatibility Mode

These features are ca65-specific and should only be active in ca65 compatibility mode (`-x ca65`).

---

## 2.1 Mode Activation

### Command Line
```bash
llvm-mc -triple=mos -x ca65 input.s -o output.o
```

### Implementation
- Add `CA65Mode` flag to `MOSAsmParser`
- Set based on `-x ca65` command line option
- CA65-specific directives only recognized when flag is set

---

## 2.2 Symbol Visibility Directives

### `.export sym [, sym...]`
- **ca65 meaning:** Make symbol visible to linker
- **LLVM equivalent:** `.globl sym`
- **Implementation:** Parse symbol list, emit `.globl` for each

### `.import sym [, sym...]`
- **ca65 meaning:** Declare external symbol
- **LLVM equivalent:** No-op (LLVM auto-resolves undefined symbols)
- **Implementation:** Parse and ignore

### `.global sym [, sym...]`
- **ca65 meaning:** Export + Import (make visible, resolve if external)
- **LLVM equivalent:** `.globl sym`

### `.importzp sym [, sym...]`
- **ca65 meaning:** Import as zero-page symbol
- **LLVM equivalent:** `.zeropage sym` (already in MOS)

### `.exportzp sym [, sym...]`
- **ca65 meaning:** Export as zero-page symbol
- **LLVM equivalent:** `.globl sym` + `.zeropage sym`

### `.globalzp sym [, sym...]`
- **ca65 meaning:** Global + zero-page
- **LLVM equivalent:** `.globl sym` + `.zeropage sym`

---

## 2.3 Segment Directives

### `.segment "NAME"`
- **ca65 meaning:** Switch to named segment
- **LLVM equivalent:** `.section NAME`
- **Mapping:**
  | ca65 Segment | ELF Section |
  |--------------|-------------|
  | `"CODE"` | `.text` |
  | `"DATA"` | `.data` |
  | `"BSS"` | `.bss` |
  | `"RODATA"` | `.rodata` |
  | `"ZEROPAGE"` | `.zeropage` |
  | Other | Pass through as-is |

### `.code`
- **LLVM equivalent:** `.section .text,"ax",@progbits`

### `.data`
- **LLVM equivalent:** `.section .data,"aw",@progbits`

### `.bss`
- **LLVM equivalent:** `.section .bss,"aw",@nobits`

### `.rodata`# MOS Assembler Enhancements

This document analyzes assembler features to add to llvm-mos, split into two categories:
1. **General MOS features** - Useful for all llvm-mos users
2. **ca65 compatibility mode** - For cc65 interoperability

---

## Goals

1. **Primary:** Assemble cc65 C compiler output (`cl65 -S`)
2. **Stretch:** Assemble cc65 runtime library source files
3. **Bonus:** Add generally useful features to the MOS assembler

---

## Integration Workflow (cc65 → llvm-mos)

```bash
# Step 1: cc65 compiles C to ca65 assembly (stops before assembler)
~/git/cc65/bin/cl65 -S -t c64 -o output.s input.c

# Step 2: llvm-mc assembles ca65 assembly to ELF object
llvm-mc -triple=mos -x ca65 output.s -filetype=obj -o output.o

# Step 3: lld links ELF objects
ld.lld output.o runtime.o -o output
```

---

## Directive Census (cc65 Runtime Library)

Usage counts from `libsrc/runtime/*.s`, `libsrc/common/*.s`, `asminc/*.inc`:

| Directive | Count | Category |
|-----------|-------|----------|
| `.charmap` | 1280 | Character encoding |
| `.proc`/`.endproc` | 130 each | Procedures |
| `.if`/`.else`/`.endif` | 84/77/93 | Conditionals |
| `.struct`/`.endstruct` | 42 each | Data structures |
| `.code` | 39 | Segments |
| `.elseif` | 35 | Conditionals |
| `.macro`/`.endmacro` | 25 each | Macros |
| `.bss` | 20 | Segments |
| `.global` | 18 | Symbols |
| `.include` | 15 | File inclusion |
| `.data` | 15 | Segments |
| `.define` | 10 | Text substitution |
| `.enum`/`.endenum` | 10 each | Enumerations |
| `.rodata` | 8 | Segments |
| `.export` | 7 | Symbols |
| `.segment` | 6 | Segments |
| `.import` | 6 | Symbols |
| `.globalzp` | 5 | Symbols |
| `.repeat`/`.endrepeat` | 4 each | Loops |
| `.importzp` | 4 | Symbols |

---

# Part 1: General MOS Parser Features

These features benefit all llvm-mos users, not just cc65 compatibility. They should be added to the main MOS assembler parser.

---

## 1.1 Character Encoding (`.charmap`)

### Why General
- Commodore systems use PETSCII, not ASCII
- Atari systems use ATASCII
- Apple II has its own character set
- **Any llvm-mos user targeting these platforms needs correct string encoding**
- This isn't ca65-specific - it's a fundamental 6502 development need

### What It Does
Maps source character codes to target character codes for string literals:
```asm
; Map ASCII lowercase to PETSCII
.charmap $61, $01    ; 'a' -> PETSCII $01
.charmap $62, $02    ; 'b' -> PETSCII $02
; ...

.byte "hello"        ; Assembles to PETSCII, not ASCII
```

### Implementation
- **Difficulty:** Medium
- **Approach:**
  1. Add `uint8_t CharMap[256]` to MOS assembler state, initialized to identity
  2. Add `.charmap` directive handler to update the table
  3. Hook string literal parsing to apply translation
  4. Affects `.byte "..."`, `.asciiz "..."`, and similar directives

### Complexity Details
- LLVM's `AsmParser` has `parseEscapedString()` that handles string literals
- We need to intercept after escape processing but before byte emission
- May need to override string directive handlers in `MOSAsmParser`
- Alternative: Handle `.byte`, `.asciiz` entirely in MOS parser when strings present

### Predefined Character Maps
Could ship predefined maps as include files:
- `petscii.inc` - Commodore PETSCII
- `atascii.inc` - Atari ATASCII
- `apple2.inc` - Apple II character set

Or provide a `.charmap_petscii` / `.charmap_atascii` shortcut directive.

---

## 1.2 Data Structures (`.struct` / `.endstruct`)

### Why General
- Useful for defining hardware register layouts (VIC-II, SID, CIA, POKEY, etc.)
- Standard feature in many assemblers (MASM, NASM, ca65, etc.)
- Not ca65-specific at all - just good assembler functionality
- Makes assembly code more readable and maintainable

### What It Does
```asm
.struct VIC
    sprite0_x   .byte       ; offset 0
    sprite0_y   .byte       ; offset 1
    sprite1_x   .byte       ; offset 2
    sprite1_y   .byte       ; offset 3
    ; ... etc
    border      .byte       ; offset 32 ($20)
    background  .byte       ; offset 33 ($21)
.endstruct

; Usage:
lda VIC_BASE + VIC::border    ; Load border color
sta VIC_BASE + VIC::background

; Size:
lda #.sizeof(VIC)             ; Get structure size
```

### Symbols Created
- `structname::fieldname` = byte offset of field
- `.sizeof(structname)` = total size of struct

### Field Types
| Type | Size | Notes |
|------|------|-------|
| `.byte` | 1 | Single byte |
| `.word` | 2 | 16-bit little-endian |
| `.addr` | 2 | Same as `.word` (address) |
| `.dword` | 4 | 32-bit |
| `.res N` | N | Reserved bytes |

### Implementation
- **Difficulty:** Hard
- **Approach:**
  1. Track struct definitions in a map: `structname` → `{fields, total_size}`
  2. Each field: `{name, offset, size}`
  3. When parsing `structname::fieldname`, look up and return offset value
  4. Implement `.sizeof()` as expression function

### Data Structures Needed
```cpp
struct StructField {
    StringRef Name;
    int64_t Offset;
    int64_t Size;
};

struct StructDef {
    StringRef Name;
    std::vector<StructField> Fields;
    int64_t TotalSize;
};

// In MOSAsmParser:
StringMap<StructDef> StructDefs;
```

### Scoped Symbol Syntax (`::`)
- Need to handle `foo::bar` in expression parsing
- When encountering `identifier::identifier`, look up in struct definitions
- If found, substitute the offset value

### Nested Structs and Unions
ca65 supports nested structs and `.union`/`.endunion`:
```asm
.struct CIA
    PRA     .byte
    PRB     .byte
    .union
        .struct
            TALO    .byte
            TAHI    .byte
        .endstruct
        TA      .word
    .endunion
.endstruct
```

**Recommendation:** Start without union support, add later if needed.

---

## 1.3 Enumerations (`.enum` / `.endenum`)

### Why General
- Standard feature for defining related constants
- More readable than manual `.set` sequences
- Not ca65-specific

### What It Does
```asm
.enum JoyDirection
    NONE            ; = 0
    UP              ; = 1
    DOWN            ; = 2
    LEFT            ; = 3
    RIGHT           ; = 4
.endenum

lda joy_state
cmp #JoyDirection::UP
beq handle_up
```

### Implementation
- **Difficulty:** Medium
- **Approach:**
  1. Parse enum name
  2. For each identifier, assign next sequential value (or explicit value if given)
  3. Create symbols as `enumname::membername` = value
  4. Track enum for potential `.sizeof()` support

### Simpler Than Structs
- No offset calculation needed
- Just sequential value assignment
- Can reuse `::` scoped symbol infrastructure from structs

---

## 1.4 Repeat Loops (`.repeat` / `.endrepeat`)

### Why General
- Useful for generating tables, unrolled loops
- Standard assembler feature

### What It Does
```asm
.repeat 8, i
    lda table + i
    sta dest + i
.endrepeat
; Expands to 8 load/store pairs
```

### Implementation
- **Difficulty:** Easy
- **LLVM equivalent:** `.rept` / `.endr`
- Just need to alias the directive names
- LLVM's `.rept` already exists

---

## 1.5 Assertions (`.assert`)

### Why General
- Useful for catching assembly-time errors
- Validates assumptions about addresses, sizes, etc.

### What It Does
```asm
.assert * < $C000, error, "Code too large for RAM"
.assert .sizeof(buffer) = 256, error, "Buffer must be 256 bytes"
```

### Implementation
- **Difficulty:** Easy
- **LLVM equivalent:** Conditional `.error` / `.warning`
- Parse expression, evaluate, emit error/warning if false

---

## 1.6 Local Label Scoping

### Why General
- Prevents label collisions in larger projects
- More readable than numeric labels (`1:`, `1b`, `1f`)
- Common need in assembly programming

### ca65 Syntax
ca65 uses `@label` for local labels scoped to `.proc`:
```asm
.proc foo
    @loop:
        dex
        bne @loop
.endproc
```

### Alternative: Generic Scopes
Instead of ca65's `@` syntax, could use a more general scoping mechanism:
```asm
.scope foo
    .local loop
    loop:
        dex
        bne loop
.endscope
```

### Implementation Options

**Option A: Support `@label` in general parser**
- Requires lexer changes to recognize `@` as label prefix
- Transform to `.Lscope_label` internally
- Simpler for users

**Option B: Use LLVM's existing local label mechanism**
- LLVM has `.L` prefix for local symbols
- Less convenient but already works

**Option C: Add general `.scope`/`.endscope` with `.local`**
- More verbose but more explicit
- Works with existing lexer

**Recommendation:** Add `@label` support to general parser - it's widely understood syntax.

### Implementation
- **Difficulty:** Medium
- **Approach:**
  1. Track current scope name (from `.proc`, `.scope`, or function label)
  2. When lexer sees `@identifier`, transform to `.L{scope}_{identifier}`
  3. Requires lexer modification in MOS target

---

# Part 2: ca65 Compatibility Mode

These features are ca65-specific and should only be active in ca65 compatibility mode (`-x ca65`).

---

## 2.1 Mode Activation

### Command Line
```bash
llvm-mc -triple=mos -x ca65 input.s -o output.o
```

### Implementation
- Add `CA65Mode` flag to `MOSAsmParser`
- Set based on `-x ca65` command line option
- CA65-specific directives only recognized when flag is set

---

## 2.2 Symbol Visibility Directives

### `.export sym [, sym...]`
- **ca65 meaning:** Make symbol visible to linker
- **LLVM equivalent:** `.globl sym`
- **Implementation:** Parse symbol list, emit `.globl` for each

### `.import sym [, sym...]`
- **ca65 meaning:** Declare external symbol
- **LLVM equivalent:** No-op (LLVM auto-resolves undefined symbols)
- **Implementation:** Parse and ignore

### `.global sym [, sym...]`
- **ca65 meaning:** Export + Import (make visible, resolve if external)
- **LLVM equivalent:** `.globl sym`

### `.importzp sym [, sym...]`
- **ca65 meaning:** Import as zero-page symbol
- **LLVM equivalent:** `.zeropage sym` (already in MOS)

### `.exportzp sym [, sym...]`
- **ca65 meaning:** Export as zero-page symbol
- **LLVM equivalent:** `.globl sym` + `.zeropage sym`

### `.globalzp sym [, sym...]`
- **ca65 meaning:** Global + zero-page
- **LLVM equivalent:** `.globl sym` + `.zeropage sym`

---

## 2.3 Segment Directives

### `.segment "NAME"`
- **ca65 meaning:** Switch to named segment
- **LLVM equivalent:** `.section NAME`
- **Mapping:**
  | ca65 Segment | ELF Section |
  |--------------|-------------|
  | `"CODE"` | `.text` |
  | `"DATA"` | `.data` |
  | `"BSS"` | `.bss` |
  | `"RODATA"` | `.rodata` |
  | `"ZEROPAGE"` | `.zeropage` |
  | Other | Pass through as-is |

### `.code`
- **LLVM equivalent:** `.section .text,"ax",@progbits`

### `.data`
- **LLVM equivalent:** `.section .data,"aw",@progbits`

### `.bss`
- **LLVM equivalent:** `.section .bss,"aw",@nobits`

### `.rodata`
- **LLVM equivalent:** `.section .rodata,"a",@progbits`

---

## 2.4 Procedure Directives

### `.proc name [: near|far]`
- **ca65 meaning:** Start procedure (creates label, starts local scope)
- **LLVM translation:**
  1. Emit label `name:`
  2. Set current scope to `name` for `@label` handling
- **Notes:** `near`/`far` modifier is for ld65, can ignore

### `.endproc`
- **ca65 meaning:** End procedure
- **LLVM translation:** Clear current scope name

---

## 2.5 Control Directives (No-ops)

These ca65 directives control assembler behavior that doesn't apply to LLVM:

| Directive | ca65 Meaning | LLVM Handling |
|-----------|--------------|---------------|
| `.fopt compiler,"..."` | File metadata | No-op |
| `.smart on\|off` | Smart mode | No-op |
| `.autoimport on\|off` | Auto-import | No-op (always on) |
| `.case on\|off` | Case sensitivity | No-op (always on) |

### `.setcpu "name"`
- **ca65 meaning:** Set target CPU
- **Options:**
  1. No-op (use command-line `-mcpu`)
  2. Switch subtarget features mid-file (complex)
- **Recommendation:** No-op with warning if different from command-line

### `.debuginfo on|off`
- **ca65 meaning:** Enable/disable debug info
- **LLVM:** Could toggle `.file`/`.loc` emission
- **Recommendation:** No-op initially

---

## 2.6 CPU Conditionals

### `.ifp02` / `.ifp4510` / `.ifp45GS02`
- **ca65 meaning:** Conditional based on CPU type
- **LLVM translation:** Define predefined symbols at init:
  ```
  __CPU_6502__ = 1    ; for 6502
  __CPU_65C02__ = 1   ; for 65C02
  __CPU_4510__ = 1    ; for 4510
  __CPU_45GS02__ = 1  ; for 45GS02
  ```
- Then translate `.ifp02` to `.if __CPU_6502__`

### `.cap(CPU_HAS_*)`
- **ca65 meaning:** Test CPU capability
- **LLVM translation:** Define capability symbols:
  ```
  CPU_HAS_ZPIND = 1   ; 65C02+ indirect without Y
  CPU_HAS_INA = 1     ; 65C02+ INC A
  CPU_HAS_STZ = 1     ; 65C02+ store zero
  CPU_HAS_BRA8 = 1    ; 65C02+ unconditional branch
  ```
- Then `.cap()` is just symbol lookup

---

## 2.7 Macro Packages (`.macpack`)

### What It Does
```asm
.macpack longbranch   ; Include long branch macros
.macpack generic      ; Include generic macros
```

### `longbranch` Package
Defines pseudo-instructions for branch-over-jump patterns:
```asm
jeq target    ; Expands to: beq *+5 / jmp target (if target far)
jne target    ;             bne *+5 / jmp target
jmi target    ; etc.
```

### Implementation Options

**Option A: Ship macro definition files**
- Create `macpack-longbranch.inc` with LLVM `.macro` definitions
- `.macpack longbranch` → `.include "macpack-longbranch.inc"`
- **Pros:** Simple, maintainable
- **Cons:** Extra files to ship

**Option B: Implement as pseudo-instructions**
- Add `JEQ`, `JNE`, etc. to instruction table
- Expand during assembly
- **Pros:** More efficient
- **Cons:** More complex

**Recommendation:** Option A (ship macro files)

### `generic` Package
Defines convenience macros:
- `add` - Add to accumulator
- `sub` - Subtract from accumulator
- `bge` - Branch if greater or equal (unsigned)
- `blt` - Branch if less than (unsigned)
- etc.

---

## 2.8 Text Substitution (`.define`)

### What It Does
```asm
.define VERSION "1.0"
.define DOUBLE(x) ((x) * 2)

.byte VERSION           ; Expands to .byte "1.0"
lda #DOUBLE(5)          ; Expands to lda #((5) * 2)
```

### Why ca65-Only
- Conflicts with LLVM's `.set` semantics
- Requires lexer-level text substitution
- Complex to implement correctly

### Implementation
- **Difficulty:** Medium-Hard
- **Approach:**
  1. Track defined text macros
  2. During tokenization, check if identifier is defined macro
  3. If so, substitute text and re-tokenize
- **Alternative:** Only support simple (non-parameterized) defines

---

## 2.9 Data Directives

### `.word val [, val...]`
- **LLVM equivalent:** `.2byte val` for each
- **Notes:** LLVM `.word` is target-dependent, use `.2byte` explicitly

### `.addr val [, val...]`
- **LLVM equivalent:** `.2byte val` for each
- **Notes:** Same as `.word` (16-bit address)

### `.res n [, fill]`
- **LLVM equivalent:** `.skip n` or `.fill n, 1, fill`

---

# Part 3: Implementation Plan

## Phase 1: General Parser Foundation (~300 lines)

Add to main MOS parser:
1. `.charmap` directive + string translation infrastructure
2. `.repeat`/`.endrepeat` as aliases for `.rept`/`.endr`
3. `.assert` directive

**Files:**
- `llvm/lib/Target/MOS/AsmParser/MOSAsmParser.cpp`

## Phase 2: ca65 Basic Mode (~250 lines)

Add ca65 compatibility layer:
1. `-x ca65` command-line flag and mode tracking
2. Symbol directives: `.export`, `.import`, `.importzp`, `.exportzp`, `.global`, `.globalzp`
3. Segment directives: `.segment`, `.code`, `.data`, `.bss`, `.rodata`
4. Procedure directives: `.proc`, `.endproc`
5. Control directives: `.fopt`, `.smart`, `.autoimport`, `.case`, `.setcpu`, `.debuginfo` (all no-op)

**Files:**
- `llvm/lib/Target/MOS/AsmParser/MOSAsmParser.cpp` (mode flag, delegation)
- `llvm/lib/Target/MOS/AsmParser/MOSCA65AsmParser.cpp` (new file, ca65 handlers)

## Phase 3: Local Labels (~150 lines)

1. Track current scope (procedure name)
2. Lexer modification to recognize `@label`
3. Transform `@label` to `.L{scope}_{label}`

**Files:**
- `llvm/lib/Target/MOS/AsmParser/MOSAsmParser.cpp`

## Phase 4: Structures (~400 lines)

Add to main MOS parser:
1. `.struct`/`.endstruct` directive handlers
2. Struct definition tracking
3. `structname::fieldname` expression parsing
4. `.sizeof()` expression function

**Files:**
- `llvm/lib/Target/MOS/AsmParser/MOSAsmParser.cpp`

## Phase 5: Enumerations (~100 lines)

Add to main MOS parser:
1. `.enum`/`.endenum` directive handlers
2. Reuse `::` scoping from structs

## Phase 6: CPU Conditionals (~100 lines)

Add to ca65 mode:
1. Define `__CPU_*` and `CPU_HAS_*` symbols at init
2. `.ifp02`/etc. directive handlers
3. `.cap()` expression function

## Phase 7: Macro Packages (~50 lines + macro files)

1. Create `macpack-longbranch.inc`, `macpack-generic.inc`
2. `.macpack` directive handler → `.include`

## Phase 8: Polish

1. `.define` support (if needed)
2. Error messages
3. Test suite
4. Documentation

---

# Part 4: Risk Assessment

| Feature | Risk | Mitigation |
|---------|------|------------|
| `.charmap` | Medium - needs string interception | May need to handle string directives entirely in MOS |
| `.struct` | High - significant new feature | Start simple, no nested structs/unions initially |
| `::` scoping | Medium - affects expression parsing | Careful integration with existing parser |
| `.sizeof()` | Medium - tied to struct | Required for structs to be useful |
| `@label` | Low - straightforward transform | Lexer modification needed |
| `.define` | High - lexer-level changes | Defer or limit to simple cases |

---

# Part 5: Test Strategy

## Unit Tests
```
llvm/test/MC/MOS/
├── charmap.s              # Character encoding tests
├── struct.s               # Structure definition tests
├── enum.s                 # Enumeration tests
├── ca65-directives.s      # ca65 mode directive tests
├── ca65-segments.s        # Segment translation tests
├── ca65-local-labels.s    # @label handling tests
└── ca65-macpack.s         # Macro package tests
```

## Integration Tests
- Assemble actual cc65 runtime files
- Compare output with ca65-assembled versions

## Success Criteria
```bash
# Phase 1-2 complete when this works:
echo 'int add(int a, int b) { return a+b; }' > test.c
cl65 -S -t none -o test.s test.c
llvm-mc -triple=mos -x ca65 test.s -filetype=obj -o test.o

# Phase 3-7 complete when this works:
llvm-mc -triple=mos -x ca65 ~/git/cc65/libsrc/runtime/add.s -filetype=obj -o add.o
```

---

# References

- [ca65 Users Guide](https://cc65.github.io/doc/ca65.html) - Official ca65 documentation
- [cc65 Users Guide](https://cc65.github.io/doc/cc65.html) - C compiler documentation
- cc65 source: `~/git/cc65/`
- LLVM MC documentation: `llvm/docs/MCInternals.rst`

- **LLVM equivalent:** `.section .rodata,"a",@progbits`

---

## 2.4 Procedure Directives

### `.proc name [: near|far]`
- **ca65 meaning:** Start procedure (creates label, starts local scope)
- **LLVM translation:**
  1. Emit label `name:`
  2. Set current scope to `name` for `@label` handling
- **Notes:** `near`/`far` modifier is for ld65, can ignore

### `.endproc`
- **ca65 meaning:** End procedure
- **LLVM translation:** Clear current scope name

---

## 2.5 Control Directives (No-ops)

These ca65 directives control assembler behavior that doesn't apply to LLVM:

| Directive | ca65 Meaning | LLVM Handling |
|-----------|--------------|---------------|
| `.fopt compiler,"..."` | File metadata | No-op |
| `.smart on\|off` | Smart mode | No-op |
| `.autoimport on\|off` | Auto-import | No-op (always on) |
| `.case on\|off` | Case sensitivity | No-op (always on) |

### `.setcpu "name"`
- **ca65 meaning:** Set target CPU
- **Options:**
  1. No-op (use command-line `-mcpu`)
  2. Switch subtarget features mid-file (complex)
- **Recommendation:** No-op with warning if different from command-line

### `.debuginfo on|off`
- **ca65 meaning:** Enable/disable debug info
- **LLVM:** Could toggle `.file`/`.loc` emission
- **Recommendation:** No-op initially

---

## 2.6 CPU Conditionals

### `.ifp02` / `.ifp4510` / `.ifp45GS02`
- **ca65 meaning:** Conditional based on CPU type
- **LLVM translation:** Define predefined symbols at init:
  ```
  __CPU_6502__ = 1    ; for 6502
  __CPU_65C02__ = 1   ; for 65C02
  __CPU_4510__ = 1    ; for 4510
  __CPU_45GS02__ = 1  ; for 45GS02
  ```
- Then translate `.ifp02` to `.if __CPU_6502__`

### `.cap(CPU_HAS_*)`
- **ca65 meaning:** Test CPU capability
- **LLVM translation:** Define capability symbols:
  ```
  CPU_HAS_ZPIND = 1   ; 65C02+ indirect without Y
  CPU_HAS_INA = 1     ; 65C02+ INC A
  CPU_HAS_STZ = 1     ; 65C02+ store zero
  CPU_HAS_BRA8 = 1    ; 65C02+ unconditional branch
  ```
- Then `.cap()` is just symbol lookup

---

## 2.7 Macro Packages (`.macpack`)

### What It Does
```asm
.macpack longbranch   ; Include long branch macros
.macpack generic      ; Include generic macros
```

### `longbranch` Package
Defines pseudo-instructions for branch-over-jump patterns:
```asm
jeq target    ; Expands to: beq *+5 / jmp target (if target far)
jne target    ;             bne *+5 / jmp target
jmi target    ; etc.
```

### Implementation Options

**Option A: Ship macro definition files**
- Create `macpack-longbranch.inc` with LLVM `.macro` definitions
- `.macpack longbranch` → `.include "macpack-longbranch.inc"`
- **Pros:** Simple, maintainable
- **Cons:** Extra files to ship

**Option B: Implement as pseudo-instructions**
- Add `JEQ`, `JNE`, etc. to instruction table
- Expand during assembly
- **Pros:** More efficient
- **Cons:** More complex

**Recommendation:** Option A (ship macro files)

### `generic` Package
Defines convenience macros:
- `add` - Add to accumulator
- `sub` - Subtract from accumulator
- `bge` - Branch if greater or equal (unsigned)
- `blt` - Branch if less than (unsigned)
- etc.

---

## 2.8 Text Substitution (`.define`)

### What It Does
```asm
.define VERSION "1.0"
.define DOUBLE(x) ((x) * 2)

.byte VERSION           ; Expands to .byte "1.0"
lda #DOUBLE(5)          ; Expands to lda #((5) * 2)
```

### Why ca65-Only
- Conflicts with LLVM's `.set` semantics
- Requires lexer-level text substitution
- Complex to implement correctly

### Implementation
- **Difficulty:** Medium-Hard
- **Approach:**
  1. Track defined text macros
  2. During tokenization, check if identifier is defined macro
  3. If so, substitute text and re-tokenize
- **Alternative:** Only support simple (non-parameterized) defines

---

## 2.9 Data Directives

### `.word val [, val...]`
- **LLVM equivalent:** `.2byte val` for each
- **Notes:** LLVM `.word` is target-dependent, use `.2byte` explicitly

### `.addr val [, val...]`
- **LLVM equivalent:** `.2byte val` for each
- **Notes:** Same as `.word` (16-bit address)

### `.res n [, fill]`
- **LLVM equivalent:** `.skip n` or `.fill n, 1, fill`

---

# Part 3: Implementation Plan

## Phase 1: General Parser Foundation (~300 lines)

Add to main MOS parser:
1. `.charmap` directive + string translation infrastructure
2. `.repeat`/`.endrepeat` as aliases for `.rept`/`.endr`
3. `.assert` directive

**Files:**
- `llvm/lib/Target/MOS/AsmParser/MOSAsmParser.cpp`

## Phase 2: ca65 Basic Mode (~250 lines)

Add ca65 compatibility layer:
1. `-x ca65` command-line flag and mode tracking
2. Symbol directives: `.export`, `.import`, `.importzp`, `.exportzp`, `.global`, `.globalzp`
3. Segment directives: `.segment`, `.code`, `.data`, `.bss`, `.rodata`
4. Procedure directives: `.proc`, `.endproc`
5. Control directives: `.fopt`, `.smart`, `.autoimport`, `.case`, `.setcpu`, `.debuginfo` (all no-op)

**Files:**
- `llvm/lib/Target/MOS/AsmParser/MOSAsmParser.cpp` (mode flag, delegation)
- `llvm/lib/Target/MOS/AsmParser/MOSCA65AsmParser.cpp` (new file, ca65 handlers)

## Phase 3: Local Labels (~150 lines)

1. Track current scope (procedure name)
2. Lexer modification to recognize `@label`
3. Transform `@label` to `.L{scope}_{label}`

**Files:**
- `llvm/lib/Target/MOS/AsmParser/MOSAsmParser.cpp`

## Phase 4: Structures (~400 lines)

Add to main MOS parser:
1. `.struct`/`.endstruct` directive handlers
2. Struct definition tracking
3. `structname::fieldname` expression parsing
4. `.sizeof()` expression function

**Files:**
- `llvm/lib/Target/MOS/AsmParser/MOSAsmParser.cpp`

## Phase 5: Enumerations (~100 lines)

Add to main MOS parser:
1. `.enum`/`.endenum` directive handlers
2. Reuse `::` scoping from structs

## Phase 6: CPU Conditionals (~100 lines)

Add to ca65 mode:
1. Define `__CPU_*` and `CPU_HAS_*` symbols at init
2. `.ifp02`/etc. directive handlers
3. `.cap()` expression function

## Phase 7: Macro Packages (~50 lines + macro files)

1. Create `macpack-longbranch.inc`, `macpack-generic.inc`
2. `.macpack` directive handler → `.include`

## Phase 8: Polish

1. `.define` support (if needed)
2. Error messages
3. Test suite
4. Documentation

---

# Part 4: Risk Assessment

| Feature | Risk | Mitigation |
|---------|------|------------|
| `.charmap` | Medium - needs string interception | May need to handle string directives entirely in MOS |
| `.struct` | High - significant new feature | Start simple, no nested structs/unions initially |
| `::` scoping | Medium - affects expression parsing | Careful integration with existing parser |
| `.sizeof()` | Medium - tied to struct | Required for structs to be useful |
| `@label` | Low - straightforward transform | Lexer modification needed |
| `.define` | High - lexer-level changes | Defer or limit to simple cases |

---

# Part 5: Test Strategy

## Unit Tests
```
llvm/test/MC/MOS/
├── charmap.s              # Character encoding tests
├── struct.s               # Structure definition tests
├── enum.s                 # Enumeration tests
├── ca65-directives.s      # ca65 mode directive tests
├── ca65-segments.s        # Segment translation tests
├── ca65-local-labels.s    # @label handling tests
└── ca65-macpack.s         # Macro package tests
```

## Integration Tests
- Assemble actual cc65 runtime files
- Compare output with ca65-assembled versions

## Success Criteria
```bash
# Phase 1-2 complete when this works:
echo 'int add(int a, int b) { return a+b; }' > test.c
cl65 -S -t none -o test.s test.c
llvm-mc -triple=mos -x ca65 test.s -filetype=obj -o test.o

# Phase 3-7 complete when this works:
llvm-mc -triple=mos -x ca65 ~/git/cc65/libsrc/runtime/add.s -filetype=obj -o add.o
```

---

# References

- [ca65 Users Guide](https://cc65.github.io/doc/ca65.html) - Official ca65 documentation
- [cc65 Users Guide](https://cc65.github.io/doc/cc65.html) - C compiler documentation
- cc65 source: `~/git/cc65/`
- LLVM MC documentation: `llvm/docs/MCInternals.rst`
