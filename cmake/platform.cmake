#===============================================================================
# Copyright 2016-2025 Intel Corporation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#===============================================================================

# Manage platform-specific quirks
#===============================================================================

if(platform_cmake_included)
    return()
endif()
set(platform_cmake_included true)

include("cmake/utils.cmake")

if (DNNL_LIBRARY_TYPE STREQUAL "SHARED")
    add_definitions_with_host_compiler(-DDNNL_DLL)
endif()

# Specify the target architecture
add_definitions_with_host_compiler(-DDNNL_${DNNL_TARGET_ARCH}=1)

# UNIT8_MAX-like macros are a part of the C99 standard and not a part of the
# C++ standard (see C99 standard 7.18.2 and 7.18.4)
add_definitions_with_host_compiler(-D__STDC_LIMIT_MACROS -D__STDC_CONSTANT_MACROS)

set(CMAKE_CCXX_FLAGS)
set(CMAKE_CCXX_NOWARN_FLAGS)
set(CMAKE_CCXX_NOEXCEPT_FLAGS)
set(DEF_ARCH_OPT_FLAGS)

# Compatibility with DNNL
if($ENV{ONEDNN_WERROR})
    set(DNNL_WERROR $ENV{ONEDNN_WERROR})
endif()

if($ENV{DNNL_WERROR})
    set(DNNL_WERROR $ENV{DNNL_WERROR})
endif()

# The flags that can be used for the main and host compilers should be moved to
# the macros to avoid code duplication and ensure consistency.
macro(platform_unix_and_mingw_common_ccxx_flags var)
    append(${var} "-Wall -Wno-unknown-pragmas")
    # TODO: remove Aarch64 limitation when ACL hits are resolved.
    if(NOT DNNL_TARGET_ARCH STREQUAL "AARCH64")
        append(${var} "-Wundef")
    endif()
    append_if(DNNL_WERROR ${var} "-Werror")
    append(${var} "-fvisibility=internal")
endmacro()

macro(platform_unix_and_mingw_common_cxx_flags var)
    append(${var} "-fvisibility-inlines-hidden")
endmacro()

macro(platform_unix_and_mingw_noexcept_ccxx_flags var)
    append(${var} "-fno-exceptions")
endmacro()

macro(platform_gnu_x64_arch_ccxx_flags var)
    set(${var} "-msse4.1")
endmacro()

macro(platform_clang_x64_arch_ccxx_flags var)
    set(${var} "-msse4.1")
endmacro()

macro(platform_gnu_nowarn_ccxx_flags var gnu_version)
    # suppress warning on assumptions made regarding overflow (#146)
    append(${var} "-Wno-strict-overflow")
    # suppress false positive warnings about uninitialized variables
    append(${var} "-Wno-maybe-uninitialized")
    # suppress false positive warnings with 9.x+: GCC Bugzilla – Bug 96963
    # assume 0.0 is unknown version - always suppress the warning
    if(${gnu_version} VERSION_EQUAL 0.0 OR
        ${gnu_version} VERSION_GREATER 9.0)
        append(${var} "-Wno-stringop-overflow")
        append(${var} "-Wno-array-bounds")
    endif()
endmacro()

macro(platform_clang_nowarn_ccxx_flags var)
    # Clang cannot vectorize some loops with #pragma omp simd and gets
    # very upset. Tell it that it's okay and that we love it
    # unconditionally.
    append(${var} "-Wno-pass-failed")
endmacro()

