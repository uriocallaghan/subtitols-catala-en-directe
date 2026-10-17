#!/usr/bin/env bash
# Builds the NeMo-Speech runtime as one static xcframework
# (Vendor/RuntimeiOS/NemoSpeechRuntime.xcframework) with three slices: iPhone (Metal),
# iOS Simulator (CPU) and macOS arm64 (Metal, for the Mac App Store app built from
# iOS/project.yml). The SwiftPM/ad-hoc Mac app keeps using the dylibs in Vendor/Runtime;
# this script does not touch them.
#   ./scripts/build-ios-runtime.sh             rebuild every slice
#   ./scripts/build-ios-runtime.sh --mac-only  rebuild only the macOS slice and keep the
#                                              iOS slices already in the xcframework
# Needs .work/NeMo-Speech.cpp with the patches in Vendor/Runtime/patches applied
# (0003 lets the ASR library build as STATIC); patches that apply cleanly are applied.
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package_directory="$(cd "$script_directory/.." && pwd)"
project_directory="$(cd "$package_directory/.." && pwd)"
runtime_source="$project_directory/.work/NeMo-Speech.cpp"
work="$project_directory/.work/ios-runtime"
output="$package_directory/Vendor/RuntimeiOS"
deployment_target="${IOS_DEPLOYMENT_TARGET:-17.0}"
mac_deployment_target="${MAC_DEPLOYMENT_TARGET:-26.0}"
patches="$package_directory/Vendor/Runtime/patches"
mac_only=false
[[ "${1:-}" == "--mac-only" ]] && mac_only=true
jobs="$(sysctl -n hw.ncpu)"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [[ ! -d "$runtime_source" ]]; then
    echo "Missing $runtime_source (see Vendor/Runtime/patches/README.md)" >&2
    exit 1
fi
for patch in "$patches"/*.patch; do
    if git -C "$runtime_source" apply --reverse --check "$patch" 2>/dev/null; then
        continue
    elif git -C "$runtime_source" apply --check "$patch" 2>/dev/null; then
        echo "Applying ${patch##*/}"
        git -C "$runtime_source" apply "$patch"
    else
        echo "${patch##*/} is neither applied nor applicable to $runtime_source" >&2
        exit 1
    fi
done
sentencepiece_source="$runtime_source/.deps/sentencepiece-build/source"
if [[ ! -d "$sentencepiece_source" ]]; then
    echo "Missing SentencePiece source; run $runtime_source/scripts/build_sentencepiece_static.sh first" >&2
    exit 1
fi

