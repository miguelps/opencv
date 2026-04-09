#!/bin/bash
#
# Unified OpenCV WebAssembly build script.
#
# Engines:
#   opencv — build_minimal_opencv_wasm.py → opencv.js (+ opencv.wasm) in --output-dir
#   minimal — build_minimal_wasm.py → build dir bin/
#   cmake — emcmake + BUILD_LIST → static libs (not opencv.js unless you extend CMake)
#
# Defaults: engine cmake, --zip ./opencv-wasm (WASM C++ SDK install tree), no WASM exceptions. Use --preset for size/speed tradeoffs.
#
set -e

# --- UI -----------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

die() { echo -e "${RED}$*${NC}" >&2; exit 1; }

# --- Paths / shared defaults --------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENCV_DIR="$SCRIPT_DIR"

# Resolve path: absolute kept; relative → $OPENCV_DIR/REL (single place for BUILD_DIR / OUTPUT_DIR / --zip dest).
abs_under_opencv() {
    case "$1" in
        /*) printf '%s' "$1" ;;
        *)  printf '%s' "$OPENCV_DIR/$1" ;;
    esac
}

ENGINE=cmake
BUILD_DIR=""
OUTPUT_DIR=dist
CLEAN=false
JOBS="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
SIMD=false
EXCEPTIONS=false
NO_OPTIMIZE_SIZE=false
PRESET=""

# Post-build: Binaryen wasm-opt (opencv + minimal engines, when .wasm exists)
WASM_OPT_LEVEL=""

# WASM C++ SDK output tree (--zip): cmake --install into prefix (+ README, LICENSE)
ZIP_DIR="./opencv-wasm"
ZIP_ONLY=false

# minimal-only
THREADS=false
SPLIT_WASM=false
ASM_JS=false
BUILD_FLAGS=""
declare -a CMAKE_OPTION_ARGS=()

# cmake-only
BUILD_LIST="core,imgproc,imgcodecs,dnn"
CMAKE_BUILD_TYPE=MinSizeRel
CMAKE_PTHREADS=ON
declare -a CMAKE_EXTRA_DEFINES=()

# --- Presets (individual flags after --preset override) -----------------------
apply_preset() {
    case "$1" in
        size)
            SIMD=false
            NO_OPTIMIZE_SIZE=false
            CMAKE_BUILD_TYPE=MinSizeRel
            ;;
        speed)
            SIMD=true
            NO_OPTIMIZE_SIZE=true
            CMAKE_BUILD_TYPE=Release
            ;;
        balanced)
            SIMD=true
            NO_OPTIMIZE_SIZE=false
            CMAKE_BUILD_TYPE=Release
            ;;
        *)
            die "Invalid --preset: $1 (use size, speed, or balanced)"
            ;;
    esac
}

# --- WASM SDK merge for --zip output (Emscripten C++ consumers) ---------------
write_cpp_sdk_readme() {
    local dest="$1"
    local readme="$dest/OPENCV_WASM_CPP_SDK.txt"
    {
        echo "OpenCV — WebAssembly / Emscripten C++ SDK bundle"
        echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo ""
        echo "OpenCV sources: $OPENCV_DIR"
        echo "CMake build tree: $BUILD_DIR"
        echo ""
        if [[ -f "$OPENCV_DIR/modules/core/include/opencv2/core/version.hpp" ]]; then
            echo "Version macros (from include):"
            grep -E '^#define CV_VERSION_(MAJOR|MINOR|REVISION|STATUS) ' \
                "$OPENCV_DIR/modules/core/include/opencv2/core/version.hpp" || true
            echo ""
        fi
        if command -v emcc &>/dev/null; then
            echo "Emscripten (current shell):"
            emcc --version 2>/dev/null | head -n 3 || true
        fi
        [[ -n "${EMSCRIPTEN:-}" ]] && echo "EMSCRIPTEN=${EMSCRIPTEN}"
        echo ""
        if [[ -f "$BUILD_DIR/CMakeCache.txt" ]]; then
            echo "CMake cache (selected):"
            grep -E '^(CMAKE_BUILD_TYPE|BUILD_LIST|WITH_PTHREADS|CMAKE_TOOLCHAIN_FILE):' \
                "$BUILD_DIR/CMakeCache.txt" 2>/dev/null || true
            echo ""
        fi
        echo "Layout"
        echo "  include/     Public headers (opencv2/...)"
        echo "  lib/         Static libraries (*.a); may include lib/opencv4/3rdparty/"
        echo "  share/       May contain OpenCVConfig.cmake and data"
        echo ""
        echo "Consumers must use a compatible Emscripten toolchain (same major version"
        echo "and matching -pthread / -fwasm-exceptions / SIMD choices as your build)."
        echo ""
        echo "Integration"
        echo "  Prefer CMake: CMAKE_PREFIX_PATH=\$SDK emcmake cmake ... find_package(OpenCV REQUIRED)"
        echo "  Or link .a manually (order matters; add 3rdparty libs from lib/opencv4/3rdparty/)."
        echo ""
        echo "Completeness"
        echo "  The --zip step merges BUILD_DIR/lib into the prefix and ensures every .a listed in"
        echo "  lib/cmake/opencv4/OpenCVModules-*.cmake exists (copy from build or Emscripten stub)."
        echo "  Stubs satisfy CMake imported-target checks for optional deps you may not link."
        echo ""
    } >"$readme"
}

# Minimal .a so OpenCVModules import checks pass (same arch as your SDK: use emcc/emar).
opencv_pack_create_stub_a() {
    local out="$1"
    command -v emcc &>/dev/null && command -v emar &>/dev/null || return 1
    mkdir -p "$(dirname "$out")" || return 1
    local tdir
    tdir=$(mktemp -d) || return 1
    printf '%s\n' 'int opencv_sdk_stub_export(void){return 0;}' >"$tdir/stub.c"
    emcc -x c "$tdir/stub.c" -c -o "$tdir/stub.o" -fno-exceptions || { rm -rf "$tdir"; return 1; }
    emar rcs "$out" "$tdir/stub.o" || { rm -rf "$tdir"; return 1; }
    rm -rf "$tdir"
    return 0
}

# Every IMPORTED_LOCATION *_PREFIX/.../*.a in OpenCVModules-*.cmake must exist on disk.
opencv_pack_fill_missing_import_libs() {
    local dest="$1"
    local bdir="$2"
    local cm="$dest/lib/cmake/opencv4"
    [[ -d "$cm" ]] || return 0
    local f rel needed found line _line_trim
    for f in "$cm"/OpenCVModules-*.cmake; do
        [[ -f "$f" ]] || continue
        while IFS= read -r line || [[ -n "$line" ]]; do
            _line_trim="${line#"${line%%[![:space:]]*}"}"
            [[ "$_line_trim" == \#* ]] && continue
            [[ "$line" == *'${_IMPORT_PREFIX}'* ]] || continue
            [[ "$line" == *.a* ]] || continue
            rel=$(printf '%s' "$line" | sed -n 's/.*"\${_IMPORT_PREFIX}\(\/[^\"]*\.a\)".*/\1/p')
            [[ -n "$rel" ]] || continue
            needed="${dest}${rel}"
            [[ -f "$needed" ]] && continue
            echo -e "${YELLOW}SDK (--zip): missing ${rel#\/}${NC}"
            found=""
            if [[ -d "$bdir/lib" ]]; then
                found=$(find "$bdir/lib" -type f -name "$(basename "$needed")" 2>/dev/null | head -n 1)
            fi
            if [[ -n "$found" ]]; then
                mkdir -p "$(dirname "$needed")"
                cp -a "$found" "$needed"
                echo "  copied from build: $found"
                continue
            fi
            if opencv_pack_create_stub_a "$needed"; then
                echo "  stub (emcc/emar): $needed"
                continue
            fi
            die "Missing archive and could not stub (activate emsdk for emcc/emar): $needed"
        done <"$f"
    done
}