if(DNNL_WITH_SYCL)
    # Clang cannot vectorize some loops with #pragma omp simd and gets
    # very upset. Tell it that it's okay and that we love it
    # unconditionally.
    append(CMAKE_CCXX_NOWARN_FLAGS "-Wno-pass-failed")
    # Suppress self-comparison warning to avoid false positives in macros such
    # as JIT_IMPL_NAME_HELPER.
    append(CMAKE_CCXX_NOWARN_FLAGS "-Wno-tautological-compare")
    if(WIN32)
        # XXX: SYCL does not like __thiscall convention coming from TBB,
        # suppress warnings for now.
        append(CMAKE_CCXX_FLAGS "-Wno-ignored-attributes")
        # XXX: compiler always pulls in release C++ runtime by default, until
        # this is fixed we have to explicitly drop release C++ runtime for
        # debug build types.
        string(TOUPPER "${CMAKE_BUILD_TYPE}" UPPERCASE_CMAKE_BUILD_TYPE)
        if(UPPERCASE_CMAKE_BUILD_TYPE MATCHES "(DEBUG|RELWITHMDD)" AND NOT CMAKE_BASE_NAME MATCHES "(icx|icpx)")
            append(CMAKE_EXE_LINKER_FLAGS "-Xlinker /NODEFAULTLIB:msvcrt")
            append(CMAKE_SHARED_LINKER_FLAGS "-Xlinker /NODEFAULTLIB:msvcrt")
        endif()
    endif()
endif()

if (DNNL_TARGET_ARCH STREQUAL "RV64")
    # Check if the RVV Intrinsics can be compiled with the current toolchain and flags
    set(ARCH_SIMD_TEST_FLAGS "-march=rv64gcv")
    set(CMAKE_REQUIRED_FLAGS_SAVE ${CMAKE_REQUIRED_FLAGS})
    set(CMAKE_REQUIRED_FLAGS "${ARCH_SIMD_TEST_FLAGS}")
    include(CheckCXXSourceCompiles)
    check_cxx_source_compiles("#if !defined(__riscv) || !defined(__riscv_v)
                               #error \"RISC-V or vector extension(RVV) is not supported by the compiler\"
                               #endif

                               #if defined(__riscv_v_intrinsic) && __riscv_v_intrinsic < 12000
                               #error \"RISC-V intrinsics v0.12 or higher is required\"
                               #endif

                               #include <riscv_vector.h>
                               int main() {
                                return 0;
                               };"
                               CAN_COMPILE_RVV_INTRINSICS
    )
    
    set(CMAKE_REQUIRED_FLAGS ${CMAKE_REQUIRED_FLAGS_SAVE})
    # Set CAN_COMPILE_RVV_INTRINSICS to TRUE / FALSE instead of 1 / "" (Undefined)
    if (CAN_COMPILE_RVV_INTRINSICS)
        set(CAN_COMPILE_RVV_INTRINSICS TRUE)
        set(RV64_MARCH_FLAG "-march=rv64gcv")
    else()
        set(CAN_COMPILE_RVV_INTRINSICS FALSE)
        set(RV64_MARCH_FLAG "-march=rv64gc")
    endif()

    set(DNNL_RISCV_USE_RVV_INTRINSICS ${CAN_COMPILE_RVV_INTRINSICS})
    if (${DNNL_RISCV_USE_RVV_INTRINSICS})
        add_definitions(-DDNNL_RISCV_USE_RVV_INTRINSICS)
    endif()

    message(STATUS "Can compile RVV Intrinsics: ${CAN_COMPILE_RVV_INTRINSICS}")
    message(STATUS "DNNL_RISCV_USE_RVV_INTRINSICS: ${DNNL_RISCV_USE_RVV_INTRINSICS}")
    message(STATUS "Using RV64 march flag: ${RV64_MARCH_FLAG}")
endif()

