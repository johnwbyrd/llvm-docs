# llvm-emu-test

A validation tool for LLVM emulators that tests instruction semantics against SingleStepTests-format JSON test vectors.

---

## Purpose

llvm-emu-test validates that an LLVM target's emulator (`emu::Context` implementation) correctly executes instructions by comparing against pre-computed test vectors. Each test specifies:

- Initial CPU state (registers, flags, memory)
- Expected final state after executing one instruction
- Expected cycle count and bus activity

This enables:
- Validation of new emulator implementations
- Regression testing after changes
- Verification against hardware ground truth (when test vectors are hardware-derived)

---

## Command Line Interface

### Synopsis

```
llvm-emu-test [options] <test-path>...
```

### Arguments

| Argument | Description |
|----------|-------------|
| `<test-path>` | JSON test file or directory containing JSON files |

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `--triple=<triple>` | (required) | Target triple (e.g., `mos`, `spc700`) |
| `--mattr=<features>` | `""` | Target features (e.g., `+wdc65c02`) |
| `-j <N>` | `0` | Parallel jobs (0 = number of cores) |
| `-v` / `--verbose` | off | Print each test as it runs |
| `--stop-on-fail` | off | Stop after first failure |
| `--no-cycles` | off | Skip cycle count validation |
| `--no-bus` | off | Skip bus activity validation |
| `--max-failures=<N>` | `0` | Stop after N failures (0 = unlimited) |
| `--filter=<glob>` | `*` | Only run tests matching pattern |
| `--exclude=<opcodes>` | `""` | Comma-separated opcodes to skip (e.g., `8b,ab,9b`) |
| `--dump-failures` | off | Print full state diff on failure |
| `--json-output=<file>` | `""` | Write results to JSON file |

### Response Files

Standard LLVM response file support is enabled:

```bash
llvm-emu-test @6502.rsp
```

Where `6502.rsp` contains:
```
--triple=mos
-j16
tests/6502/v1/
```

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All tests passed |
| 1 | One or more tests failed |
| 2 | Error (bad arguments, file not found, target not found, etc.) |

---

## Test Format

llvm-emu-test reads SingleStepTests JSON format. Each `.json` file contains an array of test cases.

### Test Case Structure

```json
{
  "name": "a9 ee",
  "initial": {
    "pc": 1234,
    "s": 253,
    "a": 0,
    "x": 0,
    "y": 0,
    "p": 36,
    "ram": [
      [1234, 169],
      [1235, 238]
    ]
  },
  "final": {
    "pc": 1236,
    "s": 253,
    "a": 238,
    "x": 0,
    "y": 0,
    "p": 164,
    "ram": [
      [1234, 169],
      [1235, 238]
    ]
  },
  "cycles": [
    [1234, 169, "read"],
    [1235, 238, "read"]
  ]
}
```

### Fields

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Human-readable test identifier |
| `initial` | object | CPU state before execution |
| `final` | object | Expected CPU state after execution |
| `cycles` | array | Expected bus activity (optional) |

### State Object (initial/final)

For MOS 6502 family:

| Field | Type | Description |
|-------|------|-------------|
| `pc` | integer | Program counter (16-bit) |
| `s` | integer | Stack pointer (8-bit) |
| `a` | integer | Accumulator (8-bit) |
| `x` | integer | X register (8-bit) |
| `y` | integer | Y register (8-bit) |
| `p` | integer | Processor status (8-bit) |
| `ram` | array | Memory contents as `[address, value]` pairs |

All values are decimal integers.

### Cycles Array

Each entry is `[address, value, type]` where:
- `address`: Memory address accessed (integer)
- `value`: Byte value read or written (integer)  
- `type`: `"read"` or `"write"`

The length of the cycles array is the instruction's cycle count.

### File Organization

SingleStepTests organizes files by opcode:

