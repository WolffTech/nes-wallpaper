# Vendored code

## FCEUX core

- Upstream: https://github.com/TASEmulators/fceux
- Pinned commit: `a62b868e9247c4aafd66f597cdfa8d2609704087` (cloned 2026-08-11)
- Vendored copy: `Sources/CFCEUX/fceux/` — a subset of upstream `src/`:
  - Everything in `src/` root, `boards/`, `input/`, `utils/`, `palettes/`
  - `drivers/common/`: only the video filters (vidblit, hq2x/hq3x, scale2x/3x/scalebit, nes_ntsc)
  - Excluded: `drivers/` (Qt/SDL/win frontends), `lua/` + `lua-engine.cpp`, `attic/`,
    `utils/ConvertUTF.c` (unused without libarchive), `fir/` (build-time tool + data)
  - `palettes/conv.cpp` copied but excluded from the build (standalone tool, defines
    duplicate symbols)

### Local modifications

- Added `Sources/CFCEUX/fceux/drivers/sdl/sdl.h` — a stub. `fceu.cpp` unconditionally
  includes a frontend header; this one declares the frontend globals the core
  references (`dendy`, `pal_emulation`, `swapDuty`), which are defined in
  `Sources/CFCEUX/shim/fceux_shim.cpp`.
- `Sources/CFCEUX/fceux/x6502.cpp` removes debugger/test counters from the CPU
  loop, keeping unused per-instruction bookkeeping out of the embedded core.

The shim (`Sources/CFCEUX/shim/`) implements the `FCEUD_*` driver interface headlessly
and exposes the C API in `Sources/CFCEUX/include/fceux_c.h`.

To update: re-clone upstream at a new commit into `vendor/fceux-upstream`, re-run the
same copy (see file set above), rebuild, and update the pin here. The `vendor/fceux-upstream`
clone is scratch space and is not committed.
