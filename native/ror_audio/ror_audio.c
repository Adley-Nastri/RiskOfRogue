/*
 * Risk of Rogue: ror_audio.dll
 * A tiny music player the mod loads with Lua's package.loadlib. It plays .ogg (and .wav/.mp3/.flac)
 * files with fades, crossfades and looping, using miniaudio and stb_vorbis.
 *
 * UE4SS doesn't export the Lua C API, so this library doesn't use it. The mod writes one command
 * line to cmd.txt next to this DLL, then calls ror_audio_cmd(). The result goes to status.txt.
 *
 * Commands (fields separated by single spaces, the path is last and may contain spaces):
 *   play <fade_ms> <loop 0|1> <volume 0..1> <path>   crossfade to this file
 *   stop <fade_ms>                                    fade out whatever is playing
 *   volume <volume 0..1> <fade_ms>                    change the playing track's volume
 *   pair <fade_ms> <loop> <volA> <volB> <pathA>|<pathB>  two tracks started on the same sample
 *                                                     (RoR2 stage song + its teleporter layer)
 *   mix <volA> <volB> <fade_ms>                       fade the pair's two volumes
 *   pause / resume                                    hold and continue, keeping the pair in sync
 *   status                                            just report
 *   info                                              device in use, the game's device, position
 *   devices / device <index|-1>                       list outputs / force one (-1 = follow the game)
 *
 * By default the player follows the game: it plays on the output device where this process (Deadzone)
 * has an active audio session, falling back to the Windows default.
 */
#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include <windows.h>
#include <initguid.h>
#include <mmdeviceapi.h>
#include <audiopolicy.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#define STB_VORBIS_HEADER_ONLY
#include "stb_vorbis.c"
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"
#undef STB_VORBIS_HEADER_ONLY
#include "stb_vorbis.c"

#define SLOTS 4

static ma_engine g_engine;
static int g_engine_ok = 0;
static ma_sound g_sound[SLOTS];
static int g_used[SLOTS];
static int g_cur = -1;
static int g_layer = -1;   /* optional second track that plays in sync with g_cur */
static wchar_t g_dir[MAX_PATH];

static void find_dir(void) {
    HMODULE self = NULL;
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                       (LPCWSTR)&find_dir, &self);
    GetModuleFileNameW(self, g_dir, MAX_PATH);
    wchar_t *slash = wcsrchr(g_dir, L'\\');
    if (slash) slash[1] = 0;
}

static void write_status(const char *msg) {
    wchar_t p[MAX_PATH];
    _snwprintf(p, MAX_PATH, L"%lsstatus.txt", g_dir);
    FILE *f = _wfopen(p, L"wb");
    if (f) { fputs(msg, f); fputs("\n", f); fclose(f); }
}

static int read_cmd(char *buf, int n) {
    wchar_t p[MAX_PATH];
    _snwprintf(p, MAX_PATH, L"%lscmd.txt", g_dir);
    FILE *f = _wfopen(p, L"rb");
    if (!f) return 0;
    int len = (int)fread(buf, 1, n - 1, f);
    fclose(f);
    buf[len] = 0;
    while (len > 0 && (buf[len - 1] == '\n' || buf[len - 1] == '\r' || buf[len - 1] == ' ')) buf[--len] = 0;
    return len;
}

/* free slots whose sound has finished fading out */
static void reap(void) {
    for (int i = 0; i < SLOTS; i++)
        if (g_used[i] && i != g_cur && i != g_layer && !ma_sound_is_playing(&g_sound[i])) {
            ma_sound_uninit(&g_sound[i]);
            g_used[i] = 0;
        }
}

/* Find the output device the game itself is playing on: the render endpoint that has an active
 * audio session belonging to this process (what Windows' Volume Mixer shows). Writes the endpoint
 * id into out (the same id miniaudio's WASAPI backend uses) and its index in the list into *index.
 * Returns 1 if found. */
