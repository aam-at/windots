/*
 * Win+S dictation recorder. It starts recording the microphone to
 * %LOCALAPPDATA%\windots\dictation\recording.raw (16 kHz mono s16le) on one press and
 * stops on the next, after which scripts\Toggle-Dictation.ps1 transcribes the
 * recording and delivers the text. Native so the chime follows the press quickly:
 * pwsh takes 0.3 s to start and ffmpeg's DirectShow 1 s to open the mic.
 *
 *   dictate [--pid N]   start the recorder, which stays resident. N is the process of
 *                       the window that had focus at the key press, for picking the
 *                       destination pane.
 *   dictate --pick-mic  a menu to choose the microphone (the YASB widget's right-click).
 *
 * Later presses never launch this exe: shells\Niri-Common.ahk signals the resident
 * recorder's event (Local\windots-dictate-toggle) after writing foreground.pid, which
 * costs nothing, where a launch costs ~0.5 s here (the security software scans new
 * binaries at every start). Running this exe again does the same signal.
 *
 * The first press opens the mic, ~0.6 s until audio flows (the driver). After a
 * recording the mic stays open for DICTATION_HOT_SECONDS (setup sets 900; unset or 0
 * closes it once the transcription is done), its audio discarded, so the next press
 * starts instantly. The mic shows as in use in Windows meanwhile.
 *
 * Sounds: a chime once audio is flowing (talk then), a short beep at the stop press,
 * a hand beep for a press while the previous transcription is still running.
 * status.json holds the YASB widget's line: starting, recording or transcribing, else
 * the idle microphone icon. It is never deleted, because the widget shows its raw
 * template when the file is missing.
 * Errors show as a balloon (Toggle-Dictation.ps1 -Action Notify).
 * The microphone is the Windows default until one is chosen in the menu, which saves its
 * name to mic.txt. A choice made while the recorder holds the mic open applies the next
 * time the recorder starts.
 *
 * Build: pwsh -File ..\Build-Native.ps1 dictate.c -Libs winmm -Windows (setup runs
 * it too). A GUI-subsystem exe, so launching it never opens a console window.
 * Tests: dictate.test.c (scripts/Test-Windots.ps1 runs them).
 */
#include <windows.h>
#include <mmsystem.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define RATE 16000
#define BUFFERS 8
#define BUFFER_MS 20
#define GRACE_MS 300      /* keep recording after the stop press: the last words are still in flight */
#define MAX_MS 600000     /* a recording nobody stopped */
#define TOGGLE_EVENT "Local\\windots-dictate-toggle"

enum { HOT, RECORDING, STOPPING };

/* <exe dir>\..\..\scripts\Toggle-Dictation.ps1 for an exe path (yasb\dictation\dictate.exe). */
static void script_path_for(const char *exe, char *out, size_t size) {
    const char *slash = strrchr(exe, '\\');
    snprintf(out, size, "%.*s\\..\\..\\scripts\\Toggle-Dictation.ps1", (int)(slash ? slash - exe : 0), exe);
}

/* The widget's JSON line for a recorder state ("starting", "recording" or "processing"),
 * ASCII so the file needs no encoding. Anything else, including "hot" (the mic held open
 * between dictations) and "", is the idle microphone icon, so the widget is always there. */
static void status_json(const char *state, char *out, size_t size) {
    const char *icon = "\\ue720", *text = "Dictation";
    if (!strcmp(state, "starting")) { icon = "\\ud83d\\udfe1"; text = "Starting"; }  /* the mic is not live yet: wait */
    else if (!strcmp(state, "recording")) { icon = "\\ud83d\\udd34"; text = "Recording"; }
    else if (!strcmp(state, "processing")) { icon = "\\u23f3"; text = "Transcribing"; }
    snprintf(out, size, "{\"icon\": \"%s\", \"text\": \"%s\"}", icon, text);
}

/* Runs Toggle-Dictation.ps1 hidden and detached. Returns its process handle to wait on
 * (the caller closes it), or NULL if it would not start. */
static HANDLE run_script(const char *arguments) {
    char exe[MAX_PATH], script[MAX_PATH + 64], command[2 * MAX_PATH + 512];
    GetModuleFileNameA(NULL, exe, sizeof exe);
    script_path_for(exe, script, sizeof script);
    snprintf(command, sizeof command, "pwsh -NoProfile -File \"%s\" %s", script, arguments);
    STARTUPINFOA si = { .cb = sizeof si };
    PROCESS_INFORMATION pi;
    if (!CreateProcessA(NULL, command, NULL, NULL, FALSE, CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP, NULL, NULL, &si, &pi))
        return NULL;
    CloseHandle(pi.hThread);
    return pi.hProcess;
}

static void notify(const char *message) {
    char arguments[512];
    snprintf(arguments, sizeof arguments, "-Action Notify -Message \"%s\"", message);
    HANDLE p = run_script(arguments);
    if (p) CloseHandle(p);
}