merge_wasm_sdk_zip() {
    [[ -n "${1:-}" ]] || die "--zip: empty destination"
    local dest
    dest="$(abs_under_opencv "$1")"
    [[ -d "$BUILD_DIR" ]] || die "Build directory not found: $BUILD_DIR"
    [[ -f "$BUILD_DIR/CMakeCache.txt" ]] || die "Not a CMake build (missing CMakeCache.txt): $BUILD_DIR"

    echo -e "${YELLOW}WASM SDK (--zip) → $dest${NC}"
    rm -rf "$dest"
    mkdir -p "$dest"

    if ! cmake --install "$BUILD_DIR" --prefix "$dest"; then
        echo -e "${YELLOW}cmake --install failed; filling from build tree.${NC}"
    fi

    # Merge build tree (covers failed/partial install; overlays 3rdparty .a install may omit).
    if [[ -d "$BUILD_DIR/lib" ]]; then
        mkdir -p "$dest/lib"
        cp -a "$BUILD_DIR/lib"/. "$dest/lib/"
    fi
    if [[ -d "$BUILD_DIR/lib/cmake" ]]; then
        mkdir -p "$dest/lib/cmake"
        cp -a "$BUILD_DIR/lib/cmake"/. "$dest/lib/cmake/"
    fi
    if [[ -d "$BUILD_DIR/opencv2" ]]; then
        mkdir -p "$dest/include/opencv4"
        cp -a "$BUILD_DIR/opencv2" "$dest/include/opencv4/"
    fi

    opencv_pack_fill_missing_import_libs "$dest" "$BUILD_DIR"

    if [[ ! -f "$dest/LICENSE" ]] && [[ ! -f "$dest/share/licenses/opencv4/LICENSE" ]]; then
        for f in LICENSE COPYING; do
            if [[ -f "$OPENCV_DIR/$f" ]]; then
                cp -a "$OPENCV_DIR/$f" "$dest/"
                break
            fi
        done
    fi

    write_cpp_sdk_readme "$dest"
    echo -e "${GREEN}WASM SDK: $dest${NC}"
    echo "  Read: $dest/OPENCV_WASM_CPP_SDK.txt"

    # Sibling archive: opencv-wasm-<git-HEAD-8>.zip (contents: basename(dest)/...)
    local zip_parent zip_base commit_hash zip_path
    zip_parent="$(dirname "$dest")"
    zip_base="$(basename "$dest")"
    commit_hash=$(git -C "$OPENCV_DIR" rev-parse HEAD 2>/dev/null | cut -c1-8)
    if [[ ${#commit_hash} -ne 8 ]]; then
        echo -e "${YELLOW}Skip opencv-wasm-*.zip: need git repo at $OPENCV_DIR (8-char commit hash in filename).${NC}"
    elif ! command -v zip &>/dev/null; then
        echo -e "${YELLOW}zip not in PATH; skip opencv-wasm-*.zip${NC}"
    else
        zip_path="$zip_parent/opencv-wasm-${commit_hash}.zip"
        rm -f "$zip_path"
        (cd "$zip_parent" && zip -qr "opencv-wasm-${commit_hash}.zip" "$zip_base")
        echo -e "${GREEN}WASM SDK zip: $zip_path${NC}"
    fi
}

# --- Help ---------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Presets (optional; later flags override):
  --preset size       Smallest wasm: no SIMD, keep -Os (opencv), MinSizeRel (cmake)
  --preset speed      Faster: SIMD, no extra -Os shrink (opencv Release defaults), Release (cmake)
  --preset balanced   SIMD + -Os-style size flags (opencv): smaller than speed, faster than size-only

General:
  --engine ENGINE     opencv | minimal | cmake (default: cmake)
  --opencv-dir DIR    OpenCV source root (default: this script's directory)
  --build-dir DIR     Build directory (defaults: opencv/minimal → build_minimal_wasm, cmake → build_wasm_libs)
  --clean             Clean before build (per engine)
  --jobs N            Parallel jobs (default: auto)
  --simd              Enable SIMD where supported
  --exceptions        WebAssembly C++ exceptions
  --wasm-opt [L]      After build, run wasm-opt on .wasm if found (default level: Oz). L = O, O1, O2, O3, O4, Os, Oz
  --zip DIR           After build: cmake --install + merge BUILD_DIR into prefix; stub missing .a if needed. DIR is removed first. Also writes sibling opencv-wasm-<git-HEAD-8>.zip (first 8 hex chars of git commit at --opencv-dir). Default: ./opencv-wasm
  --no-zip            Skip SDK output (overrides default --zip)
  --zip-only DIR      Merge SDK from existing BUILD_DIR only (needs CMakeCache.txt). No compile step. EMSCRIPTEN not required; emcc/emar only if stub .a are needed. DIR removed first. Also writes sibling opencv-wasm-<git-HEAD-8>.zip.
  --help, -h

Engine opencv:
  --output-dir DIR    (default: dist)
  --no-optimize-size  Disable -Os Release flags in build_minimal_opencv_wasm.py

Engine minimal:
  --threads --split-wasm --asm-js
  --build-flags STR   --cmake-option OPT (repeatable)

Engine cmake:
  --build-list --cmake-build-type --no-pthreads --cmake-define (repeatable)

Environment:
  EMSCRIPTEN          Required for normal builds (source emsdk/emsdk_env.sh). Not read for --zip-only.
EOF
}

# --- CLI ----------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        --preset)
            [[ -n "${2:-}" ]] || die "--preset requires size, speed, or balanced"
            apply_preset "$2"
            PRESET="$2"
            shift 2
            ;;
        --engine)
            [[ -n "${2:-}" ]] || die "--engine requires opencv, minimal, or cmake"
            ENGINE="$2"
            shift 2
            ;;
        --opencv-dir)
            OPENCV_DIR="$2"
            shift 2
            ;;
        --build-dir)
            BUILD_DIR="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --clean)
            CLEAN=true
            shift
            ;;
        --jobs)
            JOBS="$2"
            shift 2
            ;;
        --simd)
            SIMD=true
            shift
            ;;
        --exceptions)
            EXCEPTIONS=true
            shift
            ;;
        --no-optimize-size)
            NO_OPTIMIZE_SIZE=true
            shift
            ;;
        --wasm-opt)
            if [[ -n "${2:-}" && "${2:-}" != -* ]]; then
                WASM_OPT_LEVEL="$2"
                shift 2
            else
                WASM_OPT_LEVEL=Oz
                shift
            fi
            ;;
        --zip)
            [[ -n "${2:-}" ]] || die "--zip requires a destination directory"
            ZIP_DIR="$2"
            shift 2
            ;;
        --no-zip)
            ZIP_DIR=""
            shift
            ;;
        --zip-only)
            [[ -n "${2:-}" ]] || die "--zip-only requires a destination directory"
            ZIP_DIR="$2"
            ZIP_ONLY=true
            shift 2
            ;;
        --threads)
            THREADS=true
            shift
            ;;
        --split-wasm)
            SPLIT_WASM=true
            shift
            ;;
        --asm-js)
            ASM_JS=true
            shift
            ;;
        --build-flags)
            BUILD_FLAGS="$2"
            shift 2
            ;;
        --cmake-option)
            CMAKE_OPTION_ARGS+=(--cmake_option "$2")
            shift 2
            ;;
        --build-list)
            BUILD_LIST="$2"
            shift 2
            ;;
        --cmake-build-type)
            CMAKE_BUILD_TYPE="$2"
            shift 2
            ;;
        --no-pthreads)
            CMAKE_PTHREADS=OFF
            shift
            ;;
        --cmake-define)
            CMAKE_EXTRA_DEFINES+=("-D$2")
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1 (try --help)"
            ;;
    esac
