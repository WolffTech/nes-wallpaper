#ifndef FCEUX_C_H
#define FCEUX_C_H

#ifdef __cplusplus
extern "C" {
#endif

/* Minimal C facade over the FCEUX core for embedding.
   The core is global-state: one emulator instance per process. */

typedef void (*fceux_log_fn)(const char *msg, int is_error);

/* One-time process init. base_dir receives FCEUX support files (saves, etc). */
int fceux_init(const char *base_dir);

int fceux_load_game(const char *rom_path);
void fceux_close_game(void);

/* Begin read-only playback of an FM2 movie. Requires a loaded game. */
int fceux_load_movie(const char *fm2_path);
void fceux_stop_movie(void);
int fceux_movie_is_playing(void);
int fceux_movie_frame(void);

/* Buttons bitmask: A=1 B=2 Select=4 Start=8 Up=16 Down=32 Left=64 Right=128 */
void fceux_set_joypad(int pad, unsigned char buttons);

/* Select the CPU video filter (FCEUX vidblit). specfilt: 0 none, 1 hq2x,
   2 scale2x, 3 NTSC 2x, 4 hq3x, 5 scale3x. specfilteropt (NTSC only):
   0 composite, 1 svideo, 2 rgb, 3 monochrome. Call after fceux_load_game
   and before the first fceux_run_frame; re-callable (re-inits vidblit).
   Changes fceux_frame_width/height. Returns 1 on success, 0 on failure. */
int fceux_set_video_filter(int specfilt, int specfilteropt);

/* Emulate one frame. Returns pointer to an internal BGRX8888 buffer
   (bytes B,G,R,X in memory; X undefined — treat as opaque), sized
   fceux_frame_width x fceux_frame_height, tightly packed (pitch ==
   width * 4). Valid until the next call. */
const unsigned char *fceux_run_frame(int skip_render);

/* Filter-dependent: 256x240 raw, 602x480 NTSC, 512x480 2x, 768x720 3x. */
int fceux_frame_width(void);
int fceux_frame_height(void);

/* Save-state to/from memory, for checkpointing. Returns byte count, 0 on error.
   fceux_state_save with buf == NULL returns the required size. */
long fceux_state_save(unsigned char *buf, long capacity);
int fceux_state_load(const unsigned char *buf, long size);

void fceux_set_log_fn(fceux_log_fn fn);

#ifdef __cplusplus
}
#endif

#endif /* FCEUX_C_H */
