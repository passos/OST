# OST 0.2.3 Manual QA

Use this checklist for a release candidate built on macOS 26 or later on Apple Silicon.

## Build record

- Commit/tag:
- macOS and Mac model:
- App path:
- ZIP SHA-256:
- Tester/date:
- Result and notes:

## Automated preflight

- Run `swift test` and confirm all Swift Testing suites pass.
- Run `script/test.sh` and confirm the Xcode unit tests pass.
- Run `script/verify_privacy.sh --static`.
- Build the Release configuration for `platform=macOS,arch=arm64`.
- Verify `CFBundleShortVersionString` is `0.2.3` and `CFBundleVersion` is `5`.
- Verify the app and embedded XPC with `codesign --verify --deep --strict`.
- Confirm the main app has no network client entitlement and the downloader XPC does.

## Launch and permissions

- Launch the packaged app and confirm the OST icon appears in the menu bar without a Dock icon.
- On a clean first launch, confirm the overlay is unlocked and can be moved or resized; after locking it, relaunch and confirm the saved lock choice is restored.
- Choose **Settings…** and confirm the Settings window opens in front as the active key window.
- Select an MLX transcription model that is not downloaded, start capture, and confirm macOS requests System Audio Capture permission before opening Model settings.
- Switch to Apple Speech after selecting automatic input, then start capture and confirm the input is repaired to a fixed language instead of opening Model settings.
- Deny permission and confirm OST shows a clear error and a button to open the relevant System Settings page.
- Grant permission, restart capture, and confirm system audio is transcribed.

## Continuous subtitles

- Watch a video or join a meeting for at least 10 minutes.
- Confirm current text updates without blank flashes or disappearing confirmed text.
- Stop capture immediately after a short phrase and confirm its final words replace the volatile preview and remain visible.
- Confirm an identical sentence is not duplicated when Apple returns cumulative/final results.
- Confirm a deliberately repeated sentence later in time is preserved.
- Confirm the current translation preview uses its reserved two lines and never covers confirmed translations.
- Confirm EPD stabilizes translation without forcing a new visible line after every pause.
- Confirm the newest content remains visible at the bottom of each area.

## Overlay and appearance

- In Settings > Overlay, confirm the window preview immediately reflects combined/split layout, confirmed-line count, alignment, text styles, and background appearance.
- Test combined and split windows.
- Test 2, 3, 5, and 10 confirmed lines per area. Confirm the window grows and shrinks when the value changes.
- Confirm two preview lines are added independently of the configured confirmed-line count.
- Test left, center, and right alignment; verify left is the default.
- Unlock, move, and resize the overlay; lock it and verify click-through behavior.
- Test transcript, confirmed translation, and preview font sizes/colors plus background color/opacity.

## Models and languages

- Confirm the app display language defaults to English.
- Switch the app UI among English, Chinese, Japanese, and Korean and confirm the menu, settings, and overlay guidance update immediately.
- Confirm Apple Speech and Apple Translation remain the default providers.
- Confirm Apple Speech offers English, Chinese, Japanese, and Korean only, with both Simplified and Traditional Chinese selectable.
- Download one available MLX model, confirm progress/cancel/resume, then test **Show in Finder** and **Delete Downloaded Model**.
- For MLX translation, confirm only translated text is displayed and prompt/prefix echoes are removed.
- Edit the MLX translation prompt and restore the default prompt.

## Optional session files

- Confirm **Save each session to text files** is off by default.
- Enable it, select a local folder, capture two confirmed segments, and stop.
- Confirm exactly one `yyyy-MM-dd-HH-mm-ss-transcript.txt` and one matching `-translation.txt` file are created.
- Confirm corrected results update in place instead of creating duplicate lines.
- Confirm no audio file is created.
- Disable session files and confirm the next capture creates no text files.

## Privacy and network

- Confirm the Privacy tab uses plain language and states that user content is not sent outside the Mac.
- During capture, inspect connections and confirm the main OST process opens no network connection.
- Start a model download and confirm only the downloader XPC makes a network connection.
- Confirm no logs contain audio, transcript, or translation content.

## Packaging

- Extract `OST-0.2.3-macos-arm64.zip` to a clean directory.
- Confirm the executable is arm64 and the app contains `en`, `zh-Hans`, `ja`, and `ko` resources.
- Re-run strict code-sign verification on the extracted app.
- Launch the extracted app. If quarantine blocks the ad-hoc build, follow the README note and record the exact Gatekeeper message.
