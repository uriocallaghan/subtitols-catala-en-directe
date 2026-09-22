#!/bin/zsh
set -euo pipefail

project_directory="${0:A:h:h}"
models_directory="$project_directory/models"
model_path="$models_directory/catalan-parakeet-q8.gguf"
manifest="$project_directory/SubtitolLive/Sources/SubtitolLive/Resources/ModelManifest.json"
release_tag="v0.1.0"
release_url="https://github.com/uriocallaghan/subtitols-catala-en-directe/releases/download/$release_tag/catalan-parakeet-q8.gguf"

mkdir -p "$models_directory"

expected_hash=$(plutil -extract artifact.sha256 raw -o - "$manifest")

if [[ -f "$model_path" ]]; then
    actual_hash=$(shasum -a 256 "$model_path" | awk '{print $1}')
    if [[ "$actual_hash" == "$expected_hash" ]]; then
        print -r -- "El model ja és a $model_path i el SHA256 coincideix."
        exit 0
    fi
    print -u2 -- "El model existent no coincideix amb el manifest. Es torna a baixar."
    rm -f -- "$model_path"
fi

print -r -- "Baixant catalan-parakeet-q8.gguf (~1,1 GB) des del release $release_tag…"
curl -fL --progress-bar -o "$model_path" "$release_url"

actual_hash=$(shasum -a 256 "$model_path" | awk '{print $1}')
if [[ "$actual_hash" != "$expected_hash" ]]; then
    rm -f -- "$model_path"
    print -u2 -- "Error: el SHA256 del fitxer baixat no coincideix amb el manifest."
    exit 1
fi

print -r -- "Model verificat i instal·lat a $model_path"
