#!/bin/zsh
set -euo pipefail

project_directory="${0:A:h:h}"
models_directory="$project_directory/models"
manifest="$project_directory/SubtitolLive/Sources/SubtitolLive/Resources/ModelManifest.json"
release_tag="v0.2.0"

mkdir -p "$models_directory"

# Every model the manifest lists is fetched from the release and SHA-256 verified.
model_count=$(plutil -extract models raw -o - "$manifest")
for (( index = 0; index < model_count; index++ )); do
    model_filename=$(plutil -extract "models.$index.filename" raw -o - "$manifest")
    expected_hash=$(plutil -extract "models.$index.sha256" raw -o - "$manifest")
    size_bytes=$(plutil -extract "models.$index.sizeBytes" raw -o - "$manifest")
    model_path="$models_directory/$model_filename"
    release_url="https://github.com/uriocallaghan/subtitols-catala-en-directe/releases/download/$release_tag/$model_filename"

    if [[ -f "$model_path" ]]; then
        actual_hash=$(shasum -a 256 "$model_path" | awk '{print $1}')
        if [[ "$actual_hash" == "$expected_hash" ]]; then
            print -r -- "$model_filename ja és a $model_path i el SHA256 coincideix."
            continue
        fi
        print -u2 -- "$model_filename no coincideix amb el manifest. Es torna a baixar."
        rm -f -- "$model_path"
    fi

    print -r -- "Baixant $model_filename ($(( size_bytes / 1000000 )) MB) des del release $release_tag…"
    curl -fL --progress-bar -o "$model_path" "$release_url"

    actual_hash=$(shasum -a 256 "$model_path" | awk '{print $1}')
    if [[ "$actual_hash" != "$expected_hash" ]]; then
        rm -f -- "$model_path"
        print -u2 -- "Error: el SHA256 de $model_filename no coincideix amb el manifest."
        exit 1
    fi
    print -r -- "Model verificat i instal·lat a $model_path"
done

# The Core ML packages (punctuation; voice change detector) travel as zips and are
# checked file by file.
fetch_package() {
    local key=$1 label=$2 size=$3
    local name asset archive
    name=$(plutil -extract "$key.directory" raw -o - "$manifest")
    asset=$(plutil -extract "$key.release_asset" raw -o - "$manifest")
    verify() {
        /usr/bin/python3 - "$manifest" "$key" "$models_directory/$name" <<'PY'
import hashlib, json, pathlib, sys
manifest, key, root = json.load(open(sys.argv[1])), sys.argv[2], pathlib.Path(sys.argv[3])
sys.exit(any(not (root / n).is_file() or hashlib.sha256((root / n).read_bytes()).hexdigest() != d
             for n, d in manifest[key]["files"].items()))
PY
    }
    if verify; then
        print -r -- "El $label ja és a $models_directory/$name i els SHA256 coincideixen."
        return
    fi
    print -r -- "Baixant $asset ($size) des del release $release_tag…"
    archive="$models_directory/$asset"
    curl -fL --progress-bar -o "$archive" \
        "https://github.com/uriocallaghan/subtitols-catala-en-directe/releases/download/$release_tag/$asset"
    rm -rf -- "$models_directory/$name"
    ditto -x -k "$archive" "$models_directory"
    rm -f -- "$archive"
    if ! verify; then
        print -u2 -- "Error: el $label baixat no coincideix amb el manifest."
        exit 1
    fi
    print -r -- "$label verificat i instal·lat a $models_directory/$name"
}
fetch_package punctuation "model de puntuació" "~60 MB"
fetch_package speakers "detector de canvis de veu" "~6 MB"
