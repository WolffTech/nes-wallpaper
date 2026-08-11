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
static uint8 s_palette[256][3];
static uint32 s_joypad_data = 0; // 4 pads, one byte each
static std::vector<unsigned char> s_rgba(256 * 240 * 4);

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
	FCEUI_Sound(44100);
	FCEUI_SetInput(0, SI_GAMEPAD, &s_joypad_data, 0);
	FCEUI_SetInput(1, SI_GAMEPAD, &s_joypad_data, 0);
	FCEUI_SetInputFC(SIFC_NONE, nullptr, 0);
	FCEUI_SetInputFourscore(false);
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

const unsigned char *fceux_run_frame(int skip_render) {
	uint8 *gfx = nullptr;
	int32 *sound = nullptr;
	int32 ssize = 0;
	FCEUI_Emulate(&gfx, &sound, &ssize, skip_render ? 1 : 0);
	if (skip_render || !gfx)
		return nullptr;
	// XBuf is 8-bit palette-indexed, stride 256.
	unsigned char *out = s_rgba.data();
	for (int y = 0; y < 240; y++) {
		const uint8 *row = gfx + y * 256;
		for (int x = 0; x < 256; x++) {
			const uint8 idx = row[x];
			*out++ = s_palette[idx][0];
			*out++ = s_palette[idx][1];
			*out++ = s_palette[idx][2];
			*out++ = 0xFF;
		}
	}
	return s_rgba.data();
}

int fceux_frame_width(void) { return 256; }
int fceux_frame_height(void) { return 240; }

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
	return FCEUSS_LoadFP(&mem, SSLOADPARAM_NOBACKUP) ? 1 : 0;
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
	s_palette[index][0] = r;
	s_palette[index][1] = g;
	s_palette[index][2] = b;
}

void FCEUD_GetPalette(uint8 index, uint8 *r, uint8 *g, uint8 *b) {
	*r = s_palette[index][0];
	*g = s_palette[index][1];
	*b = s_palette[index][2];
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
