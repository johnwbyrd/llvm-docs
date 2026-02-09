# jbyrd's development environment for LLVM with a focus on LLDB support.
# This is a CMake cache file for a development environment for LLVM.
# It is used to configure the LLVM build system for a development environment.
set(LLVM_TARGETS_TO_BUILD "all" CACHE STRING "")
set(LLVM_EXPERIMENTAL_TARGETS_TO_BUILD "MOS" CACHE STRING "")
set(LLVM_ENABLE_PROJECTS clang;clang-tools-extra;lld;lldb CACHE STRING "")
set(LLVM_ENABLE_RUNTIMES compiler-rt CACHE STRING "")
set(CMAKE_BUILD_TYPE Debug CACHE STRING "CMake build type")
set(CMAKE_INSTALL_PREFIX "/home/jbyrd/git/llvm-mos/build/install" CACHE STRING "Installation prefix")

set(CMAKE_C_COMPILER_LAUNCHER "sccache" CACHE STRING "")
set(CMAKE_CXX_COMPILER_LAUNCHER "sccache" CACHE STRING "")
set(LLVM_PARALLEL_LINK_JOBS 4 CACHE STRING "")
# Prefer LLVM's lld linker for faster linking
set(CMAKE_C_COMPILER "clang" CACHE STRING "")
set(CMAKE_CXX_COMPILER "clang" CACHE STRING "")
set(CMAKE_LINKER "ld.lld" CACHE STRING "")
set(CMAKE_C_LINKER "ld.lld" CACHE STRING "")
set(CMAKE_CXX_LINKER "ld.lld" CACHE STRING "")
# Ensure Clang uses lld for linking
set(CMAKE_EXE_LINKER_FLAGS "-lstdc++ -fuse-ld=lld" CACHE STRING "")
set(CMAKE_SHARED_LINKER_FLAGS "-lstdc++ -fuse-ld=lld" CACHE STRING "")
set(CMAKE_MODULE_LINKER_FLAGS "-lstdc++ -fuse-ld=lld" CACHE STRING "")
# Enable AddressSanitizer and UndefinedBehaviorSanitizer for bounds checking
set(LLVM_USE_SANITIZER "Address;Undefined" CACHE STRING "")

# Additional sanitizer flags not included in default UBSan group
# -fPIC -ftls-model=global-dynamic: Required for sanitizers + shared library plugins (.so)
# The default "initial-exec" TLS model causes R_X86_64_TPOFF32 relocation errors
# -fPIC is required for -ftls-model=global-dynamic to take effect
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -fPIC -fsanitize-address-use-after-scope -fsanitize=local-bounds,nullability -fno-omit-frame-pointer -ftls-model=global-dynamic" CACHE STRING "" FORCE)
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fPIC -fsanitize-address-use-after-scope -fsanitize=local-bounds,nullability -fno-omit-frame-pointer -ftls-model=global-dynamic" CACHE STRING "" FORCE)

# LLVM-specific debug/checking options
set(LLVM_ENABLE_ASSERTIONS ON CACHE BOOL "Enable assertions")
# LLVM_ENABLE_EXPENSIVE_CHECKS causes TLS issues with shared libs, disabled for now
# set(LLVM_ENABLE_EXPENSIVE_CHECKS ON CACHE BOOL "Enable additional internal consistency checks")
set(LLVM_ENABLE_ABI_BREAKING_CHECKS ON CACHE BOOL "Enable ABI breaking checks (usually implied by assertions)")
# LLVM_REVERSE_ITERATION can also cause issues, disabled for now
# set(LLVM_REVERSE_ITERATION ON CACHE BOOL "Catch non-deterministic iteration order bugs")
