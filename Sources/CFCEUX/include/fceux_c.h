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

/* Emulate one frame. Returns pointer to an internal RGBA8888 buffer,
   256 wide by 240 high, tightly packed. Valid until the next call. */
const unsigned char *fceux_run_frame(int skip_render);

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