static int find_game_endpoint(wchar_t *out, int outlen) {
    int found = 0;
    HRESULT hrInit = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    IMMDeviceEnumerator *en = NULL;
    if (FAILED(CoCreateInstance(&CLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL, &IID_IMMDeviceEnumerator, (void **)&en))) goto done;
    IMMDeviceCollection *col = NULL;
    if (FAILED(IMMDeviceEnumerator_EnumAudioEndpoints(en, eRender, DEVICE_STATE_ACTIVE, &col))) goto done_en;
    UINT n = 0; IMMDeviceCollection_GetCount(col, &n);
    DWORD me = GetCurrentProcessId();
    for (UINT i = 0; i < n && !found; i++) {
        IMMDevice *dev = NULL;
        if (FAILED(IMMDeviceCollection_Item(col, i, &dev))) continue;
        IAudioSessionManager2 *mgr = NULL;
        if (SUCCEEDED(IMMDevice_Activate(dev, &IID_IAudioSessionManager2, CLSCTX_ALL, NULL, (void **)&mgr))) {
            IAudioSessionEnumerator *se = NULL;
            if (SUCCEEDED(IAudioSessionManager2_GetSessionEnumerator(mgr, &se))) {
                int cnt = 0; IAudioSessionEnumerator_GetCount(se, &cnt);
                for (int k = 0; k < cnt && !found; k++) {
                    IAudioSessionControl *c = NULL;
                    if (FAILED(IAudioSessionEnumerator_GetSession(se, k, &c))) continue;
                    IAudioSessionControl2 *c2 = NULL;
                    if (SUCCEEDED(IAudioSessionControl_QueryInterface(c, &IID_IAudioSessionControl2, (void **)&c2))) {
                        DWORD pid = 0; AudioSessionState st = AudioSessionStateInactive;
                        IAudioSessionControl2_GetProcessId(c2, &pid);
                        IAudioSessionControl_GetState(c, &st);
                        if (pid == me && st == AudioSessionStateActive) {
                            LPWSTR id = NULL;
                            if (SUCCEEDED(IMMDevice_GetId(dev, &id))) { wcsncpy(out, id, outlen - 1); out[outlen - 1] = 0; CoTaskMemFree(id); found = 1; }
                        }
                        IAudioSessionControl2_Release(c2);
                    }
                    IAudioSessionControl_Release(c);
                }
                IAudioSessionEnumerator_Release(se);
            }
            IAudioSessionManager2_Release(mgr);
        }
        IMMDevice_Release(dev);
    }
    IMMDeviceCollection_Release(col);
done_en:
    IMMDeviceEnumerator_Release(en);
done:
    if (SUCCEEDED(hrInit)) CoUninitialize();
    return found;
}

static wchar_t g_game_dev[256];
static int g_follow = 1;   /* follow the game's output device (default) */

static ma_context g_ctx;
static int g_ctx_ok = 0;
static ma_device_info *g_pb = NULL;
static ma_uint32 g_pbn = 0;
static int g_dev_index = -1;   /* -1 = system default */

static int ensure_context(void) {
    if (g_ctx_ok) return 1;
    if (ma_context_init(NULL, 0, NULL, &g_ctx) != MA_SUCCESS) return 0;
    g_ctx_ok = 1;
    return 1;
}

static int ensure_engine(char *err) {
    if (g_engine_ok) return 1;
    ma_engine_config cfg = ma_engine_config_init();
    cfg.channels = 2;   /* stereo music; Windows mixes it to whatever the speakers are */
    if (ensure_context()) {
        cfg.pContext = &g_ctx;
        ma_context_get_devices(&g_ctx, &g_pb, &g_pbn, NULL, NULL);
        if (g_dev_index >= 0 && (ma_uint32)g_dev_index < g_pbn) cfg.pPlaybackDeviceID = &g_pb[g_dev_index].id;
        else if (g_follow && find_game_endpoint(g_game_dev, 256)) {
            for (ma_uint32 i = 0; i < g_pbn; i++)
                if (wcscmp(g_pb[i].id.wasapi, g_game_dev) == 0) { cfg.pPlaybackDeviceID = &g_pb[i].id; break; }
        }
    }
    ma_result r = ma_engine_init(&cfg, &g_engine);
    if (r != MA_SUCCESS) { sprintf(err, "error engine init failed (%d)", r); return 0; }
    g_engine_ok = 1;
    return 1;
}

