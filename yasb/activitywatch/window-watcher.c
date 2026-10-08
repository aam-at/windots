/*
 * Drop-in replacement for ActivityWatch's aw-watcher-window and
 * aw-watcher-afk: records the focused app and window title, and whether
 * someone is at the keyboard, into the same buckets
 * (aw-watcher-window_<host>: {"app": "x.exe", "title": "..."};
 * aw-watcher-afk_<host>: {"status": "afk" | "not-afk"}), so the dashboard
 * and scripts\Get-FocusTime.ps1 read them unchanged.
 *
 * The Python watchers poll every second and every 5 s and cost ~1% of a
 * core and ~60 MB between them. This waits for WinEvents (focus changes,
 * and title changes of the focused process only), plus a 30 s window
 * heartbeat and a 5 s input check, so it idles at ~0% in ~3 MB.
 *
 * Fixes over the originals:
 *  - When the window or title changes, the old event is closed at that
 *    moment. The original only ever extends the new one, so a title that
 *    changes every second (Claude Code's spinner) became a run of events
 *    lasting 0 s each and that time went missing.
 *  - Leading status glyphs (spinners, "●" unsaved dots, emoji) are dropped
 *    from titles, so such a window stays one event.
 *  - Afk heartbeats are never timestamped before the event they extend.
 *    The original sends some 1 ms early, which aw-server can't merge, so an
 *    away period (or a return followed by no further input) left two
 *    overlapping events.
 *
 * Nothing else may run the Python watchers: setup starts aw-server alone.
 * aw-server is reached through http.h from dotfiles' tools/lib, the C
 * library shared with dotfiles' tools (Build-Native.ps1 adds it to the
 * include path).
 * Build: pwsh -File ../Build-Native.ps1 window-watcher.c -Libs ws2_32 -Windows
 *        (setup runs it too).
 * Tests: window-watcher.test.c (scripts/Test-Windots.ps1 runs them).
 */
#include "http.h"
#include "json.h"
#include <windows.h>
#include <wchar.h>

/* Unchanged state is re-sent this often; changes go out at once. Each
   request costs the Python aw-server ~10 ms, so this is what keeps it near
   idle. The current event can lag this much until the next change. */
#define HEARTBEAT_MS 30000
/* Title changes are sampled at most this often, like the original's poll. */
#define MIN_SAMPLE_MS 1000
/* aw-watcher-afk's defaults: away after 3 min without input, checked every 5 s. */
#define AFK_TIMEOUT_S 180
#define AFK_POLL_MS 5000

/* Timestamps are FILETIME ticks: 100 ns since 1601, UTC. */
#define TICKS_PER_SECOND 10000000ULL
#define ONE_MS (TICKS_PER_SECOND / 1000)

typedef struct {
    char app[MAX_PATH * 3];
    char title[1024 * 3];
} Window;

typedef struct {
    char path[256], json[512];
    /* Heartbeats of the same data merge within this many seconds. */
    int pulsetime;
    int ready;
} Bucket;

/* Window heartbeats come at least every HEARTBEAT_MS; afk ones may be
   AFK_TIMEOUT_S apart (the original's timeout + poll). */
static Bucket window_bucket = {.pulsetime = HEARTBEAT_MS / 1000 + 1};
static Bucket afk_bucket = {.pulsetime = AFK_TIMEOUT_S + AFK_POLL_MS / 1000};

static Window current;
static int have_current;
static int afk;
/* Start of the current afk or not-afk event (0 before the first change). */
static ULONGLONG afk_state_start;
/* When the last afk heartbeat went out, to space unchanged ones. */
static ULONGLONG afk_last_sent;
static DWORD last_sample_tick;
static UINT_PTR pending_timer;
static HWINEVENTHOOK title_hook;
static DWORD title_hook_pid;

static void setup_bucket(Bucket *bucket, const char *id, const char *client,
                         const char *type, const char *host) {
    snprintf(bucket->path, sizeof bucket->path, "/api/0/buckets/%s", id);
    snprintf(bucket->json, sizeof bucket->json,
             "{\"client\": \"%s\", \"type\": \"%s\", \"hostname\": \"%s\"}", client,
             type, host);
    bucket->ready = 0;
}

/* UTF-16 to a JSON string body (without quotes) in UTF-8. */
static void json_utf8(const wchar_t *in, char *out, size_t size) {
    char utf8[4096];
    WideCharToMultiByte(CP_UTF8, 0, in, -1, utf8, sizeof utf8, NULL, NULL);
    json_escape(utf8, out, size);
}

