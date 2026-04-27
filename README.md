# Visual Timer

A native macOS visual countdown timer inspired by the Time Timer style.

## Run

Build the app:

```sh
./script/build_and_run.sh --build
```

The app bundle is created at:

```text
dist/VisualTimer.app
```

The default run command is:

```sh
./script/build_and_run.sh
```

Do not launch `Contents/MacOS/VisualTimer` directly. It is the app bundle's
internal executable; the app should be opened through `VisualTimer.app`,
Finder, or the run script.

## Controls

- Drag or click the white timer face to set a duration from 0 to 60 minutes.
- The red disk shows absolute remaining time on the 60-minute face.
- Start, pause, and reset are available below the timer.
- Pin keeps the window floating above other windows.
- Silent disables the completion sound.
- Haptic enables a trackpad haptic pulse at completion.
