#!/bin/bash
#
# Build all projects for MOS DWARF debugging work:
#   1. llvm-mos - compiler/toolchain
#   2. picolibc - C library
#   3. dwarf-torture - test cases
#
# Usage: ./build-all.sh
#
set -e  # Exit on first error

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LLVM_MOS_DIR="$(dirname "$SCRIPT_DIR")"
PICOLIBC_DIR="$HOME/git/picolibc"
DWARF_TORTURE_DIR="$HOME/git/dwarf-torture"

# Ensure llvm-mos tools are in PATH for picolibc and dwarf-torture builds
export PATH="$LLVM_MOS_DIR/build/install/bin:/usr/bin:/bin:$PATH"

echo "========================================"
echo "Step 1/3: Building and installing llvm-mos"
echo "========================================"
mkdir -p ${LLVM_MOS_DIR}/build
/usr/bin/cmake --build "$LLVM_MOS_DIR/build" --config Debug --target install

echo ""
echo "========================================"
echo "Step 2/3: Rebuilding and installing picolibc"
echo "========================================"
cd "$PICOLIBC_DIR"
rm -rf build-mos
mkdir build-mos
cd build-mos
../scripts/do-mos-configure
# Use ninja -k 0 to continue despite test binary link failures (64KB limit).
# Some test binaries are too large for 6502's address space - this is expected.
# The libraries (libc.a, libm.a, libsemihost.a) build successfully.
ninja -k 0 || true
DESTDIR=install meson install --no-rebuild

echo ""
echo "========================================"
echo "Step 3/3: Building dwarf-torture"
echo "========================================"
cd "$DWARF_TORTURE_DIR"
rm -rf build
mkdir build
cd build
cmake ..
make

echo ""
echo "========================================"
echo "Build complete!"
echo "========================================"
echo "Test binaries at: $DWARF_TORTURE_DIR/build/bin/"
echo ""
echo "To verify DWARF output:"
echo "  llvm-dwarfdump --debug-frame $DWARF_TORTURE_DIR/build/bin/float_qsort_O0"