static void fade_out_slot(int i, ma_uint64 ms) {
    if (i >= 0 && g_used[i]) {
        if (ms > 0) ma_sound_stop_with_fade_in_milliseconds(&g_sound[i], ms);
        else ma_sound_stop(&g_sound[i]);
    }
}
static void fade_out_current(ma_uint64 ms) {
    fade_out_slot(g_cur, ms);
    fade_out_slot(g_layer, ms);
    g_cur = -1;
    g_layer = -1;
}

static int free_slot(void) {
    for (int i = 0; i < SLOTS; i++) if (!g_used[i]) return i;
    for (int i = 0; i < SLOTS; i++) if (i != g_cur && i != g_layer) { ma_sound_uninit(&g_sound[i]); g_used[i] = 0; return i; }
    return -1;
}

static int open_slot(const char *path, int loop, char *msg, int msglen) {
    wchar_t wpath[MAX_PATH * 2];
    MultiByteToWideChar(CP_UTF8, 0, path, -1, wpath, MAX_PATH * 2);
    int slot = free_slot();
    if (slot < 0) { snprintf(msg, msglen, "error no free slot"); return -1; }
    ma_result r = ma_sound_init_from_file_w(&g_engine, wpath, MA_SOUND_FLAG_STREAM | MA_SOUND_FLAG_NO_SPATIALIZATION, NULL, NULL, &g_sound[slot]);
    if (r != MA_SUCCESS) { snprintf(msg, msglen, "error cannot open (%d) %s", r, path); return -1; }
    g_used[slot] = 1;
    ma_sound_set_looping(&g_sound[slot], loop ? MA_TRUE : MA_FALSE);
    return slot;
}

static void fade_to(int i, float vol, unsigned ms) {
    if (i < 0 || !g_used[i]) return;
    ma_sound_set_fade_in_milliseconds(&g_sound[i], ms > 0 ? -1.0f : vol, vol, ms);
}

