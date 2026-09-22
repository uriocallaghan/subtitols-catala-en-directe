# Workspace instructions

## Delivering Subtítol Live changes

For every user-requested change that affects `SubtitolLive`, deliver the installed app as part of the same task:

1. Run the relevant tests, including `xcrun swift run -c debug SubtitolLiveTests` for application behavior.
2. From `SubtitolLive/`, run `./scripts/build-app.sh`. A Swift build inside `.build/` alone is not a user-visible delivery.
3. Verify `/Applications/Subtítol Live.app` is validly signed and its executable matches the newly staged bundle.
4. Relaunch the installed app so the user is testing the new version.

The change is complete only when the installed app has been updated and verified. If installation cannot finish, report explicitly that the change exists only in source/build output.

## Repository

Public repo: https://github.com/uriocallaghan/subtitols-catala-en-directe

- The NeMo-Speech runtime ships vendored in `SubtitolLive/Vendor/Runtime` (dylibs + `include/nemo_speech/asr.h`). `Package.swift` links there; `.work/NeMo-Speech.cpp` is gitignored and only used by `build-app.sh` to refresh the vendor when present.
- The model `models/catalan-parakeet-q8.gguf` (1.1 GB) is gitignored and distributed as a release asset. `./scripts/download-model.sh` fetches and SHA256-verifies it.