```
6502/v1/
├── 00.json    # BRK
├── 01.json    # ORA (zp,X)
├── ...
├── a9.json    # LDA #imm
├── ...
└── ff.json    # (illegal)
```

Each file contains 10,000 test cases for that opcode.

---

## Architecture

### Component Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                        llvm-emu-test                            │
├─────────────────────────────────────────────────────────────────┤
│  main()                                                         │
│  - Parse command line                                           │
│  - Discover test files                                          │
│  - Create thread pool                                           │
│  - Dispatch TestRunner per file                                 │
│  - Collect and report results                                   │
└─────────────────────────────────────────────────────────────────┘
        │
        │ parallel dispatch
        ▼
┌─────────────────────────────────────────────────────────────────┐
│                        TestRunner                               │
├─────────────────────────────────────────────────────────────────┤
│  - Owns emu::System, emu::Memory, target Context                │
│  - Parses JSON file                                             │
│  - For each test case:                                          │
│    1. Reset memory                                              │
│    2. Set initial CPU state                                     │
│    3. Execute one instruction (Context::step())                 │
│    4. Compare final state                                       │
│    5. Compare cycles (if enabled)                               │
│  - Returns pass/fail counts and failure details                 │
└─────────────────────────────────────────────────────────────────┘
        │
        │ uses
        ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Target emu::Context                          │
│                    (e.g., MOS::Context)                         │
├─────────────────────────────────────────────────────────────────┤
│  - CPU registers as public members                              │
│  - step() executes one instruction                              │
│  - Cycles counter                                               │
│  - getP()/setP() for flags                                      │
└─────────────────────────────────────────────────────────────────┘
```

### Context Interface Requirements

For a target to be testable with llvm-emu-test, its `emu::Context` subclass must expose:

1. **Registers as public members** (or accessors)
2. **`step()`** — execute one instruction
3. **`getCycles()`** — return cycle count
4. **Flag accessors** — `getP()`/`setP()` or equivalent

The test runner is target-specific because register layouts differ. Each target provides a `TestRunner` specialization or the tool uses a registry pattern.

### Target Registration

Targets register their test runner factory:

```cpp
// In target's MCTargetDesc
static bool RegisterTestRunner() {
  EmuTestRegistry::add("mos", [](const MCSubtargetInfo &STI) {
    return std::make_unique<MOSTestRunner>(STI);
  });
  return true;
}
static bool Registered = RegisterTestRunner();
```

The tool looks up the runner by triple prefix.

---

## Implementation

### File Structure

```
llvm/tools/llvm-emu-test/
├── CMakeLists.txt
├── llvm-emu-test.cpp          # Entry point, CLI, orchestration
├── TestRunner.h               # Abstract test runner interface
├── TestRunner.cpp             # Common utilities
├── JSONTestParser.h           # SingleStepTests JSON parser
├── JSONTestParser.cpp
├── EmuTestRegistry.h          # Target runner registry
├── EmuTestRegistry.cpp
└── Targets/
    ├── MOS/
    │   ├── MOSTestRunner.h
    │   └── MOSTestRunner.cpp
    └── SPC700/
        ├── SPC700TestRunner.h
        └── SPC700TestRunner.cpp
```

### CMakeLists.txt

```cmake
set(LLVM_LINK_COMPONENTS
  AllTargetsDescs
  AllTargetsDisassemblers
  AllTargetsInfos
  Emulator
  MC
  Support
)

add_llvm_tool(llvm-emu-test
  llvm-emu-test.cpp
  TestRunner.cpp
  JSONTestParser.cpp
  EmuTestRegistry.cpp
  Targets/MOS/MOSTestRunner.cpp
  # Add other targets as needed
)
```

### Core Classes

#### JSONTestParser

```cpp
// JSONTestParser.h
#ifndef LLVM_TOOLS_LLVM_EMU_TEST_JSONTESTPARSER_H
#define LLVM_TOOLS_LLVM_EMU_TEST_JSONTESTPARSER_H

