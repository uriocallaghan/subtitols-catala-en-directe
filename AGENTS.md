# Workspace instructions

## Delivering Subtítol Live changes

For every user-requested change that affects `SubtitolLive`, deliver the installed app as part of the same task:

1. Run the relevant tests, including `xcrun swift run -c debug SubtitolLiveTests` for application behavior.
2. From `SubtitolLive/`, run `./scripts/build-app.sh`. A Swift build inside `.build/` alone is not a user-visible delivery.
3. Verify `/Applications/Subtítol Live.app` is validly signed and its executable matches the newly staged bundle.
4. Relaunch the installed app so the user is testing the new version.

The change is complete only when the installed app has been updated and verified. If installation cannot finish, report explicitly that the change exists only in source/build output.
