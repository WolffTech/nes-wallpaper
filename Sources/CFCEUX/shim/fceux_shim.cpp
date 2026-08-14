// C facade + driver-interface implementation for embedding the FCEUX core.
// FCEUX expects its "driver" (normally the Qt frontend) to provide FCEUD_*
// functions; this file supplies headless implementations.

#include <cstdio>
#include <cstdarg>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <chrono>

#include "types.h"
#include "driver.h"
#include "fceu.h"
#include "file.h"
#include "movie.h"
#include "state.h"
#include "emufile.h"
#include "video.h"
#include "drivers/common/vidblit.h"

#include "fceux_c.h"

// Frontend globals the core links against (normally owned by the Qt driver).
int pal_emulation = 0;
bool swapDuty = false;
int dendy = 0;
int eoptions = 0;
int closeFinishedMovie = 0;
int KillFCEUXonFrame = 0;
bool turbo = false;

static fceux_log_fn s_log_fn = nullptr;
// 4-byte stride: the layout SetPaletteBlitToHigh expects (reads src[i<<2 .. +2]).
static uint8 s_palette4[256][4];
static int s_paletterefresh = 0;
static uint32 s_joypad_data = 0; // 4 pads, one byte each

// vidblit output state, set by fceux_set_video_filter.
static std::vector<unsigned char> s_out;
static int s_out_w = 0, s_out_h = 0;
static int s_xscale = 1, s_yscale = 1;
static bool s_blit_inited = false;

static void shim_log(const char *msg, int is_error) {
	if (s_log_fn)
		s_log_fn(msg, is_error);
	else
		fprintf(stderr, "[fceux] %s\n", msg);
}

// ---------------------------------------------------------------------------
// C API
// ---------------------------------------------------------------------------