__declspec(dllexport) int ror_audio_cmd(void *lua_state) {
    (void)lua_state;
    char cmd[2048], msg[2300];
    if (!g_dir[0]) find_dir();
    if (!read_cmd(cmd, sizeof cmd)) { write_status("error no cmd.txt"); return 0; }
    if (!ensure_engine(msg)) { write_status(msg); return 0; }
    reap();

    if (strncmp(cmd, "play ", 5) == 0) {
        unsigned fade = 0; int loop = 0; float vol = 1.0f; int used = 0;
        if (sscanf(cmd + 5, "%u %d %f %n", &fade, &loop, &vol, &used) < 3 || !cmd[5 + used]) { write_status("error bad play command"); return 0; }
        const char *path = cmd + 5 + used;
        wchar_t wpath[MAX_PATH * 2];
        MultiByteToWideChar(CP_UTF8, 0, path, -1, wpath, MAX_PATH * 2);
        int slot = -1;
        for (int i = 0; i < SLOTS; i++) if (!g_used[i]) { slot = i; break; }
        if (slot < 0) { /* all busy: drop the oldest that isn't current */
            for (int i = 0; i < SLOTS; i++) if (i != g_cur) { ma_sound_uninit(&g_sound[i]); g_used[i] = 0; slot = i; break; }
        }
        ma_result r = ma_sound_init_from_file_w(&g_engine, wpath, MA_SOUND_FLAG_STREAM | MA_SOUND_FLAG_NO_SPATIALIZATION, NULL, NULL, &g_sound[slot]);
        if (r != MA_SUCCESS) { snprintf(msg, sizeof msg, "error cannot open (%d) %s", r, path); write_status(msg); return 0; }
        g_used[slot] = 1;
        ma_sound_set_looping(&g_sound[slot], loop ? MA_TRUE : MA_FALSE);
        fade_out_current(fade);
        /* volume lives only in the fader (miniaudio multiplies sound volume and fader) */
        ma_sound_set_volume(&g_sound[slot], 1.0f);
        ma_sound_set_fade_in_milliseconds(&g_sound[slot], fade > 0 ? 0.0f : vol, vol, fade);
        ma_sound_start(&g_sound[slot]);
        g_cur = slot;
        snprintf(msg, sizeof msg, "ok playing %s", path);
        write_status(msg);
    } else if (strncmp(cmd, "pair ", 5) == 0) {
        /* pair <fade_ms> <loop> <volA> <volB> <pathA>|<pathB> : two tracks started on the same sample */
        unsigned fade = 0; int loop = 0; float va = 1.0f, vb = 0.0f; int used = 0;
        if (sscanf(cmd + 5, "%u %d %f %f %n", &fade, &loop, &va, &vb, &used) < 4) { write_status("error bad pair command"); return 0; }
        char *pa = cmd + 5 + used, *pb = strchr(pa, '|');
        if (!pb) { write_status("error pair needs pathA|pathB"); return 0; }
        *pb++ = 0;
        fade_out_current(fade);
        int a = open_slot(pa, loop, msg, sizeof msg); if (a < 0) { write_status(msg); return 0; }
        int b = open_slot(pb, loop, msg, sizeof msg); if (b < 0) { ma_sound_uninit(&g_sound[a]); g_used[a] = 0; write_status(msg); return 0; }
        ma_sound_set_volume(&g_sound[a], 1.0f);
        ma_sound_set_volume(&g_sound[b], 1.0f);
        ma_sound_set_fade_in_milliseconds(&g_sound[a], fade > 0 ? 0.0f : va, va, fade);
        ma_sound_set_fade_in_milliseconds(&g_sound[b], fade > 0 ? 0.0f : vb, vb, fade);
        /* schedule both on the same engine frame so they stay sample-locked */
        ma_uint64 t = ma_engine_get_time_in_pcm_frames(&g_engine) + ma_engine_get_sample_rate(&g_engine) / 10;
        ma_sound_set_start_time_in_pcm_frames(&g_sound[a], t);
        ma_sound_set_start_time_in_pcm_frames(&g_sound[b], t);
        ma_sound_start(&g_sound[a]);
        ma_sound_start(&g_sound[b]);
        g_cur = a; g_layer = b;
        snprintf(msg, sizeof msg, "ok pair %s | %s", pa, pb);
        write_status(msg);
    } else if (strncmp(cmd, "mix ", 4) == 0) {
        /* mix <volA> <volB> <fade_ms> : change the two tracks' volumes (B = the layer) */
        float va = 1.0f, vb = 0.0f; unsigned fade = 0;
        sscanf(cmd + 4, "%f %f %u", &va, &vb, &fade);
        fade_to(g_cur, va, fade);
        fade_to(g_layer, vb, fade);
        write_status("ok mix");
    } else if (strncmp(cmd, "pause", 5) == 0) {
        if (g_cur >= 0) ma_sound_stop(&g_sound[g_cur]);
        if (g_layer >= 0) ma_sound_stop(&g_sound[g_layer]);
        write_status("ok paused");
    } else if (strncmp(cmd, "resume", 6) == 0) {
        ma_uint64 t = ma_engine_get_time_in_pcm_frames(&g_engine) + ma_engine_get_sample_rate(&g_engine) / 20;
        if (g_cur >= 0) { ma_sound_set_start_time_in_pcm_frames(&g_sound[g_cur], t); ma_sound_start(&g_sound[g_cur]); }
        if (g_layer >= 0) { ma_sound_set_start_time_in_pcm_frames(&g_sound[g_layer], t); ma_sound_start(&g_sound[g_layer]); }
        write_status("ok resumed");
    } else if (strncmp(cmd, "stop", 4) == 0) {
        unsigned fade = 0;
        sscanf(cmd + 4, " %u", &fade);
        fade_out_current(fade);
        write_status("ok stopped");
    } else if (strncmp(cmd, "volume ", 7) == 0) {
        float vol = 1.0f; unsigned fade = 0;
        sscanf(cmd + 7, "%f %u", &vol, &fade);
        if (g_cur >= 0) ma_sound_set_fade_in_milliseconds(&g_sound[g_cur], -1.0f, vol, fade);
        write_status("ok volume");
    } else if (strncmp(cmd, "devices", 7) == 0) {
        int n = 0;
        if (ensure_context()) ma_context_get_devices(&g_ctx, &g_pb, &g_pbn, NULL, NULL);
        n = snprintf(msg, sizeof msg, "ok %u playback devices:", g_pbn);
        for (ma_uint32 i = 0; i < g_pbn && n < (int)sizeof msg - 120; i++)
            n += snprintf(msg + n, sizeof msg - n, " [%u]%s%s", i, g_pb[i].name, g_pb[i].isDefault ? "(default)" : "");
        write_status(msg);
    } else if (strncmp(cmd, "device ", 7) == 0) {
        /* switch output device: restart the engine on device <index> (-1 = default) */
        int idx = -1; sscanf(cmd + 7, "%d", &idx);
        for (int i = 0; i < SLOTS; i++) if (g_used[i]) { ma_sound_uninit(&g_sound[i]); g_used[i] = 0; }
        g_cur = -1;
        if (g_engine_ok) { ma_engine_uninit(&g_engine); g_engine_ok = 0; }
        g_dev_index = idx;
        g_follow = (idx < 0);
        if (ensure_engine(msg)) snprintf(msg, sizeof msg, "ok device set to %d", idx);
        write_status(msg);
    } else if (strncmp(cmd, "info", 4) == 0) {
        ma_device *dev = ma_engine_get_device(&g_engine);
        char name[256] = "?";
        if (dev) ma_device_get_name(dev, ma_device_type_playback, name, sizeof name, NULL);
        float cur = 0, len = 0;
        if (g_cur >= 0) { ma_sound_get_cursor_in_seconds(&g_sound[g_cur], &cur); ma_sound_get_length_in_seconds(&g_sound[g_cur], &len); }
        wchar_t gd[256] = L""; char gdn[256] = "none";
        if (find_game_endpoint(gd, 256) && ensure_context()) {
            ma_context_get_devices(&g_ctx, &g_pb, &g_pbn, NULL, NULL);
            for (ma_uint32 i = 0; i < g_pbn; i++) if (wcscmp(g_pb[i].id.wasapi, gd) == 0) { snprintf(gdn, sizeof gdn, "%s", g_pb[i].name); break; }
        }
        snprintf(msg, sizeof msg, "ok game_device=\"%s\" device=\"%s\" backend=%s rate=%u channels=%u engine_volume=%.2f playing=%d cursor=%.2f/%.2f",
                 gdn, name, dev ? ma_get_backend_name(dev->pContext->backend) : "?", ma_engine_get_sample_rate(&g_engine),
                 ma_engine_get_channels(&g_engine), ma_engine_get_volume(&g_engine),
                 (g_cur >= 0 && ma_sound_is_playing(&g_sound[g_cur])) ? 1 : 0, cur, len);
        write_status(msg);
    } else if (strncmp(cmd, "status", 6) == 0) {
        snprintf(msg, sizeof msg, "ok %s", (g_cur >= 0 && ma_sound_is_playing(&g_sound[g_cur])) ? "playing" : "idle");
        write_status(msg);
    } else {
        snprintf(msg, sizeof msg, "error unknown command: %.100s", cmd);
        write_status(msg);
    }
    return 0;
}

BOOL WINAPI DllMain(HINSTANCE h, DWORD reason, LPVOID r) { (void)h; (void)reason; (void)r; return TRUE; }
