#!/bin/zsh
set -euo pipefail

package_directory="${0:A:h:h}"
project_directory="${package_directory:h}"
runtime_directory="$package_directory/Vendor/Runtime"
runtime_source_directory="$project_directory/.work/NeMo-Speech.cpp"
build_root="$package_directory/build"
staging_app="$build_root/.bundle/duna.app"
install_app="/Applications/duna.app"
legacy_build_app="$build_root/Subtítol Live.app"
# The app was called "Subtítol Live" until 2026-09-30; its old copy is moved to the Trash.
old_install_app="/Applications/$(print -rn -- "Subtítol Live.app" | iconv -f UTF-8 -t UTF-8-MAC)"
contents_directory="$staging_app/Contents"
fonts_directory="$package_directory/Resources/Fonts"
font_files=(
    Inter_18pt-Medium.ttf OFL-Inter.txt
    AtkinsonHyperlegibleNext-Medium.ttf OFL-AtkinsonHyperlegibleNext.txt
    AtkinsonHyperlegibleMono-Medium.ttf OFL-AtkinsonHyperlegibleMono.txt
)
model_manifest_source="$package_directory/Sources/SubtitolLive/Resources/ModelManifest.json"
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [[ "$staging_app" != "$package_directory/build/.bundle/duna.app" ]]; then
    print -u2 -- "Refusing to clean an unexpected staging path: $staging_app"
    exit 1
fi
if [[ "$install_app" != "/Applications/duna.app" ]]; then
    print -u2 -- "Refusing to replace an unexpected install path: $install_app"
    exit 1
fi
# Keep the installed folder name ASCII (or, with accents, decomposed): macOS cannot start
# a share extension inside an app whose path has a precomposed "í" ("unable to obtain XPC
# bundle info dictionary", checked on macOS 26).
if [[ ! -f "$model_manifest_source" ]]; then
    print -u2 -- "Missing model manifest: $model_manifest_source"
    exit 1
fi
# The manifest lists every model the app accepts; the build bundles each of them,
# after checking it against the manifest's SHA-256.
model_count=$(plutil -extract models raw -o - "$model_manifest_source")
model_filenames=()
for (( index = 0; index < model_count; index++ )); do
    model_filename=$(plutil -extract "models.$index.filename" raw -o - "$model_manifest_source")
    model_path="$project_directory/models/$model_filename"
    if [[ ! -f "$model_path" ]]; then
        print -u2 -- "Missing model: $model_path (run scripts/download-model.sh)"
        exit 1
    fi
    expected_model_hash=$(plutil -extract "models.$index.sha256" raw -o - "$model_manifest_source")
    actual_model_hash=$(shasum -a 256 "$model_path" | awk '{print $1}')
    if [[ "$actual_model_hash" != "$expected_model_hash" ]]; then
        print -u2 -- "Model hash does not match ModelManifest.json: $model_filename"
        exit 1
    fi
    model_filenames+=("$model_filename")
done

# The punctuation package (Core ML model + tokenizer) and the voice change detector
# are checked file by file.
check_package() {
    /usr/bin/python3 - "$model_manifest_source" "$1" "$2" <<'PY'
import hashlib, json, pathlib, sys
manifest, key, root = json.load(open(sys.argv[1])), sys.argv[2], pathlib.Path(sys.argv[3])
bad = [name for name, digest in manifest[key]["files"].items()
       if not (root / name).is_file() or hashlib.sha256((root / name).read_bytes()).hexdigest() != digest]
if bad:
    print(f"{key} package missing or altered: " + ", ".join(bad), file=sys.stderr)
    sys.exit(1)
PY
}
punctuation_directory="$project_directory/models/$(plutil -extract punctuation.directory raw -o - "$model_manifest_source")"
speakers_directory="$project_directory/models/$(plutil -extract speakers.directory raw -o - "$model_manifest_source")"
if ! check_package punctuation "$punctuation_directory" || ! check_package speakers "$speakers_directory"; then
    print -u2 -- "Run scripts/download-model.sh to fetch the Core ML packages."
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
    cp "$runtime_source_directory/include/nemo_speech/asr.h" "$runtime_directory/include/nemo_speech/asr.h"
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
xcrun swift build -c release --product SubtitolPunctuationCheck

rm -rf -- "$staging_app"
mkdir -p \
    "$contents_directory/MacOS" \
    "$contents_directory/Frameworks" \
    "$contents_directory/Resources/Fonts"
cp "$package_directory/.build/release/SubtitolLive" "$contents_directory/MacOS/SubtitolLive"
# `swift run` finds the runtime in the source tree; the installed app must only look in
# its own Frameworks. Searching ~/Documents first makes macOS ask for folder access and
# leaves the app blocked at launch until someone answers.
install_name_tool -delete_rpath "$runtime_directory" "$contents_directory/MacOS/SubtitolLive" 2>/dev/null || true
cp "$package_directory/Resources/Info.plist" "$contents_directory/Info.plist"
for font_file in "${font_files[@]}"; do
    if [[ ! -f "$fonts_directory/$font_file" ]]; then
        print -u2 -- "Missing bundled reading font: $fonts_directory/$font_file"
        exit 1
    fi