#include "llvm/ADT/StringRef.h"
#include "llvm/Support/JSON.h"
#include <cstdint>
#include <string>
#include <vector>

namespace llvm {
namespace emutest {

struct MemoryWrite {
  uint64_t Address;
  uint8_t Value;
};

struct BusCycle {
  uint64_t Address;
  uint8_t Value;
  bool IsWrite;
};

struct CPUState {
  uint64_t PC;
  std::vector<std::pair<std::string, uint64_t>> Registers;
  std::vector<MemoryWrite> RAM;
};

struct TestCase {
  std::string Name;
  CPUState Initial;
  CPUState Final;
  std::vector<BusCycle> Cycles;
};

/// Parse a SingleStepTests JSON file.
/// Returns empty vector on parse error.
std::vector<TestCase> parseTestFile(StringRef Path, std::string &Error);

/// Parse from already-loaded JSON.
std::vector<TestCase> parseTestJSON(const json::Array &Tests, std::string &Error);

} // namespace emutest
} // namespace llvm

#endif
```

#### TestRunner

```cpp
// TestRunner.h
#ifndef LLVM_TOOLS_LLVM_EMU_TEST_TESTRUNNER_H
#define LLVM_TOOLS_LLVM_EMU_TEST_TESTRUNNER_H

#include "JSONTestParser.h"
#include "llvm/ADT/StringRef.h"
#include <string>
#include <vector>

namespace llvm {
namespace emutest {

struct TestFailure {
  std::string TestName;
  unsigned Index;
  std::string Field;
  uint64_t Expected;
  uint64_t Actual;
};

struct TestResult {
  std::string File;
  uint64_t Passed = 0;
  uint64_t Failed = 0;
  uint64_t Skipped = 0;
  std::vector<TestFailure> Failures;
};

struct TestOptions {
  bool ValidateCycles = true;
  bool ValidateBus = true;
  bool StopOnFail = false;
  unsigned MaxFailures = 0;
  bool Verbose = false;
  bool DumpFailures = false;
};

/// Abstract base class for target-specific test runners.
class TestRunner {
public:
  virtual ~TestRunner() = default;
  
  /// Run all tests in a parsed test file.
  virtual TestResult runTests(ArrayRef<TestCase> Tests,
                              const TestOptions &Opts) = 0;
  
  /// Get the list of register names this target uses.
  virtual ArrayRef<StringRef> getRegisterNames() const = 0;
};

} // namespace emutest
} // namespace llvm

#endif
```

#### MOSTestRunner

```cpp
// Targets/MOS/MOSTestRunner.h
#ifndef LLVM_TOOLS_LLVM_EMU_TEST_TARGETS_MOS_MOSTESTRUNNER_H
#define LLVM_TOOLS_LLVM_EMU_TEST_TARGETS_MOS_MOSTESTRUNNER_H

#include "TestRunner.h"
#include "llvm/Emulator/Memory.h"
#include "llvm/Emulator/System.h"
#include "llvm/MC/MCSubtargetInfo.h"
#include <memory>

namespace llvm {
namespace MOS {
class Context;
}

namespace emutest {

class MOSTestRunner : public TestRunner {
  std::unique_ptr<emu::System> Sys;
  std::unique_ptr<emu::Memory> RAM;
  std::unique_ptr<MOS::Context> Ctx;
  
public:
  explicit MOSTestRunner(const MCSubtargetInfo &STI);
  ~MOSTestRunner() override;
  
  TestResult runTests(ArrayRef<TestCase> Tests,
                      const TestOptions &Opts) override;
  
  ArrayRef<StringRef> getRegisterNames() const override;
  
private:
  void setInitialState(const CPUState &State);
  bool compareState(const CPUState &Expected, TestFailure &Fail);
  bool compareCycles(ArrayRef<BusCycle> Expected, TestFailure &Fail);
  void clearMemory();
};

} // namespace emutest
} // namespace llvm