static void state_path(const char *name, char *out, size_t size) {
    const char *base = getenv("LOCALAPPDATA");
    char dir[MAX_PATH];
    snprintf(dir, sizeof dir, "%s\\windots", base ? base : ".");
    CreateDirectoryA(dir, NULL);
    snprintf(dir, sizeof dir, "%s\\windots\\dictation", base ? base : ".");
    CreateDirectoryA(dir, NULL);
    snprintf(out, size, "%s\\%s", dir, name);
}

/* Replaces a one-line state file (NULL deletes it). The new content is written aside and
 * swapped in, so the widget never reads the file empty between the truncate and the write. */
static void write_state(const char *name, const char *value) {
    char path[MAX_PATH], temp[MAX_PATH + 8];
    state_path(name, path, sizeof path);
    if (!value) { DeleteFileA(path); return; }
    snprintf(temp, sizeof temp, "%s.tmp", path);
    FILE *f = fopen(temp, "w");
    if (!f) return;
    fputs(value, f);
    fclose(f);
    MoveFileExA(temp, path, MOVEFILE_REPLACE_EXISTING);
}

static int read_state(const char *name, char *out, size_t size) {
    char path[MAX_PATH];
    state_path(name, path, sizeof path);
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    out[0] = 0;
    if (!fgets(out, (int)size, f)) out[0] = 0;
    fclose(f);
    return out[0] != 0;
}

/* Publishes the recorder's state for the widget. */
static void set_status(const char *state) {
    char line[128];
    status_json(state, line, sizeof line);
    write_state("status.json", line);
}

/* The device the menu chose, else the Windows default (also if it has been unplugged). */
static UINT pick_device(void) {
    char saved[128] = "";
    if (!read_state("mic.txt", saved, sizeof saved)) return WAVE_MAPPER;
    UINT count = waveInGetNumDevs();
    for (UINT i = 0; i < count; i++) {
        WAVEINCAPSA caps;
        if (waveInGetDevCapsA(i, &caps, sizeof caps) == MMSYSERR_NOERROR && strcmp(caps.szPname, saved) == 0) return i;
    }
    return WAVE_MAPPER;
}

typedef struct {
    WAVEHDR headers[BUFFERS];
    int next;
    FILE *file;           /* NULL while the mic is only being held open: audio is dropped */
    int flowing;          /* audio has arrived since the mic opened */
    int chime_pending;    /* chime at the next audio, for a press before it flowed */
} Recorder;

/* Takes every finished buffer in order (writing it when recording) and hands it back to the mic. */
static void drain(Recorder *r, HWAVEIN mic) {
    while (r->headers[r->next].dwFlags & WHDR_DONE) {
        WAVEHDR *h = &r->headers[r->next];
        if (h->dwBytesRecorded) {
            r->flowing = 1;
            if (r->file) fwrite(h->lpData, 1, h->dwBytesRecorded, r->file);
            if (r->chime_pending) {  /* audio is flowing: this is when to talk */
                MessageBeep(MB_ICONASTERISK);
                r->chime_pending = 0;
            }
        }
        h->dwBytesRecorded = 0;
        h->dwFlags &= ~WHDR_DONE;
        waveInAddBuffer(mic, h, sizeof *h);
        r->next = (r->next + 1) % BUFFERS;
    }
}

/* How long the mic stays open after a recording. The length is a setting, not a
 * constant: setup\Configure-Env.ps1 sets DICTATION_HOT_SECONDS, and without it the mic
 * closes as soon as the transcription is done. */
static int hot_ms(void) {
    const char *v = getenv("DICTATION_HOT_SECONDS");
    return (v && *v ? atoi(v) : 0) * 1000;
}