extern "C" {

void fceux_set_log_fn(fceux_log_fn fn) { s_log_fn = fn; }

int fceux_init(const char *base_dir) {
	if (!FCEUI_Initialize())
		return 0;
	FCEUI_SetBaseDirectory(base_dir ? base_dir : "/tmp");
	FCEUI_SetVidSystem(0); // NTSC
	FCEUI_Sound(0);
	FCEUI_SetInput(0, SI_GAMEPAD, &s_joypad_data, 0);
	FCEUI_SetInput(1, SI_GAMEPAD, &s_joypad_data, 0);
	FCEUI_SetInputFC(SIFC_NONE, nullptr, 0);
	FCEUI_SetInputFourscore(false);
	// vidblit is the only output path, even unfiltered: it applies the
	// deemphasis map (XDBuf) the old hand-rolled palette loop dropped.
	return fceux_set_video_filter(0, 0);
}

int fceux_set_video_filter(int specfilt, int specfilteropt) {
	int w, h, xscale, yscale;
	switch (specfilt) {
	case 0: w = 256; h = 240; xscale = 1; yscale = 1; break; // none
	case 1: case 2: w = 512; h = 480; xscale = 2; yscale = 2; break; // hq2x, scale2x
	case 3: w = 602; h = 480; xscale = 2; yscale = 2; break; // NTSC (2 * 301)
	case 4: case 5: w = 768; h = 720; xscale = 3; yscale = 3; break; // hq3x, scale3x
	default: return 0;
	}
	if (specfilt == 3 && (specfilteropt < 0 || specfilteropt > 3))
		return 0;
	if (s_blit_inited)
		KillBlitToHigh();
	s_blit_inited = false;
	// b=4 only: nes_ntsc_out_t is hardcoded to 32-bit. These masks make
	// every path emit 0x00RRGGBB words = B,G,R,X bytes in memory (BGRX).
	// Init BEFORE the palette: hq2x/hq3x rewrite masks/Bpp internally.
	if (!InitBlitToHigh(4, 0x00FF0000u, 0x0000FF00u, 0x000000FFu, 0,
	                    specfilt, specfilteropt))
		return 0;
	s_blit_inited = true;
	s_out.assign((size_t)w * h * 4, 0);
	s_out_w = w;
	s_out_h = h;
	s_xscale = xscale;
	s_yscale = yscale;
	s_paletterefresh = 1;
	return 1;
}

int fceux_load_game(const char *rom_path) {
	return FCEUI_LoadGame(rom_path, 1, true) != nullptr;
}

void fceux_close_game(void) { FCEUI_CloseGame(); }

int fceux_load_movie(const char *fm2_path) {
	return FCEUI_LoadMovie(fm2_path, true, 0);
}

void fceux_stop_movie(void) { FCEUI_StopMovie(); }

int fceux_movie_is_playing(void) { return FCEUMOV_Mode(MOVIEMODE_PLAY) ? 1 : 0; }

int fceux_movie_frame(void) { return currFrameCounter; }

void fceux_set_joypad(int pad, unsigned char buttons) {
	if (pad < 0 || pad > 3) return;
	uint32 shift = 8u * (uint32)pad;
	s_joypad_data = (s_joypad_data & ~(0xFFu << shift)) | ((uint32)buttons << shift);
}

static int emulate_frame(unsigned char *dest, int pitch, bool convert_output) {
	if (convert_output && (!dest || pitch < s_out_w * 4))
		return 0;
	uint8 *gfx = nullptr;
	int32 *sound = nullptr;
	int32 ssize = 0;
	// Always use the exact PPU path. Fast-forward and low-power playback skip
	// only the comparatively expensive output color conversion.
	FCEUI_Emulate(&gfx, &sound, &ssize, 0);
	if (!convert_output || !gfx || !s_blit_inited)
		return 0;
	if (s_paletterefresh) {
		SetPaletteBlitToHigh(&s_palette4[0][0]);
		s_paletterefresh = 0;
	}
	// gfx is XBuf itself. Blit8ToHigh needs the real XBuf pointer: it
	// locates the parallel deemphasis plane (XDBuf) via src - XBuf.
	Blit8ToHigh(gfx, dest, 256, 240, pitch, s_xscale, s_yscale);
	return 1;
}

const unsigned char *fceux_run_frame(int skip_render) {
	if (!emulate_frame(s_out.data(), s_out_w * 4, skip_render == 0))
		return nullptr;
	return s_out.data();
}

int fceux_run_frame_into(unsigned char *bgrx, int pitch) {
	return emulate_frame(bgrx, pitch, true);
}

int fceux_frame_width(void) { return s_out_w; }
int fceux_frame_height(void) { return s_out_h; }

long fceux_state_save(unsigned char *buf, long capacity) {
	std::vector<u8> vec;
	EMUFILE_MEMORY mem(&vec);
	if (!FCEUSS_SaveMS(&mem, -1))
		return 0;
	if (!buf)
		return (long)vec.size();
	if ((long)vec.size() > capacity)
		return 0;
	memcpy(buf, vec.data(), vec.size());
	return (long)vec.size();
}

int fceux_state_load(const unsigned char *buf, long size) {
	std::vector<u8> vec(buf, buf + size);
	EMUFILE_MEMORY mem(&vec);
	// BACKUP matches FCEUX's own movie-savestate path (movie.cpp): if the
	// load is rejected (GUID/timeline mismatch, post-movie state), the core
	// rolls back instead of being left half-loaded.
	return FCEUSS_LoadFP(&mem, SSLOADPARAM_BACKUP) ? 1 : 0;
}

} // extern "C"

// ---------------------------------------------------------------------------
// FCEUD_* driver interface
// ---------------------------------------------------------------------------

FILE *FCEUD_UTF8fopen(const char *fn, const char *mode) { return fopen(fn, mode); }

EMUFILE_FILE *FCEUD_UTF8_fstream(const char *n, const char *m) {
	std::string mode = m;
	if (mode.find('b') == std::string::npos)
		mode += 'b';
	return new EMUFILE_FILE(n, mode.c_str());
}