done
ditto "$package_directory/Resources/Fonts" "$contents_directory/Resources/Fonts"
cp "$model_manifest_source" "$contents_directory/Resources/ModelManifest.json"
cp "$package_directory/Resources/Credits.html" "$contents_directory/Resources/Credits.html"
# The interface in five languages: the shared catalogue and the Mac's Info.plist strings,
# compiled into ca/es/gl/eu/en.lproj. The code reads them from Bundle.main.
for catalog in "$package_directory/Resources/Localizable.xcstrings" "$package_directory/iOS/SubtitolLiveMac/InfoPlist.xcstrings"; do
    xcrun xcstringstool compile "$catalog" --output-directory "$contents_directory/Resources"
done

# The same icon as the iPhone and the store build (scripts/generate-mac-icon.swift).
icon_set="$package_directory/iOS/SubtitolLiveMac/Assets.xcassets/AppIcon.appiconset"
iconset_directory="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$iconset_directory"
for icon_size in 16 32 128 256 512; do
    cp "$icon_set/AppIcon-${icon_size}@1x.png" "$iconset_directory/icon_${icon_size}x${icon_size}.png"
    cp "$icon_set/AppIcon-${icon_size}@2x.png" "$iconset_directory/icon_${icon_size}x${icon_size}@2x.png"
done
iconutil -c icns "$iconset_directory" -o "$contents_directory/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$contents_directory/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$contents_directory/Info.plist"

# The Shortcuts actions (Sources/SubtitolLive/AppIntents.swift). SwiftPM does not write
# the metadata the system reads them from, so this does what Xcode's build does: the
# compiler records the actions' constant values, and appintentsmetadataprocessor turns
# them into Resources/Metadata.appintents.
intents_work="$(mktemp -d)"
print -r -- '["AnyResolverProviding","AppEntity","AppEnum","AppExtension","AppIntent","AppIntentsPackage","AppShortcutProviding","AppShortcutsProvider","DynamicOptionsProvider","EntityQuery","ExtensionPointDefining","IntentValueQuery","Resolver","TransientEntity","_AssistantIntentsProvider","_GenerativeFunctionExtractable","_IntentValueRepresentable"]' \
    > "$intents_work/protocols.json"
