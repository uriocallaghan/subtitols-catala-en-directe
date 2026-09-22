#!/bin/zsh
set -euo pipefail

package_directory="${0:A:h:h}"
project_directory="${package_directory:h}"
runtime_directory="$package_directory/Vendor/Runtime"
runtime_source_directory="$project_directory/.work/NeMo-Speech.cpp"
build_root="$package_directory/build"
staging_app="$build_root/.bundle/Subtítol Live.app"
install_app="/Applications/Subtítol Live.app"
legacy_build_app="$build_root/Subtítol Live.app"
contents_directory="$staging_app/Contents"
model_path="$project_directory/models/catalan-parakeet-q8.gguf"
font_source="$package_directory/Resources/Fonts/Inter_18pt-Medium.ttf"
model_manifest_source="$package_directory/Sources/SubtitolLive/Resources/ModelManifest.json"
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [[ "$staging_app" != "$package_directory/build/.bundle/Subtítol Live.app" ]]; then
    print -u2 -- "Refusing to clean an unexpected staging path: $staging_app"
    exit 1
fi
if [[ "$install_app" != "/Applications/Subtítol Live.app" ]]; then
    print -u2 -- "Refusing to replace an unexpected install path: $install_app"
    exit 1
fi
if [[ ! -f "$model_manifest_source" ]]; then
    print -u2 -- "Missing model manifest: $model_manifest_source"
    exit 1
fi
expected_model_hash=$(plutil -extract artifact.sha256 raw -o - "$model_manifest_source")
actual_model_hash=$(shasum -a 256 "$model_path" | awk '{print $1}')
if [[ "$actual_model_hash" != "$expected_model_hash" ]]; then
    print -u2 -- "Model hash does not match ModelManifest.json"
    exit 1
fi

mkdir -p "$build_root"
touch "$build_root/.metadata_never_index"

runtime_libraries=(
    libnemo_speech_asr_c.1.dylib
    libnemo_speech_asr.dylib
    libggml.0.dylib
    libggml-base.0.dylib
    libggml-blas.0.dylib
    libggml-cpu.0.dylib
    libggml-metal.0.dylib
)

if [[ -d "$runtime_source_directory" ]]; then
    cd "$runtime_source_directory"
    if [[ ! -f .deps/sentencepiece/lib/libsentencepiece.a ]]; then
        MACOSX_DEPLOYMENT_TARGET=14.0 scripts/build_sentencepiece_static.sh
    fi
    cmake --preset metal-asr \
        -DSENTENCEPIECE_STATIC_LIB="$runtime_source_directory/.deps/sentencepiece/lib/libsentencepiece.a" \
        -DSENTENCEPIECE_INCLUDE_DIR="$runtime_source_directory/.deps/sentencepiece/include" \
        -DGGML_METAL_NDEBUG=ON \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
    cmake --build --preset metal-asr --target nemo_speech_asr_c
    for library in $runtime_libraries; do
        cp -L "$runtime_source_directory/build/metal-asr/bin/$library" "$runtime_directory/$library"
    done
    cd "$package_directory"
fi

for library in $runtime_libraries; do
    if [[ ! -f "$runtime_directory/$library" ]]; then
        print -u2 -- "Missing vendored runtime library: $runtime_directory/$library"
        exit 1
    fi
done

cd "$package_directory"
xcrun swift build -c release --product SubtitolLive

rm -rf -- "$staging_app"
mkdir -p \
    "$contents_directory/MacOS" \
    "$contents_directory/Frameworks" \
    "$contents_directory/Resources/Fonts"
cp "$package_directory/.build/release/SubtitolLive" "$contents_directory/MacOS/SubtitolLive"
cp "$package_directory/Resources/Info.plist" "$contents_directory/Info.plist"
if [[ ! -f "$font_source" ]]; then
    print -u2 -- "Missing bundled Inter Medium font: $font_source"
    exit 1
fi
ditto "$package_directory/Resources/Fonts" "$contents_directory/Resources/Fonts"
cp "$model_manifest_source" "$contents_directory/Resources/ModelManifest.json"

shader_bundle="$package_directory/.build/release/SubtitolLive_SubtitolLive.bundle"
if [[ ! -d "$shader_bundle" ]]; then
    print -u2 -- "Missing compiled shader bundle: $shader_bundle"
    exit 1
fi
ditto "$shader_bundle" "$contents_directory/Resources/${shader_bundle:t}"

for library in $runtime_libraries; do
    cp -L "$runtime_directory/$library" "$contents_directory/Frameworks/$library"
done

bundled_model="$contents_directory/Resources/catalan-parakeet-q8.gguf"
if ! cp -c -f "$model_path" "$bundled_model"; then
    cp -f "$model_path" "$bundled_model"
fi

codesign --force --deep --sign - "$staging_app"

osascript -e 'quit app "Subtítol Live"' >/dev/null 2>&1 || true
killall SubtitolLive >/dev/null 2>&1 || true
sleep 0.4

rm -rf -- "$install_app"
ditto "$staging_app" "$install_app"
codesign --force --deep --sign - "$install_app"

if [[ -e "$legacy_build_app" ]]; then
    rm -rf -- "$legacy_build_app"
    "$lsregister" -u "$legacy_build_app" >/dev/null 2>&1 || true
fi
"$lsregister" -f "$install_app" >/dev/null 2>&1 || true

print -r -- "$install_app"