if(MSVC)
    set(USERCONFIG_PLATFORM "x64")
    append_if(DNNL_WERROR CMAKE_CCXX_FLAGS "/WX")

    # Generating frame pointers for easier performance profiling
    if(DNNL_TARGET_ARCH STREQUAL "X64")
        if(CMAKE_CXX_COMPILER_ID MATCHES "Clang")
            append(CMAKE_CCXX_FLAGS "-fno-omit-frame-pointer -mno-omit-leaf-frame-pointer")
        else()
            append(CMAKE_CCXX_FLAGS "/Oy-")
        endif()
    endif()

    if(${CMAKE_CXX_COMPILER_ID} STREQUAL MSVC)
        append(CMAKE_CCXX_FLAGS "/MP")
        # increase number of sections in obj file
        append(CMAKE_CCXX_FLAGS "/bigobj")
        # make preprocessor standard compliant
        append(CMAKE_CCXX_FLAGS "/Zc:preprocessor")
        # Set UTF-8 as default encoding to be consistent with other compilers
        append(CMAKE_CCXX_FLAGS "/utf-8")
        # Enable __cplusplus macro to align behavior with other compilers
        append(CMAKE_CCXX_FLAGS "/Zc:__cplusplus")
        # int64_t -> int (tent)
        append(CMAKE_CCXX_NOWARN_FLAGS "/wd4244")
        # workaround: macro outputs defined token in msvs header
        append(CMAKE_CCXX_NOWARN_FLAGS "/wd5105")
    endif()
    if(CMAKE_CXX_COMPILER_ID STREQUAL "Intel")
        append(CMAKE_CCXX_FLAGS "/MP")
        # increase number of sections in obj file
        append(CMAKE_CCXX_FLAGS "/bigobj")
        set(DEF_ARCH_OPT_FLAGS "-QxSSE4.1")
        # disable: loop was not vectorized with "simd"
        append(CMAKE_CCXX_NOWARN_FLAGS "-Qdiag-disable:13379")
        # disable: loop was not vectorized with "simd"
        append(CMAKE_CCXX_NOWARN_FLAGS "-Qdiag-disable:15552")
        # disable: unknown pragma
        append(CMAKE_CCXX_NOWARN_FLAGS "-Qdiag-disable:3180")
        # disable: foo has been targeted for automatic cpu dispatch
        append(CMAKE_CCXX_NOWARN_FLAGS "-Qdiag-disable:15009")
        # disable: disabling user-directed function packaging (COMDATs)
        append(CMAKE_CCXX_NOWARN_FLAGS "-Qdiag-disable:11031")
        # disable: decorated name length exceeded, name was truncated
        append(CMAKE_CCXX_NOWARN_FLAGS "-Qdiag-disable:2586")
        # disable: disabling optimization; runtime debug checks enabled
        append(CMAKE_CXX_FLAGS_DEBUG "-Qdiag-disable:10182")
        # disable: icpc deprecation notice
        append(CMAKE_CXX_FLAGS_DEBUG "-Qdiag-disable:10441")
    endif()
    if(CMAKE_CXX_COMPILER_ID MATCHES "(Apple)?[Cc]lang")
        append(CMAKE_CCXX_NOEXCEPT_FLAGS "-fno-exceptions")
        # Clang cannot vectorize some loops with #pragma omp simd and gets
        # very upset. Tell it that it's okay and that we love it
        # unconditionally.
        append(CMAKE_CCXX_FLAGS "-Wno-pass-failed")
        # Clang doesn't like the idea of overriding optimization flags.
        # We don't want to optimize jit gemm kernels to reduce compile time
        append(CMAKE_CCXX_FLAGS "-Wno-overriding-t-option")
    endif()
    if(CMAKE_CXX_COMPILER_ID MATCHES "IntelLLVM" OR DNNL_WITH_SYCL OR
            CMAKE_BASE_NAME STREQUAL "icx" OR CMAKE_BASE_NAME STREQUAL "icpx")
        # When using Debug build mode CMake adds '-debug' without any
        # optimization-level option causing the warning.
        # We disable the warning for debug build mode.
        if(UPPERCASE_CMAKE_BUILD_TYPE STREQUAL "DEBUG")
            append(CMAKE_CCXX_FLAGS "-Wno-debug-disables-optimization")
            # The compiler may issue the corresponding remark.
            append(CMAKE_CCXX_FLAGS "-Rno-debug-disables-optimization")
        endif()

        # Disabling OMP SIMD feature on Windows ICX debug builds and suppressing this warning:
        # Using /MTd or /MDd with '#pragma omp simd' may lead to unexpected fails due
        # to the debugging version of iterators that cannot be vectorized correctly.
        if (UPPERCASE_CMAKE_BUILD_TYPE MATCHES "(DEBUG|RELWITHMDD)")
            append(CMAKE_CCXX_FLAGS "/Qopenmp-simd-")
            append(CMAKE_CCXX_FLAGS "/Wno-debug-option-simd")
        endif()

        # Default fp-model in icx and dpcpp (unlike clang) may be precise or
        # fast=1 depending on the version.
        append(CMAKE_CCXX_FLAGS "/fp:precise")
        # icx and dpcpp cannot vectorize some loops with #pragma omp simd and
        # gets very upset. Tell it that it's okay and that we love it
        # unconditionally.
        append(CMAKE_CCXX_NOWARN_FLAGS "-Wno-pass-failed")

        # icx/icpx may issue a recommendation warning on using
        # -qopenmp over -fopenmp to enable some additional optimizations.
        # Suppress the warning to avoid breaking the build until we figure out
        # whether it makes sense to enable those optimizations.
        append(CMAKE_CCXX_NOWARN_FLAGS "-Wno-recommended-option")
        # Older compiler versions may not support "-Wno-recommended-option".
        append(CMAKE_CCXX_FLAGS "-Wno-unknown-warning-option")
    endif()