done

case "$ENGINE" in
    opencv|minimal|cmake) ;;
    *) die "Invalid --engine: $ENGINE" ;;
esac

EMSCRIPTEN_DIR="${EMSCRIPTEN_DIR:-$EMSCRIPTEN}"

# --- Resolve paths ------------------------------------------------------------
if [[ -z "$BUILD_DIR" ]]; then
    case "$ENGINE" in
        opencv|minimal) BUILD_DIR="$OPENCV_DIR/build_minimal_wasm" ;;
        cmake)          BUILD_DIR="$OPENCV_DIR/build_wasm_libs" ;;
    esac
else
    BUILD_DIR="$(abs_under_opencv "$BUILD_DIR")"
fi

OUTPUT_DIR="$(abs_under_opencv "$OUTPUT_DIR")"

# --- WASM SDK --zip-only (no build) -------------------------------------------
if [[ "$ZIP_ONLY" == true ]]; then
    [[ -n "$ZIP_DIR" ]] || die "--zip-only requires a destination directory"
    merge_wasm_sdk_zip "$ZIP_DIR"
    exit 0
fi

[[ -n "$EMSCRIPTEN" ]] || die "EMSCRIPTEN is not set. source emsdk/emsdk_env.sh"

# --- Status line --------------------------------------------------------------
echo -e "${BLUE}=== OpenCV WASM build (${ENGINE}) ===${NC}"
[[ -n "$PRESET" ]] && echo "  Preset:         $PRESET"
echo "  OpenCV source:  $OPENCV_DIR"
echo "  Build dir:      $BUILD_DIR"
echo "  Emscripten:     $EMSCRIPTEN_DIR"
echo "  Jobs:           $JOBS"
echo "  SIMD:           $SIMD"
echo "  Exceptions:     $EXCEPTIONS"
echo "  Size-opt (-Os): $([[ "$NO_OPTIMIZE_SIZE" == true ]] && echo off || echo on) (opencv engine only)"
echo "  wasm-opt:       ${WASM_OPT_LEVEL:-off}"
if [[ -n "$ZIP_DIR" ]]; then
    echo "  --zip output:   $(abs_under_opencv "$ZIP_DIR")"