build_platform() {
    local sdk="$1"
    local platform_work="$work/$sdk"
    # The Simulator's Metal driver cannot wrap host memory the way ggml's Metal backend
    # does (it aborts in newBufferWithBytesNoCopy), so the simulator slice runs on the
    # CPU with Accelerate. iPhones get the Metal backend.
    # The macOS slice builds for the host system (no CMAKE_SYSTEM_NAME) with GGML_NATIVE
    # off like the others, so it runs on every Apple silicon Mac, not just this one.
    local metal=ON
    [[ "$sdk" == iphonesimulator ]] && metal=OFF
    local common=(
        -G Ninja
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_OSX_SYSROOT="$sdk"
        -DCMAKE_OSX_ARCHITECTURES=arm64
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    )
    if [[ "$sdk" == macosx ]]; then
        common+=(-DCMAKE_OSX_DEPLOYMENT_TARGET="$mac_deployment_target")
    else
        common+=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment_target")
    fi

    # SentencePiece expects an iOS toolchain file that defines this helper.
    mkdir -p "$platform_work"
    echo 'function(set_xcode_property)' > "$platform_work/xcode-property.cmake"
    echo 'endfunction()' >> "$platform_work/xcode-property.cmake"
    cmake "${common[@]}" -S "$sentencepiece_source" -B "$platform_work/sentencepiece" \
        -DCMAKE_PROJECT_INCLUDE="$platform_work/xcode-property.cmake" \
        -DSPM_BUILD_TEST=OFF -DSPM_ENABLE_SHARED=OFF -DSPM_ENABLE_TCMALLOC=OFF > "$platform_work.sentencepiece.log"
    cmake --build "$platform_work/sentencepiece" --target sentencepiece-static -j "$jobs" >> "$platform_work.sentencepiece.log"
    mkdir -p "$platform_work/deps/sentencepiece/lib" "$platform_work/deps/sentencepiece/include"
    cp "$platform_work/sentencepiece/src/libsentencepiece.a" "$platform_work/deps/sentencepiece/lib/"
    cp "$sentencepiece_source/src/sentencepiece_processor.h" "$platform_work/deps/sentencepiece/include/"

    cmake "${common[@]}" -S "$runtime_source" -B "$platform_work/runtime" \
        -DBUILD_SHARED_LIBS=OFF \
        -DNEMO_SPEECH_ASR_LIBRARY_TYPE=STATIC \
        -DNEMO_SPEECH_DEPENDENCY_PREFIX="$platform_work/deps" \
        -DSENTENCEPIECE_STATIC_LIB="$platform_work/deps/sentencepiece/lib/libsentencepiece.a" \
        -DSENTENCEPIECE_INCLUDE_DIR="$platform_work/deps/sentencepiece/include" \
        -DNEMO_SPEECH_GGML_PATCHED=OFF \
        -DNEMO_SPEECH_BUILD_ASR=ON -DNEMO_SPEECH_BUILD_DIAR=ON \
        -DNEMO_SPEECH_BUILD_TTS=OFF -DNEMO_SPEECH_BUILD_NMT=OFF \
        -DNEMO_SPEECH_BUILD_CLI=OFF -DNEMO_SPEECH_BUILD_MIC_CAPTURE=OFF \
        -DNEMO_SPEECH_BUILD_EXAMPLES=OFF -DNEMO_SPEECH_BUILD_TESTS=OFF -DNEMO_SPEECH_BUILD_TOOLS=OFF \
        -DGGML_METAL="$metal" -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_METAL_NDEBUG=ON \
        -DGGML_BLAS=ON -DGGML_BLAS_VENDOR=Apple -DGGML_ACCELERATE=ON \
        -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF -DGGML_CCACHE=OFF > "$platform_work.runtime.log"
    cmake --build "$platform_work/runtime" --target nemo_speech_asr_c -j "$jobs" >> "$platform_work.runtime.log"

    # One archive per platform: every static library the C API pulls in.
    local archives=()
    while IFS= read -r archive; do archives+=("$archive"); done < <(
        find "$platform_work/runtime" -name '*.a' \
            \( -name 'libnemo_speech_*' -o -name 'libggml*' \) | sort)
    archives+=("$platform_work/deps/sentencepiece/lib/libsentencepiece.a")
    printf '  %s\n' "${archives[@]##*/}"
    xcrun libtool -static -no_warning_for_no_symbols -o "$platform_work/libNemoSpeechRuntime.a" "${archives[@]}"
}

if $mac_only; then
    # Keep the iOS slices exactly as they are in the vendored xcframework.
    existing="$output/NemoSpeechRuntime.xcframework"
    for pair in iphoneos:ios-arm64 iphonesimulator:ios-arm64-simulator; do
        library="$existing/${pair#*:}/libNemoSpeechRuntime.a"
        if [[ ! -f "$library" ]]; then
            echo "Missing $library; run without --mac-only" >&2
            exit 1
        fi
        rm -rf "$work/kept/${pair%%:*}"
        mkdir -p "$work/kept/${pair%%:*}"
        cp "$library" "$work/kept/${pair%%:*}/libNemoSpeechRuntime.a"
    done
    ios_libraries="$work/kept"
    rm -rf "$work/macosx" "$work/headers"
    platforms=(macosx)
else
    rm -rf "$work"
    ios_libraries="$work"
    platforms=(iphoneos iphonesimulator macosx)
fi
mkdir -p "$work"
for sdk in "${platforms[@]}"; do
    echo "Building the runtime for $sdk…"
    build_platform "$sdk"
done

headers="$work/headers"
mkdir -p "$headers/nemo_speech"
cp "$runtime_source/include/nemo_speech/asr.h" "$headers/nemo_speech/"

staged="$work/NemoSpeechRuntime.xcframework"
rm -rf "$staged"
xcodebuild -create-xcframework \
    -library "$ios_libraries/iphoneos/libNemoSpeechRuntime.a" -headers "$headers" \
    -library "$ios_libraries/iphonesimulator/libNemoSpeechRuntime.a" -headers "$headers" \
    -library "$work/macosx/libNemoSpeechRuntime.a" -headers "$headers" \
    -output "$staged"
rm -rf "$output/NemoSpeechRuntime.xcframework"
mkdir -p "$output"
mv "$staged" "$output/NemoSpeechRuntime.xcframework"
du -sh "$output/NemoSpeechRuntime.xcframework"