/* Drops leading spinner and status glyphs: symbols outside ASCII, and the
   spaces after them. "◐ Fix bug" and "● main.c - Zed" keep only the text. */
static const wchar_t *strip_status(const wchar_t *title) {
    const wchar_t *start = title;
    while (*start && ((*start >= 0x80 && !IsCharAlphaNumericW(*start)) ||
                      (*start == L' ' && start != title)))
        start++;
    return *start ? start : title;
}

/* The event data for an exe path (or name) and a raw window title. */
static void make_window(const wchar_t *exe, const wchar_t *title, Window *window) {
    const wchar_t *name = wcsrchr(exe, L'\\');
    json_utf8(name ? name + 1 : exe, window->app, sizeof window->app);
    json_utf8(strip_status(title), window->title, sizeof window->title);
}

static void read_window(HWND hwnd, Window *window) {
    wchar_t path[MAX_PATH] = L"", title[1024] = L"";
    DWORD pid = 0, size = MAX_PATH;
    GetWindowThreadProcessId(hwnd, &pid);
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!process || !QueryFullProcessImageNameW(process, 0, path, &size))
        wcscpy(path, L"unknown");
    if (process) CloseHandle(process);
    GetWindowTextW(hwnd, title, 1024);
    make_window(path, title, window);
}

static void heartbeat_to_server(Bucket *bucket, ULONGLONG at, double duration,
                                const char *data) {
    if (!bucket->ready && !(bucket->ready = http_post(bucket->path, bucket->json)))
        return;
    char path[512], timestamp[64],
        body[sizeof current.app + sizeof current.title + 200];
    format_timestamp(at, timestamp, sizeof timestamp);
    snprintf(path, sizeof path, "%s/heartbeat?pulsetime=%d", bucket->path,
             bucket->pulsetime);
    snprintf(body, sizeof body,
             "{\"timestamp\": \"%s\", \"duration\": %.3f, \"data\": %s}", timestamp,
             duration, data);
    /* Server down: retry the bucket too once it is back. */
    if (!http_post(path, body)) bucket->ready = 0;
}

/* Where heartbeats go; the tests record them instead. */
static void (*send_heartbeat)(Bucket *, ULONGLONG, double,
                              const char *) = heartbeat_to_server;

static void send_window(const Window *window, ULONGLONG at) {
    char data[sizeof window->app + sizeof window->title + 32];
    snprintf(data, sizeof data, "{\"app\": \"%s\", \"title\": \"%s\"}", window->app,
             window->title);
    send_heartbeat(&window_bucket, at, 0, data);
}

/* The focused window at this time. On a change, closes the old event at
   this moment so its duration is exact, then opens the new one. */
static void observe(const Window *now, ULONGLONG at) {
    if (have_current && strcmp(now->app, current.app) == 0 &&
        strcmp(now->title, current.title) == 0)
        return;
    if (have_current) send_window(&current, at);
    current = *now;
    have_current = 1;
    send_window(&current, at);
}

/* Extends the current event to this time; the periodic heartbeat. */
static void keep_alive(ULONGLONG at) {
    if (have_current) send_window(&current, at);
}

static void send_afk(int away, ULONGLONG at, double duration) {
    send_heartbeat(&afk_bucket, at, duration,
                   away ? "{\"status\": \"afk\"}" : "{\"status\": \"not-afk\"}");
}

/* aw-watcher-afk's state machine (aw_watcher_afk/afk.py heartbeat_loop):
   not-afk events run until the last input; once idle for AFK_TIMEOUT_S, an
   afk event starts 1 ms after that input and runs until input again. */
static void observe_input(ULONGLONG now, double idle_seconds) {
    ULONGLONG last_input = now - (ULONGLONG)(idle_seconds * TICKS_PER_SECOND);
    if (afk && idle_seconds < AFK_TIMEOUT_S) {
        /* Back: the afk event ends at this input. */
        send_afk(1, last_input, 0);
        afk = 0;
        afk_state_start = last_input + ONE_MS;
        send_afk(0, afk_state_start, 0);
    } else if (!afk && idle_seconds >= AFK_TIMEOUT_S) {
        /* Away: the not-afk event ends at the last input. */
        send_afk(0, last_input > afk_state_start ? last_input : afk_state_start, 0);
        afk = 1;
        afk_state_start = last_input + ONE_MS;
        send_afk(1, afk_state_start, idle_seconds);
    } else if (now - afk_last_sent < HEARTBEAT_MS * (TICKS_PER_SECOND / 1000))
        return;
    /* Never before the current event's start: aw-server can't merge a
       heartbeat that precedes it and would open a duplicate event. */
    else if (afk)
        send_afk(1, afk_state_start,
                 (now - afk_state_start) / (double)TICKS_PER_SECOND);
    else
        send_afk(0, last_input > afk_state_start ? last_input : afk_state_start, 0);
    afk_last_sent = now;
}