elseif(UNIX OR MINGW)
    if(DNNL_WITH_SYCL OR CMAKE_BASE_NAME STREQUAL "icx" OR CMAKE_BASE_NAME STREQUAL "icpx")
        # When using Debug build mode CMake adds "-g" option without "-O0"
        # causing the warning. This probably happens because clang/gcc compilers
        # use "-O0" as the default therefore passing only "-g" is correct
        # for them, however icx/icpx use "O2" as the default, which makes the
        # CMake logic incorrect. This should be fixed in CMake.
        # We disable the warning for debug build mode.
        if(UPPERCASE_CMAKE_BUILD_TYPE STREQUAL "DEBUG")
            append(CMAKE_CCXX_FLAGS "-Wno-debug-disables-optimization")
            # The compiler may issue the corresponding remark.
            append(CMAKE_CCXX_FLAGS "-Rno-debug-disables-optimization")
            # Some compiler versions may not know "debug-disables-optimization".
            append(CMAKE_CCXX_FLAGS "-Wno-unknown-warning-option")
        endif()
        # Default fp-model in icx and dpcpp (unlike clang) may be precise or
        # fast=1 depending on the version.
        append(CMAKE_CCXX_FLAGS "-ffp-model=precise -fno-reciprocal-math")
        # icx and dpcpp cannot vectorize some loops with #pragma omp simd and
        # gets very upset. Tell it that it's okay and that we love it
        # unconditionally.
        append(CMAKE_CCXX_NOWARN_FLAGS "-Wno-pass-failed")

        # icx/icpx may issue a recommendation warning on using
        # -qopenmp over -fopenmp to enable some additional optimizations.
        # Suppress the warning to avoid breaking the build until we figure out
        # whether it makes sense to enable those optimizations.
        append(CMAKE_CCXX_NOWARN_FLAGS "-Wno-recommended-option")
        # Older compiler versions may not support "-Wno-recommended-option".
        append(CMAKE_CCXX_FLAGS "-Wno-unknown-warning-option")

        # Align with GCC -Wall
        append(CMAKE_CCXX_FLAGS "-Wsign-compare")
    endif()

    # Generating frame pointers for easier performance profiling
    if(DNNL_TARGET_ARCH STREQUAL "X64")
        append(CMAKE_CCXX_FLAGS "-fno-omit-frame-pointer -mno-omit-leaf-frame-pointer")
    endif()

    platform_unix_and_mingw_common_ccxx_flags(CMAKE_CCXX_FLAGS)
    platform_unix_and_mingw_common_cxx_flags(CMAKE_CXX_FLAGS)
    platform_unix_and_mingw_noexcept_ccxx_flags(CMAKE_CMAKE_CCXX_NOEXCEPT_FLAGS)
    # compiler specific settings
    if(CMAKE_CXX_COMPILER_ID MATCHES "(Apple)?[Cc]lang")
        if(DNNL_TARGET_ARCH STREQUAL "AARCH64")
             if (NOT CMAKE_BUILD_TYPE STREQUAL "Debug")
                 set(DEF_ARCH_OPT_FLAGS "-O3")
             endif()
             if (CMAKE_SYSTEM_PROCESSOR STREQUAL CMAKE_HOST_SYSTEM_PROCESSOR)
                 # Defaults to a generic cpu target, equivalent to setting -mtune=generic -march=armv8-a.
                 # This ensures no implementation specific tuning, or architectural features beyond
                 # armv8-a are used, for portability across AArch64 systems.
                 # The DNNL_ARCH_OPT_FLAGS build option can be used to override these defaults
                 # to optimise for a specific cpu, or revision of the Armv8 architecture.
                 append(DEF_ARCH_OPT_FLAGS "-mcpu=generic")
             endif()
        elseif(DNNL_TARGET_ARCH STREQUAL "PPC64")
             if (NOT CMAKE_BUILD_TYPE STREQUAL "Debug")
                 set(DEF_ARCH_OPT_FLAGS "-O3")
             endif()
             # For native compilation tune for the host processor
             if (CMAKE_SYSTEM_PROCESSOR STREQUAL CMAKE_HOST_SYSTEM_PROCESSOR)
                 append(DEF_ARCH_OPT_FLAGS "-mcpu=native")
             endif()
        elseif(DNNL_TARGET_ARCH STREQUAL "S390X")
             if (NOT CMAKE_BUILD_TYPE STREQUAL "Debug")
                 set(DEF_ARCH_OPT_FLAGS "-O3")
             endif()
             # For native compilation tune for the host processor
             if (CMAKE_SYSTEM_PROCESSOR STREQUAL CMAKE_HOST_SYSTEM_PROCESSOR)
                 append(DEF_ARCH_OPT_FLAGS "-march=native")
             endif()
        elseif(DNNL_TARGET_ARCH STREQUAL "RV64")
             append(DEF_ARCH_OPT_FLAGS "${RV64_MARCH_FLAG}")
        elseif(DNNL_TARGET_ARCH STREQUAL "X64")
             platform_clang_x64_arch_ccxx_flags(DEF_ARCH_OPT_FLAGS)
        endif()
        platform_clang_nowarn_ccxx_flags(CMAKE_CCXX_NOWARN_FLAGS)

        if(DNNL_USE_CLANG_SANITIZER MATCHES "Memory(WithOrigin)?")
            if(NOT DNNL_CPU_THREADING_RUNTIME STREQUAL "SEQ")
                message(WARNING "Clang OpenMP is not compatible with MSan! "
                    "Expect a lot of false positives!")
            endif()
            append(CMAKE_CCXX_SANITIZER_FLAGS "-fsanitize=memory")
            if(DNNL_USE_CLANG_SANITIZER STREQUAL "MemoryWithOrigin")
                append(CMAKE_CCXX_SANITIZER_FLAGS
                    "-fsanitize-memory-track-origins=2")
                # Already enabled for x64
                if(NOT DNNL_TARGET_ARCH STREQUAL "X64")
                    append(CMAKE_CCXX_SANITIZER_FLAGS
                        "-fno-omit-frame-pointer")
                endif()
            endif()
            set(DNNL_ENABLED_CLANG_SANITIZER "${DNNL_USE_CLANG_SANITIZER}")
        elseif(DNNL_USE_CLANG_SANITIZER STREQUAL "Undefined")
            append(CMAKE_CCXX_SANITIZER_FLAGS "-fsanitize=undefined")
            append(CMAKE_CCXX_SANITIZER_FLAGS
                "-fno-sanitize=function,vptr")  # work around linking problems
            set(DNNL_ENABLED_CLANG_SANITIZER "${DNNL_USE_CLANG_SANITIZER}")
        elseif(DNNL_USE_CLANG_SANITIZER STREQUAL "Address")
            append(CMAKE_CCXX_SANITIZER_FLAGS "-fsanitize=address")
            set(DNNL_ENABLED_CLANG_SANITIZER "${DNNL_USE_CLANG_SANITIZER}")
        elseif(DNNL_USE_CLANG_SANITIZER STREQUAL "Thread")
            append(CMAKE_CCXX_SANITIZER_FLAGS "-fsanitize=thread")
            set(DNNL_ENABLED_CLANG_SANITIZER "${DNNL_USE_CLANG_SANITIZER}")
        elseif(DNNL_USE_CLANG_SANITIZER STREQUAL "Leak")
            append(CMAKE_CCXX_SANITIZER_FLAGS "-fsanitize=leak")
            set(DNNL_ENABLED_CLANG_SANITIZER "${DNNL_USE_CLANG_SANITIZER}")
        elseif(NOT DNNL_USE_CLANG_SANITIZER STREQUAL "")
            message(FATAL_ERROR
                "Unsupported Clang sanitizer '${DNNL_USE_CLANG_SANITIZER}'")
        endif()
        if(DNNL_ENABLED_CLANG_SANITIZER)
            message(STATUS
                "Using Clang ${DNNL_ENABLED_CLANG_SANITIZER} "
                "sanitizer (experimental!)")
            append(CMAKE_CCXX_SANITIZER_FLAGS "-DDNNL_ENABLED_CLANG_SANITIZER")
            append(CMAKE_CCXX_SANITIZER_FLAGS "-g")
            # Already enabled for x64
            if(NOT DNNL_TARGET_ARCH STREQUAL "X64")
                append(CMAKE_CCXX_SANITIZER_FLAGS "-fno-omit-frame-pointer")
            endif()

            # Blacklist to ignore false-positive cases. Each case may be
            # assigned to a specific sanitizer. See online doc for help.
            append(CMAKE_CCXX_SANITIZER_FLAGS
                   "-fsanitize-blacklist=${PROJECT_SOURCE_DIR}/.clang-ignorelist")
        endif()

        if(DNNL_USE_CLANG_TIDY MATCHES "(CHECK|FIX)")
            find_program(CLANG_TIDY NAMES clang-tidy)
            if(NOT CLANG_TIDY)
                message(FATAL_ERROR "Clang-tidy not found")
            else()
                if(DNNL_USE_CLANG_TIDY STREQUAL "CHECK")
                    set(CMAKE_CXX_CLANG_TIDY ${CLANG_TIDY})
                    message(STATUS "Using clang-tidy to run checks for source and headers")
                elseif(DNNL_USE_CLANG_TIDY STREQUAL "FIX")
                    set(CMAKE_CXX_CLANG_TIDY ${CLANG_TIDY}
                        -fix)
                    message(STATUS "Using clang-tidy to run checks and fix found issues")
                endif()
            endif()
        endif()

    elseif("${CMAKE_CXX_COMPILER_ID}" STREQUAL "GNU")
        # XXX: Suppress a warning that pops up when using a function pointer
        # to an OpenCL function as a template argument (GCC Bugzilla – Bug 71463).
        if (DNNL_GPU_RUNTIME STREQUAL "OCL")
            append(CMAKE_CCXX_FLAGS "-Wno-ignored-attributes")
        endif()

        if(DNNL_TARGET_ARCH STREQUAL "AARCH64")
            if (NOT CMAKE_BUILD_TYPE STREQUAL "Debug")
                set(DEF_ARCH_OPT_FLAGS "-O3")
            endif()
            if (CMAKE_SYSTEM_PROCESSOR STREQUAL CMAKE_HOST_SYSTEM_PROCESSOR)
                 # Defaults to a generic cpu target, equivalent to setting -mtune=generic -march=armv8-a.
                 # This ensures no implementation specific tuning, or architectural features beyond
                 # armv8-a are used, for portability across AArch64 systems.
                 # The DNNL_ARCH_OPT_FLAGS build option can be used to override these defaults
                 # to optimise for a specific cpu, or revision of the Armv8 architecture.
                 append(DEF_ARCH_OPT_FLAGS "-mcpu=generic")
            endif()
        elseif(DNNL_TARGET_ARCH STREQUAL "PPC64")
            if (NOT CMAKE_BUILD_TYPE STREQUAL "Debug")
                set(DEF_ARCH_OPT_FLAGS "-O3")
            endif()
            # In GCC, -ftree-vectorize is turned on under -O3 since 2007.
            # For native compilation tune for the host processor
            if (CMAKE_SYSTEM_PROCESSOR STREQUAL CMAKE_HOST_SYSTEM_PROCESSOR)
                append(DEF_ARCH_OPT_FLAGS "-mcpu=native")
            endif()
        elseif(DNNL_TARGET_ARCH STREQUAL "S390X")
            if (NOT CMAKE_BUILD_TYPE STREQUAL "Debug")
                set(DEF_ARCH_OPT_FLAGS "-O3")
            endif()
            # In GCC, -ftree-vectorize is turned on under -O3 since 2007.
            # For native compilation tune for the host processor
            if (CMAKE_SYSTEM_PROCESSOR STREQUAL CMAKE_HOST_SYSTEM_PROCESSOR)
                append(DEF_ARCH_OPT_FLAGS "-march=native")
            endif()
        elseif(DNNL_TARGET_ARCH STREQUAL "RV64")
            append(DEF_ARCH_OPT_FLAGS "${RV64_MARCH_FLAG}")
        elseif(DNNL_TARGET_ARCH STREQUAL "X64")
            platform_gnu_x64_arch_ccxx_flags(DEF_ARCH_OPT_FLAGS)
        endif()
        platform_gnu_nowarn_ccxx_flags(CMAKE_CCXX_NOWARN_FLAGS ${CMAKE_CXX_COMPILER_VERSION})
    elseif(CMAKE_CXX_COMPILER_ID STREQUAL "Intel")
        set(DEF_ARCH_OPT_FLAGS "-xSSE4.1")
        # workaround for Intel Compiler that produces error caused
        # by pragma omp simd collapse(..)
        append(CMAKE_CCXX_NOWARN_FLAGS "-diag-disable:13379")
        append(CMAKE_CCXX_NOWARN_FLAGS "-diag-disable:15552")
        # disable `was not vectorized: vectorization seems inefficient` remark
        append(CMAKE_CCXX_NOWARN_FLAGS "-diag-disable:15335")
        # disable: foo has been targeted for automatic cpu dispatch
        append(CMAKE_CCXX_NOWARN_FLAGS "-diag-disable:15009")
        # The Intel(R) C++ Compiler Classic (ICC) is deprecated and will be
        # removed from product release in the second half of 2023.
        append(CMAKE_CCXX_NOWARN_FLAGS "-diag-disable:10441")
    endif()