#endif
```

```cpp
// Targets/MOS/MOSTestRunner.cpp
#include "MOSTestRunner.h"
#include "llvm/Target/MOS/MCTargetDesc/MOSContext.h"

using namespace llvm;
using namespace llvm::emutest;

static const StringRef MOSRegisterNames[] = {"pc", "s", "a", "x", "y", "p"};

MOSTestRunner::MOSTestRunner(const MCSubtargetInfo &STI) {
  // Create 64K RAM
  RAM = std::make_unique<emu::Memory>(65536);
  
  // Create system and map RAM
  Sys = std::make_unique<emu::System>();
  Sys->addDevice(0x0000, 0xFFFF, RAM.get());
  
  // Create CPU context
  // Note: Need to get disassembler and instr info from target
  Ctx = createMOSContext(STI, *Sys);
}

MOSTestRunner::~MOSTestRunner() = default;

ArrayRef<StringRef> MOSTestRunner::getRegisterNames() const {
  return MOSRegisterNames;
}

void MOSTestRunner::setInitialState(const CPUState &State) {
  Ctx->PC = State.PC;
  Ctx->Cycles = 0;
  Ctx->Halted = false;
  
  for (const auto &[Name, Value] : State.Registers) {
    if (Name == "a") Ctx->A = Value;
    else if (Name == "x") Ctx->X = Value;
    else if (Name == "y") Ctx->Y = Value;
    else if (Name == "s") Ctx->S = Value;
    else if (Name == "p") Ctx->setP(Value);
  }
  
  for (const auto &MW : State.RAM) {
    RAM->write(MW.Address, MW.Value);
  }
}

bool MOSTestRunner::compareState(const CPUState &Expected, TestFailure &Fail) {
  if (Ctx->PC != Expected.PC) {
    Fail.Field = "pc";
    Fail.Expected = Expected.PC;
    Fail.Actual = Ctx->PC;
    return false;
  }
  
  for (const auto &[Name, Value] : Expected.Registers) {
    uint64_t Actual;
    if (Name == "a") Actual = Ctx->A;
    else if (Name == "x") Actual = Ctx->X;
    else if (Name == "y") Actual = Ctx->Y;
    else if (Name == "s") Actual = Ctx->S;
    else if (Name == "p") Actual = Ctx->getP();
    else continue;
    
    if (Actual != Value) {
      Fail.Field = Name;
      Fail.Expected = Value;
      Fail.Actual = Actual;
      return false;
    }
  }
  
  for (const auto &MW : Expected.RAM) {
    uint8_t Actual = RAM->read(MW.Address);
    if (Actual != MW.Value) {
      Fail.Field = "ram[" + std::to_string(MW.Address) + "]";
      Fail.Expected = MW.Value;
      Fail.Actual = Actual;
      return false;
    }
  }
  
  return true;
}

void MOSTestRunner::clearMemory() {
  // Fast clear - assumes Memory has a clear() or we write zeros
  for (unsigned i = 0; i < 65536; ++i)
    RAM->write(i, 0);
}