static void CALLBACK on_title_change(HWINEVENTHOOK, DWORD, HWND, LONG, LONG, DWORD,
                                     DWORD);

/* Follows title changes of the focused process only; a global hook would
   wake us for every caption and accessible name in the session. */
static void watch_titles_of(HWND hwnd) {
    DWORD pid = 0;
    GetWindowThreadProcessId(hwnd, &pid);
    if (pid == title_hook_pid && title_hook) return;
    if (title_hook) UnhookWinEvent(title_hook);
    title_hook = SetWinEventHook(EVENT_OBJECT_NAMECHANGE, EVENT_OBJECT_NAMECHANGE, NULL,
                                 on_title_change, pid, 0, WINEVENT_OUTOFCONTEXT);
    title_hook_pid = pid;
}

static void sample(void) {
    HWND hwnd = GetForegroundWindow();
    if (!hwnd) return;
    last_sample_tick = GetTickCount();
    watch_titles_of(hwnd);
    Window now;
    read_window(hwnd, &now);
    observe(&now, now_ticks());
}

static void CALLBACK on_pending(HWND hwnd, UINT message, UINT_PTR id, DWORD time) {
    KillTimer(NULL, pending_timer);
    pending_timer = 0;
    sample();
}

static void CALLBACK on_heartbeat(HWND hwnd, UINT message, UINT_PTR id, DWORD time) {
    /* Also catches anything the hooks missed. */
    sample();
    keep_alive(now_ticks());
}

static void CALLBACK on_afk_poll(HWND hwnd, UINT message, UINT_PTR id, DWORD time) {
    LASTINPUTINFO input = {sizeof input};
    if (!GetLastInputInfo(&input)) return;
    observe_input(now_ticks(), (GetTickCount() - input.dwTime) / 1000.0);
}

static void CALLBACK on_focus(HWINEVENTHOOK hook, DWORD event, HWND hwnd, LONG object,
                              LONG child, DWORD thread, DWORD time) {
    sample();
}

static void CALLBACK on_title_change(HWINEVENTHOOK hook, DWORD event, HWND hwnd,
                                     LONG object, LONG child, DWORD thread,
                                     DWORD time) {
    if (object != OBJID_WINDOW || child != CHILDID_SELF ||
        hwnd != GetForegroundWindow())
        return;
    DWORD since = GetTickCount() - last_sample_tick;
    if (since >= MIN_SAMPLE_MS)
        sample();
    else if (!pending_timer)
        pending_timer = SetTimer(NULL, 0, MIN_SAMPLE_MS - since, on_pending);
}

int WINAPI WinMain(HINSTANCE instance, HINSTANCE previous, LPSTR command_line,
                   int show) {
    CreateMutexW(NULL, FALSE, L"windots-window-watcher");
    if (GetLastError() == ERROR_ALREADY_EXISTS) return 0;

    wchar_t whost[256];
    DWORD size = 256;
    char host[256], id[300];
    GetComputerNameExW(ComputerNameDnsHostname, whost, &size);
    json_utf8(whost, host, sizeof host);
    snprintf(id, sizeof id, "aw-watcher-window_%s", host);
    setup_bucket(&window_bucket, id, "aw-watcher-window", "currentwindow", host);
    snprintf(id, sizeof id, "aw-watcher-afk_%s", host);
    setup_bucket(&afk_bucket, id, "aw-watcher-afk", "afkstatus", host);

    SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, NULL, on_focus, 0,
                    0, WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
    SetTimer(NULL, 0, HEARTBEAT_MS, on_heartbeat);
    SetTimer(NULL, 0, AFK_POLL_MS, on_afk_poll);
    sample();
    on_afk_poll(NULL, 0, 0, 0);

    MSG message;
    while (GetMessageW(&message, NULL, 0, 0) > 0) DispatchMessageW(&message);
    return 0;
}
