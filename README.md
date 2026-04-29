# redrunner

A native macOS countdown timer inspired by the Time Timer style.

## Run

Build the app:

```sh
./script/build_and_run.sh --build
```

The app bundle is created at:

```text
dist/redrunner.app
```

The default run command is:

```sh
./script/build_and_run.sh
```

Do not launch `Contents/MacOS/redrunner` directly. It is the app bundle's
internal executable; the app should be opened through `redrunner.app`,
Finder, or the run script.

## Controls

- Drag or click the white timer face to set a duration from 0 to 60 minutes.
- The red disk shows absolute remaining time on the 60-minute face.
- Start, pause, and reset are available below the timer.
- Pin keeps the window floating above other windows.
- Silent disables the completion sound.
- Haptic enables a trackpad haptic pulse at completion.
- The menu bar item shows the remaining minutes and provides quick actions.