TestResult MOSTestRunner::runTests(ArrayRef<TestCase> Tests,
                                   const TestOptions &Opts) {
  TestResult Result;
  
  for (unsigned i = 0; i < Tests.size(); ++i) {
    const auto &Test = Tests[i];
    
    clearMemory();
    setInitialState(Test.Initial);
    
    Ctx->step();
    
    TestFailure Fail;
    Fail.TestName = Test.Name;
    Fail.Index = i;
    
    if (!compareState(Test.Final, Fail)) {
      Result.Failed++;
      if (Opts.DumpFailures || Result.Failures.size() < 10)
        Result.Failures.push_back(Fail);
      
      if (Opts.StopOnFail)
        break;
      if (Opts.MaxFailures && Result.Failed >= Opts.MaxFailures)
        break;
    } else if (Opts.ValidateCycles) {
      if (Ctx->Cycles != Test.Cycles.size()) {
        Fail.Field = "cycles";
        Fail.Expected = Test.Cycles.size();
        Fail.Actual = Ctx->Cycles;
        Result.Failed++;
        if (Opts.DumpFailures || Result.Failures.size() < 10)
          Result.Failures.push_back(Fail);
        
        if (Opts.StopOnFail)
          break;
        if (Opts.MaxFailures && Result.Failed >= Opts.MaxFailures)
          break;
      } else {
        Result.Passed++;
      }
    } else {
      Result.Passed++;
    }
    
    if (Opts.Verbose && (i % 1000 == 0))
      errs() << "  " << i << "/" << Tests.size() << "\r";
  }
  
  return Result;
}
```

#### Main Entry Point

```cpp
// llvm-emu-test.cpp
#include "EmuTestRegistry.h"
#include "JSONTestParser.h"
#include "TestRunner.h"
#include "llvm/MC/TargetRegistry.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/InitLLVM.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/ThreadPool.h"
#include "llvm/Support/WithColor.h"
#include <atomic>
#include <mutex>

using namespace llvm;
using namespace llvm::emutest;

static cl::list<std::string> TestPaths(cl::Positional, cl::OneOrMore,
                                        cl::desc("<test files or directories>"));

static cl::opt<std::string> TripleName("triple", cl::Required,
                                        cl::desc("Target triple"));

static cl::opt<std::string> MAttr("mattr", cl::init(""),
                                   cl::desc("Target features"));

static cl::opt<unsigned> Jobs("j", cl::init(0),
                               cl::desc("Parallel jobs (0 = auto)"));

static cl::opt<bool> Verbose("v", cl::desc("Verbose output"));

static cl::opt<bool> StopOnFail("stop-on-fail",
                                 cl::desc("Stop after first failure"));

static cl::opt<bool> NoCycles("no-cycles",
                               cl::desc("Skip cycle count validation"));

static cl::opt<bool> NoBus("no-bus",
                            cl::desc("Skip bus activity validation"));

static cl::opt<unsigned> MaxFailures("max-failures", cl::init(0),
                                      cl::desc("Stop after N failures"));

static cl::opt<std::string> Exclude("exclude", cl::init(""),
                                     cl::desc("Opcodes to skip (comma-separated)"));

static cl::opt<bool> DumpFailures("dump-failures",
                                   cl::desc("Print full state on failure"));

static cl::opt<std::string> JSONOutput("json-output", cl::init(""),
                                        cl::desc("Write results to JSON file"));

/// Collect all .json files from paths (files or directories).
static std::vector<std::string> collectTestFiles(ArrayRef<std::string> Paths) {
  std::vector<std::string> Files;
  
  for (const auto &Path : Paths) {
    if (sys::fs::is_directory(Path)) {
      std::error_code EC;
      for (sys::fs::directory_iterator I(Path, EC), E; I != E && !EC; I.increment(EC)) {
        if (sys::path::extension(I->path()) == ".json")
          Files.push_back(I->path());
      }
    } else {
      Files.push_back(Path);
    }
  }
  
  llvm::sort(Files);
  return Files;
}

/// Check if an opcode (from filename like "a9.json") should be excluded.
static bool isExcluded(StringRef Filename, const std::set<std::string> &Excluded) {
  StringRef Stem = sys::path::stem(Filename);
  return Excluded.count(Stem.str()) > 0;
}

/// Parse comma-separated exclude list.
static std::set<std::string> parseExcludeList(StringRef List) {
  std::set<std::string> Result;
  SmallVector<StringRef, 16> Parts;
  List.split(Parts, ',', -1, false);
  for (auto P : Parts)
    Result.insert(P.trim().lower());
  return Result;
}

