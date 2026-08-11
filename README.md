# NES Wallpaper

A modern macOS recreation of the 2016 UberNES "Nintendo Saver": a live desktop wallpaper that tiles NES games playing back tool-assisted speedrun (TAS) movies, rendered behind your desktop icons.

The original was an x86_64 screensaver built on the UberNES emulator and its proprietary movie format. This project replaces both halves with maintained equivalents:

- **Emulator**: the [FCEUX](https://github.com/TASEmulators/fceux) core, vendored and compiled directly into the app (see `vendor/VENDOR.md`).
- **Movies**: FCEUX's FM2 format, the native format of the huge [TASVideos](https://tasvideos.org) NES library. FM2 files only play back deterministically on FCEUX itself, which is why that core was chosen.
- **Wallpaper, not screensaver**: a borderless window per display at the desktop window level (the same technique as Plash), since macOS Sonoma+ broke legacy third-party screensavers and offers no wallpaper API.

ROMs are not included and never will be; point the app at your own.

## Building

Requires Xcode command line tools on Apple Silicon or Intel.

```sh
swift build
```

## Targets

| Target | What it is |
| --- | --- |
| `CFCEUX` | Vendored FCEUX core + headless driver shim behind a C API (`fceux_c.h`) |
| `CShm` | Shared-memory frame transport (`nes_shm.h`) between helpers and the app |
| `nes-headless` | CLI: run a ROM (+ FM2) off-screen, dump PNG frames, benchmark |
| `nes-helper` | One emulator instance publishing frames to shared memory |
| `nes-wallpaper` | The wallpaper app: spawns one helper per tile, renders the grid |

The FCEUX core keeps global state, so the app runs one `nes-helper` process per tile; each publishes 256×240 RGBA frames into a double-buffered POSIX shared-memory segment that the app composites at 60 Hz.

## Installing as an app

```sh
./Scripts/make-app.sh   # builds release and assembles dist/"NES Wallpaper.app"
open "dist/NES Wallpaper.app"
```

The app lives in the menu bar (no Dock icon). Pick your ROM and movie folders in Settings…, and the wallpaper starts automatically on the next launch. It pauses emulation while the screen is locked or the desktop is fully covered, and rotates tiles to new games over time. ROMs with no matching movie join the rotation too, playing their title or attract screen with no input (toggleable in Settings).

Browse TASVideos… lists every current NES publication in FM2 format straight from the [tasvideos.org API](https://tasvideos.org/api) and downloads runs into your movies folder. Each row shows whether a matching ROM (by the checksum in the movie's header) is already in your ROM folder; new movies are picked up the next time the wallpaper starts.

## Trying it

```sh
# Headless smoke test: emulate 300 frames, dump every 60th as PNG
swift build
./.build/out/Products/Debug/nes-headless TestData/nestest.nes --frames 300 --dump-every 60 --out /tmp/frames

# Wallpaper (test ROM + synthetic movie; substitute your own rom:movie pairs)
./.build/out/Products/Debug/nes-wallpaper TestData/nestest.nes:TestData/nestest.fm2

# Library mode: point at folders of ROMs and FM2 movies (e.g. from tasvideos.org).
# Movies are matched to ROMs by the checksum in their header; each tile picks a
# random match, starts at a random mid-movie point, and rotates every 10 minutes.
./.build/out/Products/Debug/nes-wallpaper --grid 4x3 --rotate 600 --roms ~/NES/roms --movies ~/NES/movies
```

`TestData/` contains `nestest.nes` (the standard freely-distributable CPU test ROM) and a generated FM2 that drives its menu, used as an always-available smoke test.
