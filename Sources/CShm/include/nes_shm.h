#ifndef NES_SHM_H
#define NES_SHM_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Shared-memory frame transport between a nes-helper emulator process
   (writer) and the wallpaper app (reader).

   Double-buffered: the writer fills pixels[back], then publishes it by
   storing the buffer index into `front` (release). The reader loads
   `front` (acquire) and reads that buffer. A frame may be skipped or
   shown twice under scheduling jitter; it is never torn. */

#define NES_SHM_MAGIC   0x4E455331u /* "NES1" */
#define NES_SHM_VERSION 1u
#define NES_SHM_WIDTH   256u
#define NES_SHM_HEIGHT  240u
#define NES_SHM_PIXBYTES (NES_SHM_WIDTH * NES_SHM_HEIGHT * 4u)

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t width;  /* NES_SHM_WIDTH */
    uint32_t height; /* NES_SHM_HEIGHT */

    /* Written by the helper, read by the app. Use the nes_shm_load/store
       helpers below; Swift cannot express C11 atomics directly. */
    volatile uint32_t front;         /* 0 or 1: last completed buffer */
    volatile uint32_t frame_count;   /* frames emulated since start */
    volatile uint32_t movie_playing; /* 1 while an FM2 is driving input */
    volatile uint32_t movie_frame;   /* current movie frame index */

    uint8_t pixels[2][NES_SHM_PIXBYTES]; /* RGBA8888, tightly packed */
} nes_shm_t;

static inline uint32_t nes_shm_load(const volatile uint32_t *p) {
    return __atomic_load_n(p, __ATOMIC_ACQUIRE);
}

static inline void nes_shm_store(volatile uint32_t *p, uint32_t v) {
    __atomic_store_n(p, v, __ATOMIC_RELEASE);
}

/* Create (writer) or open (reader) a mapping. Names must start with '/'
   and stay under 31 chars (macOS PSHMNAMLEN), e.g. "/nes.12345.0".
   Returns NULL on failure. The creator unlinks the name on nes_shm_close,
   so the segment disappears when both sides unmap. */
nes_shm_t *nes_shm_create(const char *name);
nes_shm_t *nes_shm_open(const char *name);
void nes_shm_close(nes_shm_t *shm, const char *name, int is_creator);

#ifdef __cplusplus
}
#endif

#endif /* NES_SHM_H */