int main(int argc, char **argv) {
  InitLLVM X(argc, argv);
  
  cl::ParseCommandLineOptions(argc, argv, "LLVM Emulator Test Runner\n");
  
  // Initialize targets
  InitializeAllTargetInfos();
  InitializeAllTargetMCs();
  InitializeAllDisassemblers();
  
  // Look up target
  std::string Error;
  const Target *TheTarget = TargetRegistry::lookupTarget(TripleName, Error);
  if (!TheTarget) {
    WithColor::error() << Error << "\n";
    return 2;
  }
  
  // Create subtarget info
  std::unique_ptr<MCSubtargetInfo> STI(
      TheTarget->createMCSubtargetInfo(TripleName, "", MAttr));
  if (!STI) {
    WithColor::error() << "unable to create subtarget info\n";
    return 2;
  }
  
  // Get test runner for target
  auto RunnerFactory = EmuTestRegistry::lookup(TripleName);
  if (!RunnerFactory) {
    WithColor::error() << "no test runner registered for " << TripleName << "\n";
    return 2;
  }
  
  // Collect test files
  std::vector<std::string> Files = collectTestFiles(TestPaths);
  if (Files.empty()) {
    WithColor::error() << "no test files found\n";
    return 2;
  }
  
  auto Excluded = parseExcludeList(Exclude);
  
  // Set up options
  TestOptions Opts;
  Opts.ValidateCycles = !NoCycles;
  Opts.ValidateBus = !NoBus;
  Opts.StopOnFail = StopOnFail;
  Opts.MaxFailures = MaxFailures;
  Opts.Verbose = Verbose;
  Opts.DumpFailures = DumpFailures;
  
  // Results collection
  std::atomic<uint64_t> TotalPassed{0};
  std::atomic<uint64_t> TotalFailed{0};
  std::atomic<uint64_t> TotalSkipped{0};
  std::atomic<bool> ShouldStop{false};
  std::mutex FailureMutex;
  std::vector<TestFailure> AllFailures;
  
  // Progress
  std::atomic<unsigned> FilesCompleted{0};
  unsigned TotalFiles = Files.size();
  
  // Thread pool
  unsigned NumThreads = Jobs ? Jobs : std::thread::hardware_concurrency();
  ThreadPool Pool(hardware_concurrency(NumThreads));
  
  for (const auto &File : Files) {
    if (isExcluded(sys::path::filename(File), Excluded)) {
      TotalSkipped += 10000; // Approximate
      FilesCompleted++;
      continue;
    }
    
    Pool.async([&, File]() {
      if (ShouldStop)
        return;
      
      // Each thread gets its own runner instance
      auto Runner = RunnerFactory(*STI);
      
      std::string ParseError;
      auto Tests = parseTestFile(File, ParseError);
      if (Tests.empty()) {
        WithColor::warning() << File << ": " << ParseError << "\n";
        return;
      }
      
      auto Result = Runner->runTests(Tests, Opts);
      Result.File = File;
      
      TotalPassed += Result.Passed;
      TotalFailed += Result.Failed;
      TotalSkipped += Result.Skipped;
      
      if (!Result.Failures.empty()) {
        std::lock_guard<std::mutex> Lock(FailureMutex);
        for (auto &F : Result.Failures) {
          if (AllFailures.size() < 100) // Cap stored failures
            AllFailures.push_back(std::move(F));
        }
        
        if (StopOnFail)
          ShouldStop = true;
      }
      
      unsigned Done = ++FilesCompleted;
      if (!Verbose)
        errs() << "\r[" << Done << "/" << TotalFiles << "] "
               << sys::path::filename(File) << "        ";
    });
  }
  
  Pool.wait();
  errs() << "\n\n";
  
  // Summary
  outs() << "Passed:  " << TotalPassed << "\n";
  outs() << "Failed:  " << TotalFailed << "\n";
  outs() << "Skipped: " << TotalSkipped << "\n";
  outs() << "\n";
  
  // Failure details
  if (!AllFailures.empty()) {
    outs() << "Failures:\n";
    for (const auto &F : AllFailures) {
      outs() << "  " << F.TestName << "[" << F.Index << "]: "
             << F.Field << " expected " << format_hex(F.Expected, 0)
             << ", got " << format_hex(F.Actual, 0) << "\n";
    }
  }
  
  // JSON output
  if (!JSONOutput.empty()) {
    std::error_code EC;
    raw_fd_ostream Out(JSONOutput, EC);
    if (!EC) {
      json::Object Root;
      Root["passed"] = TotalPassed.load();
      Root["failed"] = TotalFailed.load();
      Root["skipped"] = TotalSkipped.load();
      
      json::Array FailuresArr;
      for (const auto &F : AllFailures) {
        json::Object Obj;
        Obj["test"] = F.TestName;
        Obj["index"] = F.Index;
        Obj["field"] = F.Field;
        Obj["expected"] = F.Expected;
        Obj["actual"] = F.Actual;
        FailuresArr.push_back(std::move(Obj));
      }
      Root["failures"] = std::move(FailuresArr);
      
      Out << json::Value(std::move(Root)) << "\n";
    }
  }
  
  return TotalFailed > 0 ? 1 : 0;
}
```

---

## Usage Examples

### Basic validation

```bash
# Test NMOS 6502
llvm-emu-test --triple=mos ~/SingleStepTests/65x02/6502/v1/