// No archive (zip) support in the embedded build; ROMs are plain files.
FCEUFILE *FCEUD_OpenArchiveIndex(ArchiveScanRecord &, std::string &, int) { return nullptr; }
FCEUFILE *FCEUD_OpenArchiveIndex(ArchiveScanRecord &, std::string &, int, int *) { return nullptr; }
FCEUFILE *FCEUD_OpenArchive(ArchiveScanRecord &, std::string &, std::string *) { return nullptr; }
FCEUFILE *FCEUD_OpenArchive(ArchiveScanRecord &, std::string &, std::string *, int *) { return nullptr; }
ArchiveScanRecord FCEUD_ScanArchive(std::string) { return ArchiveScanRecord(); }

const char *FCEUD_GetCompilerString() { return "clang (embedded)"; }

void FCEUD_SetPalette(uint8 index, uint8 r, uint8 g, uint8 b) {
	s_palette4[index][0] = r;
	s_palette4[index][1] = g;
	s_palette4[index][2] = b;
	// Deferred into fceux_run_frame: palette callbacks fire during
	// FCEUI_LoadGame, possibly before InitBlitToHigh has run.
	s_paletterefresh = 1;
}

void FCEUD_GetPalette(uint8 index, uint8 *r, uint8 *g, uint8 *b) {
	*r = s_palette4[index][0];
	*g = s_palette4[index][1];
	*b = s_palette4[index][2];
}

void FCEUD_PrintError(const char *s) { shim_log(s, 1); }
void FCEUD_Message(const char *s) { shim_log(s, 0); }

// Netplay: disabled.
int FCEUD_SendData(void *, uint32) { return 0; }
int FCEUD_RecvData(void *, uint32) { return 0; }
void FCEUD_NetplayText(uint8 *) {}
void FCEUD_NetworkClose(void) {}

uint64 FCEUD_GetTime(void) {
	return (uint64)std::chrono::steady_clock::now().time_since_epoch().count();
}
uint64 FCEUD_GetTimeFreq(void) {
	using period = std::chrono::steady_clock::period;
	return (uint64)(period::den / period::num);
}

void FCEUD_SoundToggle(void) {}
void FCEUD_SoundVolumeAdjust(int) {}

void FCEUD_SaveStateAs(void) {}
void FCEUD_LoadStateFrom(void) {}
void FCEUD_MovieRecordTo(void) {}
void FCEUD_MovieReplayFrom(void) {}
void FCEUD_LuaRunFrom(void) {}

void FCEUD_SetInput(bool, bool, ESI, ESI, ESIFC) {}

bool FCEUD_ShouldDrawInputAids() { return false; }
void FCEUD_OnCloseGame(void) {}

void FCEUD_AviRecordTo(void) {}
void FCEUD_AviStop(void) {}

void FCEUD_SetEmulationSpeed(int) {}
void FCEUD_TurboOn(void) {}
void FCEUD_TurboOff(void) {}
void FCEUD_TurboToggle(void) {}

int FCEUD_ShowStatusIcon(void) { return 0; }
void FCEUD_ToggleStatusIcon(void) {}
void FCEUD_HideMenuToggle(void) {}
void FCEUD_CmdOpen(void) {}

void FCEUD_DebugBreakpoint(int) {}
void FCEUD_TraceInstruction(uint8 *, int) {}
void FCEUD_FlushTrace() {}
void FCEUD_UpdateNTView(int, bool) {}
void FCEUD_UpdatePPUView(int, int) {}

bool FCEUD_PauseAfterPlayback() { return false; }
void FCEUD_VideoChanged() {}

// AVI recording is a driver feature; disabled in the embedded build.
bool FCEUI_AviIsRecording() { return false; }
void FCEUI_AviVideoUpdate(const unsigned char *) {}
bool FCEUI_AviEnableHUDrecording() { return false; }
bool FCEUI_AviDisableMovieMessages() { return true; }
void FCEUI_UseInputPreset(int) {}

// Non-FCEUD driver hooks referenced by a few boards / region switching.
static unsigned int s_keyboard[256];
unsigned int *GetKeyboard(void) { return s_keyboard; }
void GetMouseData(uint32 (&md)[3]) { md[0] = md[1] = md[2] = 0; }
void RefreshThrottleFPS() {}
