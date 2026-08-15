// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-2.0-only

#ifndef NES_SHM_H
#define NES_SHM_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Shared-memory frame transport between a nes-helper emulator process
   (writer) and its readers: the wallpaper app, and the screensaver
   plugin. The segment is a plain mmapped file (not POSIX shm) so the
   sandboxed screensaver can open it read-only; any number of concurrent
   read-only mappings is fine.

   Double-buffered: the writer fills buffer `back`, then publishes it by
   storing the buffer index into `front` (release). The reader loads
   `front` (acquire) and reads that buffer. A frame may be skipped or
   shown twice under scheduling jitter; it is never torn.

   v2: frame dimensions are runtime fields chosen by the writer (they
   depend on the video filter: 256x240 raw, 602x480 NTSC, up to 768x720
   hq3x/scale3x). Two BGRX8888 buffers (bytes B,G,R,X in memory; the X
   byte is undefined — treat as opaque) follow immediately after the
   header, each width*height*4 bytes, tightly packed (pitch == width*4). */

#define NES_SHM_MAGIC   0x4E455331u /* "NES1" */
#define NES_SHM_VERSION 2u
#define NES_SHM_MAX_WIDTH  768u
#define NES_SHM_MAX_HEIGHT 720u

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t width;  /* set by the writer before magic appears */
    uint32_t height;
    uint32_t pitch;  /* always width * 4 */

    /* Written by the helper, read by the app. Use the nes_shm_load/store
       helpers below; Swift cannot express C11 atomics directly. */
    volatile uint32_t front;         /* 0 or 1: last completed buffer */
    volatile uint32_t frame_count;   /* frames published since start */
    volatile uint32_t movie_playing; /* 1 while an FM2 is driving input */
    volatile uint32_t movie_frame;   /* current movie frame index */

    /* pixel buffers follow immediately after the struct */
} nes_shm_t;

static inline uint32_t nes_shm_load(const volatile uint32_t *p) {
    return __atomic_load_n(p, __ATOMIC_ACQUIRE);
}

static inline void nes_shm_store(volatile uint32_t *p, uint32_t v) {
    __atomic_store_n(p, v, __ATOMIC_RELEASE);
}

static inline size_t nes_shm_pix_bytes(uint32_t width, uint32_t height) {
    return (size_t)width * height * 4u;
}

static inline size_t nes_shm_total_size(uint32_t width, uint32_t height) {
    return sizeof(nes_shm_t) + 2u * nes_shm_pix_bytes(width, height);
}

/* Start of pixel buffer `idx` (0 or 1). Shared by writer and reader so
   the layout lives in exactly one place. */
static inline uint8_t *nes_shm_pixels(nes_shm_t *shm, uint32_t idx) {
    return (uint8_t *)(shm + 1) + (size_t)idx * nes_shm_pix_bytes(shm->width, shm->height);
}

/* Create (writer) or open (reader) a mapping. Names are filesystem
   paths in a directory that already exists, e.g.
   "/Users/Shared/NESWallpaper/tiles/nes.12345.0.frame". The writer maps
   read-write; nes_shm_open maps read-only. Returns NULL on failure. The
   creator unlinks the file on nes_shm_close; existing mappings (and the
   pages behind them) survive until every side unmaps. */
nes_shm_t *nes_shm_create(const char *path, uint32_t width, uint32_t height);
nes_shm_t *nes_shm_open(const char *path);
void nes_shm_close(nes_shm_t *shm, const char *path, int is_creator);

#ifdef __cplusplus
}
#endif

#endif /* NES_SHM_H */