# Test WDC 65C02
llvm-emu-test --triple=mos --mattr=+wdc65c02 ~/SingleStepTests/65x02/wdc65c02/v1/
```

### Response files for CI

Create `tests/6502.rsp`:
```
--triple=mos
-j16
tests/6502/v1/
```

Create `tests/wdc65c02.rsp`:
```
--triple=mos
--mattr=+wdc65c02
-j16
tests/wdc65c02/v1/
```

CI script:
```bash
#!/bin/bash
set -e
for rsp in tests/*.rsp; do
  echo "=== Running $rsp ==="
  llvm-emu-test @$rsp
done
```

### Excluding unstable opcodes

```bash
# Skip the "magic constant" opcodes
llvm-emu-test --triple=mos --exclude=8b,ab,9b,9c,9e,9f,93 tests/6502/v1/
```

### Debugging failures

```bash
# Stop on first failure with full dump
llvm-emu-test --triple=mos --stop-on-fail --dump-failures -v tests/6502/v1/00.json
```

### JSON output for automation

```bash
llvm-emu-test --triple=mos --json-output=results.json tests/6502/v1/
```

---

## Future Extensions

### Bus Activity Validation

The current design validates cycle counts. Full bus validation would compare each entry in the `cycles` array against actual bus transactions. This requires:

1. A trace mechanism in `emu::Context` that records `[addr, value, read/write]` per cycle
2. Comparison logic in the test runner

### Additional Test Formats

The architecture supports multiple formats via different parsers. Potential additions:

- MAME test format
- Custom JSON schemas for other test suites
- Binary formats for faster loading

### Interactive Mode

```bash
llvm-emu-test --interactive --triple=mos
> load tests/6502/v1/a9.json
Loaded 10000 tests
> run 42
Test 42: a9 ee
Initial: PC=1234 A=00 X=00 Y=00 S=FD P=24
Final:   PC=1236 A=EE X=00 Y=00 S=FD P=A4
PASSED
> 
```

### Integration with lit

```python
# test/Emulator/MOS/6502.test
# RUN: llvm-emu-test --triple=mos %S/Inputs/6502/v1/ | FileCheck %s
# CHECK: Failed: 0
```

---

## References

- [SingleStepTests/65x02](https://github.com/SingleStepTests/65x02) — Test vectors
- [ZBC Specification](https://www.zeroboardcomputer.com) — Platform spec
- [llvm-exegesis](https://llvm.org/docs/CommandGuide/llvm-exegesis.html) — Similar tool for hardware measurement