else
    echo "  --zip output:   off"
fi
echo "  Clean:          $CLEAN"
echo

# --- Engines ------------------------------------------------------------------
run_opencv_engine() {
    local -a cmd=(
        python3 "$OPENCV_DIR/build_minimal_opencv_wasm.py"
        --build-dir "$BUILD_DIR"
        --output-dir "$OUTPUT_DIR"
        --jobs "$JOBS"
    )
    [[ "$SIMD" == true ]] && cmd+=(--simd)
    [[ "$NO_OPTIMIZE_SIZE" == true ]] && cmd+=(--no-optimize-size)
    [[ "$EXCEPTIONS" == true ]] && cmd+=(--exceptions)
    [[ "$CLEAN" == true ]] && cmd+=(--clean)
    echo -e "${YELLOW}Running:${NC} ${cmd[*]}"
    "${cmd[@]}"
}

run_minimal_engine() {
    mkdir -p "$BUILD_DIR"
    local -a cmd=(
        python3 "$OPENCV_DIR/build_minimal_wasm.py" "$BUILD_DIR"
        --opencv_dir "$OPENCV_DIR"
        --emscripten_dir "$EMSCRIPTEN_DIR"
        --jobs "$JOBS"
    )
    if [[ "$ASM_JS" == true ]]; then
        cmd+=(--disable_wasm)
    else
        cmd+=(--build_wasm)
    fi
    [[ "$SPLIT_WASM" == true ]] && cmd+=(--disable_single_file)
    [[ "$SIMD" == true ]] && cmd+=(--simd)
    [[ "$THREADS" == true ]] && cmd+=(--threads)
    [[ "$EXCEPTIONS" == true ]] && cmd+=(--enable_exception)
    [[ "$CLEAN" == true ]] && cmd+=(--clean_build_dir)
    [[ -n "$BUILD_FLAGS" ]] && cmd+=(--build_flags "$BUILD_FLAGS")
    [[ ${#CMAKE_OPTION_ARGS[@]} -gt 0 ]] && cmd+=("${CMAKE_OPTION_ARGS[@]}")
    echo -e "${YELLOW}Running:${NC} ${cmd[*]}"
    "${cmd[@]}"
}

run_cmake_engine() {
    if [[ "$CLEAN" == true ]]; then
        echo -e "${YELLOW}Cleaning $BUILD_DIR ...${NC}"
        rm -rf "$BUILD_DIR"
    fi
    mkdir -p "$BUILD_DIR"
    local -a xcflags=()
    if [[ "$EXCEPTIONS" == true ]]; then
        xcflags+=(
            -DCMAKE_CXX_FLAGS=-fwasm-exceptions
            -DCMAKE_C_FLAGS=-fwasm-exceptions
            -DCMAKE_EXE_LINKER_FLAGS=-fwasm-exceptions
            -DCMAKE_SHARED_LINKER_FLAGS=-fwasm-exceptions
        )
    fi
    # Imgcodecs: keep JPEG + PNG only (libjpeg-turbo, libpng, zlib). Drop WebP/TIFF/JPEG2000.
    # Protobuf: off so libprotobuf is not built (DNN still builds; ONNX/TF/Caffe protobuf importers disabled).
    echo -e "${YELLOW}Configuring with emcmake ...${NC}"
    emcmake cmake -S "$OPENCV_DIR" -B "$BUILD_DIR" \
        -DBUILD_SHARED_LIBS=OFF \
        "-DWITH_PTHREADS=$CMAKE_PTHREADS" \
        -DWITH_ITT=OFF \
        -DWITH_IPP=OFF \
        -DWITH_PROTOBUF=OFF \
        -DWITH_WEBP=OFF \
        -DWITH_TIFF=OFF \
        -DWITH_OPENJPEG=OFF \
        -DWITH_JASPER=OFF \
        "-DBUILD_LIST=$BUILD_LIST" \
        "-DCMAKE_BUILD_TYPE=$CMAKE_BUILD_TYPE" \
        "${xcflags[@]}" \
        "${CMAKE_EXTRA_DEFINES[@]}"

    echo -e "${YELLOW}Building ...${NC}"
    cmake --build "$BUILD_DIR" -j "$JOBS"
}

maybe_wasm_opt() {
    [[ -z "$WASM_OPT_LEVEL" ]] && return 0
    if ! command -v wasm-opt &>/dev/null; then
        echo -e "${YELLOW}wasm-opt not in PATH; skip post-process.${NC}"
        return 0
    fi
    case "$WASM_OPT_LEVEL" in
        O|O1|O2|O3|O4|Os|Oz) ;;
        *)
            die "Invalid wasm-opt level: $WASM_OPT_LEVEL (use O, O1, O2, O3, O4, Os, Oz)"
            ;;
    esac
    local f tmp
    for f in "$OUTPUT_DIR/opencv.wasm" "$BUILD_DIR/bin/opencv.wasm"; do
        [[ -f "$f" ]] || continue
        tmp="${f}.wasm-opt.tmp"
        echo -e "${YELLOW}wasm-opt -${WASM_OPT_LEVEL} $f${NC}"
        wasm-opt "-$WASM_OPT_LEVEL" -o "$tmp" "$f"
        mv "$tmp" "$f"
    done
}

case "$ENGINE" in
    opencv)  run_opencv_engine ;;
    minimal) run_minimal_engine ;;
    cmake)   run_cmake_engine ;;
esac

maybe_wasm_opt

if [[ -n "$ZIP_DIR" ]]; then
    merge_wasm_sdk_zip "$ZIP_DIR"
fi

echo
echo -e "${GREEN}=== Build finished ===${NC}"
if [[ "$ENGINE" == opencv ]]; then
    echo "Artifacts: $OUTPUT_DIR (opencv.js, opencv.wasm when split)"
elif [[ "$ENGINE" == minimal ]]; then
    echo "Artifacts: $BUILD_DIR/bin/opencv.js (and .wasm if split)"
else
    echo "Artifacts: static libs under $BUILD_DIR/lib (BUILD_LIST=$BUILD_LIST)"
fi
[[ -n "$ZIP_DIR" ]] && echo "WASM SDK (--zip): $(abs_under_opencv "$ZIP_DIR") (see OPENCV_WASM_CPP_SDK.txt inside)"
