# NES Wallpaper

A modern macOS recreation of the 2016 UberNES "Nintendo Saver": a live desktop wallpaper that tiles NES games playing back tool-assisted speedrun (TAS) movies, rendered behind your desktop icons.

The original (`Nintendo Saver.saver`, kept in this repo for reference) was an x86_64 screensaver built on the UberNES emulator and its proprietary movie format. This project replaces both halves with maintained equivalents:

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

## Trying it

```sh
# Headless smoke test: emulate 300 frames, dump every 60th as PNG
swift build
./.build/out/Products/Debug/nes-headless TestData/nestest.nes --frames 300 --dump-every 60 --out /tmp/frames

# Wallpaper (test ROM + synthetic movie; substitute your own rom:movie pairs)
./.build/out/Products/Debug/nes-wallpaper TestData/nestest.nes:TestData/nestest.fm2
```

`TestData/` contains `nestest.nes` (the standard freely-distributable CPU test ROM) and a generated FM2 that drives its menu, used as an always-available smoke test.