/* The widget's right-click menu: pick the microphone, or the Windows default. */
static int pick_mic(void) {
    char saved[128] = "";
    read_state("mic.txt", saved, sizeof saved);
    HMENU menu = CreatePopupMenu();
    AppendMenuA(menu, MF_STRING | (saved[0] ? 0 : MF_CHECKED), 1, "Default device");
    AppendMenuA(menu, MF_SEPARATOR, 0, NULL);
    UINT count = waveInGetNumDevs();
    for (UINT i = 0; i < count; i++) {
        WAVEINCAPSA caps;
        if (waveInGetDevCapsA(i, &caps, sizeof caps) == MMSYSERR_NOERROR)
            AppendMenuA(menu, MF_STRING | (strcmp(caps.szPname, saved) == 0 ? MF_CHECKED : 0), 100 + i, caps.szPname);
    }
    /* A menu needs a window that is in the foreground, or it will not close on a click elsewhere. */
    HWND owner = CreateWindowExA(WS_EX_TOOLWINDOW, "STATIC", "", WS_POPUP, 0, 0, 0, 0, NULL, NULL, NULL, NULL);
    POINT at;
    GetCursorPos(&at);
    SetForegroundWindow(owner);
    int chosen = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY, at.x, at.y, 0, owner, NULL);
    PostMessage(owner, WM_NULL, 0, 0);
    if (chosen == 1) write_state("mic.txt", NULL);
    else if (chosen >= 100) {
        WAVEINCAPSA caps;
        if (waveInGetDevCapsA((UINT)(chosen - 100), &caps, sizeof caps) == MMSYSERR_NOERROR) write_state("mic.txt", caps.szPname);
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "--pick-mic")) return pick_mic();
    char foreground[32] = "0";
    for (int i = 1; i + 1 < argc; i++)
        if (!strcmp(argv[i], "--pid")) snprintf(foreground, sizeof foreground, "%d", atoi(argv[i + 1]));
    write_state("foreground.pid", foreground);

    /* A resident recorder owns the toggle event: this press is its to handle. */
    HANDLE toggle = OpenEventA(EVENT_MODIFY_STATE, FALSE, TOGGLE_EVENT);
    if (toggle) {
        SetEvent(toggle);
        return 0;
    }
    toggle = CreateEventA(NULL, FALSE, FALSE, TOGGLE_EVENT);
    if (!toggle) return 1;
    if (GetLastError() == ERROR_ALREADY_EXISTS) {  /* lost a race with another press */
        SetEvent(toggle);
        return 0;
    }
    set_status("starting");

    Recorder r = { 0 };
    HANDLE data = CreateEventA(NULL, FALSE, FALSE, NULL);
    WAVEFORMATEX format = { WAVE_FORMAT_PCM, 1, RATE, RATE * 2, 2, 16, 0 };
    HWAVEIN mic;
    MMRESULT opened = waveInOpen(&mic, pick_device(), &format, (DWORD_PTR)data, 0, CALLBACK_EVENT);
    if (opened != MMSYSERR_NOERROR) {
        char message[128];
        snprintf(message, sizeof message, "Could not open the microphone (error %u)", opened);
        notify(message);
        set_status("");
        return 1;
    }
    size_t size = RATE * 2 * BUFFER_MS / 1000;
    for (int i = 0; i < BUFFERS; i++) {
        r.headers[i].lpData = malloc(size);
        r.headers[i].dwBufferLength = (DWORD)size;
        waveInPrepareHeader(mic, &r.headers[i], sizeof r.headers[i]);
        waveInAddBuffer(mic, &r.headers[i], sizeof r.headers[i]);
    }
    waveInStart(mic);

    HANDLE events[2] = { data, toggle };
    int state = HOT, want_start = 1, first = 1;  /* the press that launched this process starts a recording */
    int announced = 0;
    HANDLE worker = NULL;  /* the transcription in progress: it needs recording.raw until it is done */
    DWORD started = 0, deadline = 0;
    char raw[MAX_PATH];
    state_path("recording.raw", raw, sizeof raw);
    for (;;) {
        DWORD woke = WaitForMultipleObjects(2, events, FALSE, 50);
        drain(&r, mic);
        DWORD now = GetTickCount();
        if (state == RECORDING && !announced && r.flowing && !r.chime_pending) {  /* the chime just played */
            set_status("recording");
            announced = 1;
        }
        if (woke == WAIT_OBJECT_0 + 1) {
            if (state == HOT) want_start = 1;
            else if (state == RECORDING) {
                set_status("processing");  /* show it at the press, not when the worker starts */
                Beep(800, 40);
                state = STOPPING;
                deadline = now + GRACE_MS;
            }
        }
        if (want_start) {
            want_start = 0;
            char pid[32] = "0";
            if (worker) MessageBeep(MB_ICONHAND);
            else if (!(r.file = fopen(raw, "wb"))) notify("Could not write the recording");
            else {
                read_state("foreground.pid", pid, sizeof pid);
                state = RECORDING;
                started = now;
                announced = r.flowing;
                if (r.flowing) {  /* a held-open mic: talk now */
                    set_status("recording");
                    MessageBeep(MB_ICONASTERISK);
                } else {
                    set_status("starting");
                    r.chime_pending = 1;
                }
                char arguments[64];
                snprintf(arguments, sizeof arguments, "-Action Prepare -ForegroundPid %d", atoi(pid));
                HANDLE prepare = run_script(arguments);
                if (prepare) CloseHandle(prepare);
            }
            if (first && state == HOT) deadline = now;  /* a first press that could not record has nothing to hold open for */
            first = 0;
        }
        if (state == RECORDING && now - started > MAX_MS) {
            state = STOPPING;
            deadline = now;
            set_status("processing");
        }
        if (state == STOPPING && now >= deadline) {
            fclose(r.file);
            r.file = NULL;
            state = HOT;
            worker = run_script("-Action Transcribe");
            if (!worker) {  /* nothing will transcribe it: back to idle */
                notify("Could not start the transcription");
                deadline = now + hot_ms();
                set_status("hot");
            } else deadline = (DWORD)-1;
        }
        if (worker && WaitForSingleObject(worker, 0) == WAIT_OBJECT_0) {  /* done: now the mic idles for the hot window */
            CloseHandle(worker);
            worker = NULL;
            deadline = now + hot_ms();
            set_status("hot");
        }
        if (state == HOT && !worker && now >= deadline) break;
    }
    waveInStop(mic);
    waveInReset(mic);
    for (int i = 0; i < BUFFERS; i++) {
        waveInUnprepareHeader(mic, &r.headers[i], sizeof r.headers[i]);
        free(r.headers[i].lpData);
    }
    waveInClose(mic);
    set_status("");
    CloseHandle(toggle);
    return 0;
}