endif()

if(MSVC)
    if(CMAKE_CXX_COMPILER_ID STREQUAL "Intel")
        # There's no opportunity for icl to link its libraries statically
        # into the library. That's why removing them when searching symbols.
        # libm symbols will be taken from ucrt.lib, otherwise, linker will
        # complain about duplicated symbols being linked to the library.
        append(NO_DYNAMIC_LIBS "/NODEFAULTLIB:libmmd.lib")
        append(NO_DYNAMIC_LIBS "/NODEFAULTLIB:svml_dispmd.lib svml_dispmt.lib")
        append(CMAKE_SHARED_LINKER_FLAGS "${NO_DYNAMIC_LIBS}")
    endif()
elseif(UNIX OR MINGW)
    if(CMAKE_CXX_COMPILER_ID STREQUAL "Intel")
        # Link Intel libraries statically (except for iomp5)
        if ("${DNNL_CPU_THREADING_RUNTIME}" STREQUAL "OMP")
            append(CMAKE_SHARED_LINKER_FLAGS "-liomp5")
        endif()
        append(CMAKE_SHARED_LINKER_FLAGS "-static-intel")
        # Tell linker to not complain about missing static libraries
        append(CMAKE_SHARED_LINKER_FLAGS "-diag-disable:10237")
    endif()
endif()

if(DNNL_ARCH_OPT_FLAGS STREQUAL "HostOpts")
    set(DNNL_ARCH_OPT_FLAGS "${DEF_ARCH_OPT_FLAGS}")
endif()

append(CMAKE_CCXX_FLAGS "${DNNL_ARCH_OPT_FLAGS}")

if(APPLE)
    set(CMAKE_INSTALL_RPATH_USE_LINK_PATH TRUE)
    # FIXME: this is ugly but required when compiler does not add its library
    # paths to rpath (like Intel compiler...)
    foreach(_ ${CMAKE_C_IMPLICIT_LINK_DIRECTORIES})
        set(_rpath "-Wl,-rpath,${_}")
        append(CMAKE_SHARED_LINKER_FLAGS "${_rpath}")
        set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} ${_rpath}")
    endforeach()
endif()

append(CMAKE_C_FLAGS "${CMAKE_CCXX_FLAGS}")
append(CMAKE_CXX_FLAGS "${CMAKE_CCXX_FLAGS}")
