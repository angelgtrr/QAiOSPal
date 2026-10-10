# QA Mobile Pal

A desktop QA tool that mirrors a USB-connected iPhone (via Appium) or an Android phone/emulator (via adb), lets you control it with the mouse and trackpad, shows where every touch happens, and records the session to an MP4.

It talks to the phone through an [Appium](https://appium.io) server (XCUITest / WebDriverAgent). The app starts Appium for you if it isn't running.

## What it does

- **Live view:** the phone screen is streamed in the app window (MJPEG, with a screenshot-polling fallback).
- **Control the phone:**
  - Click to tap.
  - Press and hold for a long press.
  - Click and drag to swipe. The drag path and timing are replayed on the phone.
  - Two-finger trackpad scroll or the mouse wheel scrolls the phone.
  - Type text into the focused field from the side panel.
  - Back, Home and App switcher buttons under the phone view, like Android's nav bar.
- **Touch overlay:** taps show as a red circle, swipes and scrolls as an orange trail, typed text as a green box around the field with a "Typed: ..." label, and nav buttons as a label.
- **Recording:** Record and Stop save an MP4 with the overlay drawn into the video. No frame images are kept. Files go to `~/Downloads/Recordings/recording_<timestamp>.mp4`, and the log shows `Recording saved: <path>`.
- **Appium auto-start:** on Connect, the app checks `/status` on the Appium URL and starts `appium` itself if needed (localhost only). It stops Appium on Disconnect or quit, but only if the app started it.

## Requirements

- macOS with Xcode installed and a Flutter SDK
- [Appium](https://appium.io) with the XCUITest driver, available on your login shell's PATH (`npm i -g appium && appium driver install xcuitest`)
- A signed WebDriverAgent set up for your device (the usual Appium iOS real-device setup)
- `ffmpeg` for recording (`brew install ffmpeg`)
- An iPhone connected over USB, trusted, with Developer Mode on

## Run

```bash
flutter run -d macos
```

1. Enter the device UDID. You can find it with `xcrun xctrace list devices`. The Appium URL defaults to `http://127.0.0.1:4723`, and Bundle ID is optional.
2. Click **Connect**. The first session can take a minute.
3. Use the phone view and the Back / Home / App switcher buttons.
4. Click **Record**, do your steps, then click **Stop**.

## Android

Switch to **Android** at the top of the side panel. The dropdown lists connected real devices and running emulators (via `adb devices`) plus any installed AVDs, which are started and waited on for you. No Appium is needed, and it works on Windows and macOS.

- Requires `adb` (Android platform-tools, on PATH or under `ANDROID_HOME`), and USB debugging on for real devices. `adb connect <ip>:5555` devices show up too.
- Same UI as iOS: click to tap, hold for long press, drag or scroll to swipe, type text, Back / Home / Recents, overlay and MP4 recording.
- Limits: swipes are straight lines (adb `input swipe`), typing is ASCII only, video is `adb screenrecord` decoded by ffmpeg (needs `ffmpeg`; falls back to `screencap` polling at a few fps without it) and there is no green field box around typed text.
- **Apps: save / install APK** (side panel, Android only): lists the device's installed apps, saves one to `~/Downloads/Apks/<package>_<version>/` (base APK plus any split APKs), and installs a saved one onto the connected device with `adb install-multiple`. App data is not included.
- Code: `lib/adb_client.dart`, `lib/android_tools.dart`; both iOS and Android implement `lib/device_client.dart`.

## Windows

The app also runs on Windows, but **iOS automation itself needs a Mac**: Appium's XCUITest driver requires Xcode, so it can't drive an iPhone from Windows. Run Appium on a Mac that has the phone attached, then on Windows:

1. Install Flutter and the Visual Studio "Desktop development with C++" workload.
2. Install `ffmpeg` and put it on PATH (`winget install ffmpeg`).
3. `flutter run -d windows`
4. Set **Appium server** to the Mac, e.g. `http://<mac-ip>:4723` (start Appium there with `appium --address 0.0.0.0`), and make sure the Mac's port 9100 (the MJPEG stream) is reachable too.

On Windows the app does not auto-start Appium. Recordings go to `%USERPROFILE%\Downloads\Recordings`.

## Notes

- The macOS app sandbox is disabled in `macos/Runner/*.entitlements` so the app can write to Downloads and launch Appium and ffmpeg.
- Touch input is sent to the phone one action at a time, so fast clicking queues up.
- Scrolling sends one swipe after you pause for about 0.1 s, so it doesn't follow your fingers live.

## Code layout

- `lib/main.dart`: UI, touch handling, connect and record flow
- `lib/wda_client.dart`: Appium / WebDriver commands (tap, hold, swipe, typing, Home, switcher)
- `lib/frame_source.dart`: MJPEG stream and screenshot fallback
- `lib/overlay.dart`: animated touch markers (shared by the live view and the recording)
- `lib/recorder.dart`: composites frames and markers and pipes them to ffmpeg
- `lib/appium_launcher.dart`: checks for and starts the Appium server