app_sources=("$package_directory"/Sources/SubtitolLive/*.swift)
print -rl -- "${app_sources[@]}" > "$intents_work/sources.txt"
print -r -- "$intents_work/SubtitolLive.swiftconstvalues" > "$intents_work/constvalues.txt"
macos_sdk="$(xcrun --sdk macosx --show-sdk-path)"
xcrun swiftc -frontend -typecheck -module-name SubtitolLive \
    -target arm64-apple-macos26.0 -sdk "$macos_sdk" \
    -I "$package_directory/.build/release/Modules" \
    -Xcc -fmodule-map-file="$package_directory/.build/arm64-apple-macosx/release/CNemoSpeech.build/module.modulemap" \
    -emit-const-values-path "$intents_work/SubtitolLive.swiftconstvalues" \
    -const-gather-protocols-file "$intents_work/protocols.json" \
    "${app_sources[@]}"
xcrun appintentsmetadataprocessor \
    --toolchain-dir "${$(xcrun --find swiftc):h:h:h}" \
    --module-name SubtitolLive \
    --sdk-root "$macos_sdk" \
    --xcode-version "$(xcodebuild -version | awk '/Build version/ { print $3 }')" \
    --platform-family macOS --deployment-target 26.0 \
    --bundle-identifier "$(plutil -extract CFBundleIdentifier raw -o - "$package_directory/Resources/Info.plist")" \
    --output "$contents_directory/Resources" \
    --target-triple arm64-apple-macos26.0 \
    --binary-file "$contents_directory/MacOS/SubtitolLive" \
    --source-file-list "$intents_work/sources.txt" \
    --swift-const-vals-list "$intents_work/constvalues.txt" \
    --compile-time-extraction --deployment-aware-processing --no-app-shortcuts-localization --force \
    >/dev/null 2>&1
rm -rf -- "$intents_work"
if [[ ! -f "$contents_directory/Resources/Metadata.appintents/extract.actionsdata" ]]; then
    print -u2 -- "The Shortcuts actions' metadata was not written"
    exit 1
fi

shader_bundle="$package_directory/.build/release/SubtitolLive_SubtitolLive.bundle"
if [[ ! -d "$shader_bundle" ]]; then
    print -u2 -- "Missing compiled shader bundle: $shader_bundle"
    exit 1
fi
ditto "$shader_bundle" "$contents_directory/Resources/${shader_bundle:t}"

# Each LC_RPATH's path, spaces included.
otool_rpaths() {
    otool -l "$1" | sed -n '/cmd LC_RPATH/{n;n;s/^ *path \(.*\) (offset [0-9]*)$/\1/p;}'
}

for library in $runtime_libraries; do
    bundled_library="$contents_directory/Frameworks/$library"
    cp -L "$runtime_directory/$library" "$bundled_library"
    # The runtime was built under ~/Documents and remembers those folders; the bundled
    # copies find each other beside themselves instead.
    for rpath in ${(f)"$(otool_rpaths "$bundled_library")"}; do
        if [[ "$rpath" == /* ]]; then
            install_name_tool -delete_rpath "$rpath" "$bundled_library" 2>/dev/null
        fi
    done
    install_name_tool -add_rpath @loader_path "$bundled_library" 2>/dev/null || true
done

# Languages arrive as downloads, as in the stores (Apple-hosted pack, then the GitHub
# mirror): this local build carries every staged pack (speech model + compiled
# punctuation model) in DevPacks, and the language card installs from there.
# BUNDLED_LANGUAGES=ids would carry those inside the app (Languages/<id>) instead;
# empty by the founder's decision of 2026-10-07. stage-ios-resources.sh unpacks them.
"$package_directory/scripts/stage-ios-resources.sh" >/dev/null
for language in ${BUNDLED_LANGUAGES:-}; do
    if [[ ! -d "$project_directory/.work/ios-packs/$language" ]]; then
        echo "error: language pack $language is not staged in .work/ios-packs" >&2
        exit 1
    fi
    ditto "$project_directory/.work/ios-packs/$language" "$contents_directory/Resources/Languages/$language"
done
ditto "$project_directory/.work/ios-packs" "$contents_directory/Resources/DevPacks"

# Compile the Core ML package ahead of time so the app never compiles at launch.
bundled_speakers="$contents_directory/Resources/${speakers_directory:t}"
mkdir -p "$bundled_speakers"
"$package_directory/.build/release/SubtitolPunctuationCheck" compile \
    "$speakers_directory/segmentacio.mlpackage" "$bundled_speakers/segmentacio.mlmodelc" >/dev/null
cp "$speakers_directory/LICENSE" "$bundled_speakers/LICENSE"

# "duna" in the Share menu of a video: a small extension that opens the app
# with the file. Extensions must be sandboxed, so it is signed with its entitlements
# after the rest, and the app sealed again around it.
share_extension="$contents_directory/PlugIns/ShareExtension.appex"
share_sources="$package_directory/iOS/ShareExtensionMac"
mkdir -p "$share_extension/Contents/MacOS"
xcrun swiftc -O -parse-as-library -application-extension -module-name ShareExtension \
    -target arm64-apple-macos26.0 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -Xlinker -e -Xlinker _NSExtensionMain -framework AppKit \
    "$share_sources/ShareViewController.swift" -o "$share_extension/Contents/MacOS/ShareExtension"
cp "$share_sources/Info.plist" "$share_extension/Contents/Info.plist"

# Signed with the team's development certificate when this Mac has one: Shortcuts only
# hands its lists (a format, a language) to an app whose signature names a team, and the
# microphone permission then survives rebuilds. Without one, the app is signed ad hoc.
signing_identity="$(security find-identity -v -p codesigning | awk -F '"' '/Apple Development/ { print $2; exit }')"
signing_identity="${signing_identity:--}"
codesign --force --deep --sign "$signing_identity" "$staging_app"
codesign --force --sign "$signing_identity" --entitlements "$share_sources/ShareExtensionMac.entitlements" "$share_extension"
codesign --force --sign "$signing_identity" "$staging_app"

osascript -e 'quit app "duna"' >/dev/null 2>&1 || true
osascript -e 'quit app "Subtítol Live"' >/dev/null 2>&1 || true
killall SubtitolLive >/dev/null 2>&1 || true
sleep 0.4

rm -rf -- "$install_app"
ditto "$staging_app" "$install_app"
codesign --force --deep --sign "$signing_identity" "$install_app"
codesign --force --sign "$signing_identity" --entitlements "$share_sources/ShareExtensionMac.entitlements" "$install_app/Contents/PlugIns/ShareExtension.appex"
codesign --force --sign "$signing_identity" "$install_app"

if [[ -e "$old_install_app" ]]; then
    "$lsregister" -u "$old_install_app" >/dev/null 2>&1 || true
    osascript -e "tell application \"Finder\" to delete POSIX file \"$old_install_app\"" >/dev/null 2>&1 || true
fi
if [[ -e "$legacy_build_app" ]]; then
    rm -rf -- "$legacy_build_app"
    "$lsregister" -u "$legacy_build_app" >/dev/null 2>&1 || true
fi
"$lsregister" -f "$install_app" >/dev/null 2>&1 || true
pluginkit -a "$install_app/Contents/PlugIns/ShareExtension.appex" >/dev/null 2>&1 || true

print -r -- "$install_app"
