#!/bin/zsh
# Prepares what the iPhone app needs besides its code, from models/ and the manifest:
#   .work/ios-stage/veus-segmentacio   compiled voice-change model, bundled in the app
#   .work/ios-packs/<language>/        one unpacked language pack per manifest language
#                                      (speech model + compiled punctuation model); the
#                                      simulator installs from here via SUBTITOL_PACKS_DIR
# With --asset-packs it also writes .work/ios-asset-packs/<assetPack>.aar, the archives
# to upload to App Store Connect as Apple-hosted, on-demand Background Assets.
set -euo pipefail

script_directory="${0:A:h}"
package_directory="${script_directory:h}"
project_directory="${package_directory:h}"
manifest="$package_directory/Sources/SubtitolLive/Resources/ModelManifest.json"
stage="$project_directory/.work/ios-stage"
packs="$project_directory/.work/ios-packs"
archives="$project_directory/.work/ios-asset-packs"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

cd "$package_directory"
xcrun swift build -c release --product SubtitolPunctuationCheck >/dev/null
compiler="$package_directory/.build/release/SubtitolPunctuationCheck"

speakers_directory="$project_directory/models/veus-segmentacio"
rm -rf "$stage/veus-segmentacio"
mkdir -p "$stage/veus-segmentacio"
"$compiler" compile "$speakers_directory/segmentacio.mlpackage" "$stage/veus-segmentacio/segmentacio.mlmodelc" >/dev/null
cp "$speakers_directory/LICENSE" "$stage/veus-segmentacio/LICENSE"

# One line per staged language (packStaged false = no files yet): id|model filename|punctuation folder (or empty)|asset pack. Not tabs: read would merge an empty field.
languages=("${(@f)$(python3 - "$manifest" <<'EOF'
import json, sys
manifest = json.load(open(sys.argv[1]))
models = {m["id"]: m for m in manifest["models"]}
for language in manifest.get("languages", []):
    if language.get("packStaged") is False:
        continue
    print("|".join([
        language["id"],
        models[language["model"]]["filename"],
        language.get("punctuation") or "",
        language["assetPack"],
    ]))
EOF
)}")

rm -rf "$packs"
mkdir -p "$packs"
for line in "${languages[@]}"; do
    IFS='|' read -r language_id model_filename punctuation asset_pack <<< "$line"
    pack="$packs/$language_id"
    mkdir -p "$pack"
    cp -c "$project_directory/models/$model_filename" "$pack/$model_filename" 2>/dev/null \
        || cp "$project_directory/models/$model_filename" "$pack/$model_filename"
    if [[ -n "$punctuation" ]]; then
        source_punctuation="$project_directory/models/$punctuation"
        mkdir -p "$pack/$punctuation"
        "$compiler" compile "$source_punctuation/puntuacio.mlpackage" "$pack/$punctuation/puntuacio.mlmodelc" >/dev/null
        for tokenizer_file in vocab.json merges.txt labels.json; do
            cp "$source_punctuation/$tokenizer_file" "$pack/$punctuation/$tokenizer_file"
        done
    fi
    echo "Pack $language_id: $(du -sh "$pack" | cut -f1)"

    if [[ "${1:-}" == "--asset-packs" ]]; then
        mkdir -p "$archives"
        cat > "$archives/$asset_pack.json" <<EOF
{
    "assetPackID": "$asset_pack",
    "downloadPolicy": { "onDemand": {} },
    "fileSelectors": [ { "directory": "$language_id" } ],
    "platforms": [ "iOS", "macOS" ]
}
EOF
        # ba-package refuses to overwrite an archive.
        rm -f "$archives/$asset_pack.aar"
        (cd "$packs" && xcrun ba-package package "$archives/$asset_pack.json" --output-path "$archives/$asset_pack.aar")
        echo "Archive: $archives/$asset_pack.aar"
    fi
done
