/*
 * Drop-in replacement for ActivityWatch's aw-watcher-window: records the
 * focused app and window title into the same bucket
 * (aw-watcher-window_<host>, events {"app": "x.exe", "title": "..."}), so the
 * dashboard and scripts\Get-FocusTime.ps1 read it unchanged.
 *
 * The Python watcher polls every second and costs ~1% of a core. This one
 * waits for WinEvents (focus changes, and title changes of the focused
 * process only) plus a 10 s heartbeat, so it idles at ~0% in ~1 MB.
 *
 * Two fixes over the original:
 *  - When the window or title changes, the old event is closed at that
 *    moment. The original only ever extends the new one, so a title that
 *    changes every second (Claude Code's spinner) became a run of events
 *    lasting 0 s each and that time went missing.
 *  - Leading status glyphs (spinners, "●" unsaved dots, emoji) are dropped
 *    from titles, so such a window stays one event.
 *
 * aw-qt must not start the Python watcher too: see aw-qt.toml.
 * Build: pwsh -File ../Build-Native.ps1 window-watcher.c -Libs winhttp -Windows
 *        (setup runs it too).
 * Tests: window-watcher.test.c (scripts/Test-Windots.ps1 runs them).
 */
#include <windows.h>
#include <winhttp.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

#define SERVER_PORT 5600
#define HEARTBEAT_MS 10000
/* Heartbeats of the same window merge within this; > HEARTBEAT_MS. */
#define PULSETIME "11"
/* Title changes are sampled at most this often, like the original's poll. */
#define MIN_SAMPLE_MS 1000

typedef struct {
    char app[MAX_PATH * 3];
    char title[1024 * 3];
} Window;

static HINTERNET session, connection;
static char bucket_path[256], bucket_json[512];
static int bucket_ready;
static Window current;
static int have_current;
static DWORD last_sample_tick;
static UINT_PTR pending_timer;
static HWINEVENTHOOK title_hook;
static DWORD title_hook_pid;

/* One HTTP request to aw-server; returns the status code, 0 when unreachable.
   The response body goes to response when given. */
static DWORD request(const wchar_t *method, const char *path, const char *body, char *response, DWORD response_size) {
    wchar_t wpath[512];
    MultiByteToWideChar(CP_UTF8, 0, path, -1, wpath, 512);
    HINTERNET handle = WinHttpOpenRequest(connection, method, wpath, NULL, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, 0);
    if (!handle) return 0;
    DWORD length = body ? (DWORD)strlen(body) : 0;
    DWORD status = 0, size = sizeof status;
    if (WinHttpSendRequest(handle, L"Content-Type: application/json\r\n", (DWORD)-1, (void *)body, length, length, 0)
        && WinHttpReceiveResponse(handle, NULL))
        WinHttpQueryHeaders(handle, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, NULL, &status, &size, NULL);
    if (response && response_size) {
        DWORD total = 0, read = 0;
        while (status && total + 1 < response_size && WinHttpReadData(handle, response + total, response_size - 1 - total, &read) && read)
            total += read;
        response[total] = 0;
    }
    WinHttpCloseHandle(handle);
    return status;
}

static int post(const char *path, const char *body) {
    DWORD status = request(L"POST", path, body, NULL, 0);
    /* 304: the bucket already exists. */
    return (status >= 200 && status < 300) || status == 304;
}

/* Points the watcher at aw-server on this port, in this bucket. */
static void connect_server(INTERNET_PORT port, const char *bucket_id, const char *host) {
    snprintf(bucket_path, sizeof bucket_path, "/api/0/buckets/%s", bucket_id);
    snprintf(bucket_json, sizeof bucket_json,
        "{\"client\": \"aw-watcher-window\", \"type\": \"currentwindow\", \"hostname\": \"%s\"}", host);
    bucket_ready = 0;
    if (!session) {
        session = WinHttpOpen(L"windots-window-watcher", WINHTTP_ACCESS_TYPE_NO_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
        WinHttpSetTimeouts(session, 1000, 1000, 2000, 2000);
    }
    if (connection) WinHttpCloseHandle(connection);
    connection = WinHttpConnect(session, L"localhost", port, 0);
}

/* UTF-16 to a JSON string body (without quotes) in UTF-8. */
static void json_utf8(const wchar_t *in, char *out, size_t size) {
    char utf8[4096];
    WideCharToMultiByte(CP_UTF8, 0, in, -1, utf8, sizeof utf8, NULL, NULL);
    size_t n = 0;
    const unsigned char *c = (const unsigned char *)utf8;
    for (; *c && n + 7 < size; c++) {
        if (*c == '"' || *c == '\\') out[n++] = '\\', out[n++] = (char)*c;
        else if (*c < 0x20) n += snprintf(out + n, size - n, "\\u%04x", *c);
        else out[n++] = (char)*c;
    }
    /* Truncated mid-character: drop the partial one, or the JSON is invalid. */
    if (*c && (*c & 0xC0) == 0x80) {
        while (n > 0 && ((unsigned char)out[n - 1] & 0xC0) == 0x80) n--;
        if (n > 0 && (unsigned char)out[n - 1] >= 0xC0) n--;
    }
    out[n] = 0;
}

/* Drops leading spinner and status glyphs: symbols outside ASCII, and the
   spaces after them. "◐ Fix bug" and "● main.c - Zed" keep only the text. */
static const wchar_t *strip_status(const wchar_t *title) {
    const wchar_t *start = title;
    while (*start && ((*start >= 0x80 && !IsCharAlphaNumericW(*start)) || (*start == L' ' && start != title)))
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
    if (!process || !QueryFullProcessImageNameW(process, 0, path, &size)) wcscpy(path, L"unknown");
    if (process) CloseHandle(process);
    GetWindowTextW(hwnd, title, 1024);
    make_window(path, title, window);
}

/* aw-server's timestamp format, in UTC. */
static void format_timestamp(const SYSTEMTIME *t, char *out, size_t size) {
    snprintf(out, size, "%04d-%02d-%02dT%02d:%02d:%02d.%03d000+00:00",
        t->wYear, t->wMonth, t->wDay, t->wHour, t->wMinute, t->wSecond, t->wMilliseconds);
}

static void heartbeat_to_server(const Window *window, const char *timestamp) {
    if (!bucket_ready && !(bucket_ready = post(bucket_path, bucket_json))) return;
    char path[512], body[sizeof window->app + sizeof window->title + 160];
    snprintf(path, sizeof path, "%s/heartbeat?pulsetime=" PULSETIME, bucket_path);
    snprintf(body, sizeof body, "{\"timestamp\": \"%s\", \"duration\": 0, \"data\": {\"app\": \"%s\", \"title\": \"%s\"}}",
        timestamp, window->app, window->title);
    /* Server down: retry the bucket too once it is back. */
    if (!post(path, body)) bucket_ready = 0;
}

/* Where heartbeats go; the tests record them instead. */
static void (*send_heartbeat)(const Window *, const char *) = heartbeat_to_server;

/* The focused window at this time. On a change, closes the old event at
   this moment so its duration is exact, then opens the new one. */
static void observe(const Window *now, const char *timestamp) {
    if (have_current && strcmp(now->app, current.app) == 0 && strcmp(now->title, current.title) == 0) return;
    if (have_current) send_heartbeat(&current, timestamp);
    current = *now;
    have_current = 1;
    send_heartbeat(&current, timestamp);
}

/* Extends the current event to this time; the periodic heartbeat. */
static void keep_alive(const char *timestamp) {
    if (have_current) send_heartbeat(&current, timestamp);
}

static void now_timestamp(char *out, size_t size) {
    SYSTEMTIME t;
    GetSystemTime(&t);
    format_timestamp(&t, out, size);
}

static void CALLBACK on_title_change(HWINEVENTHOOK, DWORD, HWND, LONG, LONG, DWORD, DWORD);

/* Follows title changes of the focused process only; a global hook would
   wake us for every caption and accessible name in the session. */
static void watch_titles_of(HWND hwnd) {
    DWORD pid = 0;
    GetWindowThreadProcessId(hwnd, &pid);
    if (pid == title_hook_pid && title_hook) return;
    if (title_hook) UnhookWinEvent(title_hook);
    title_hook = SetWinEventHook(EVENT_OBJECT_NAMECHANGE, EVENT_OBJECT_NAMECHANGE, NULL, on_title_change, pid, 0, WINEVENT_OUTOFCONTEXT);
    title_hook_pid = pid;
}

static void sample(void) {
    HWND hwnd = GetForegroundWindow();
    if (!hwnd) return;
    last_sample_tick = GetTickCount();
    watch_titles_of(hwnd);
    Window now;
    read_window(hwnd, &now);
    char timestamp[64];
    now_timestamp(timestamp, sizeof timestamp);
    observe(&now, timestamp);
}

static void CALLBACK on_pending(HWND hwnd, UINT message, UINT_PTR id, DWORD time) {
    KillTimer(NULL, pending_timer);
    pending_timer = 0;
    sample();
}

static void CALLBACK on_heartbeat(HWND hwnd, UINT message, UINT_PTR id, DWORD time) {
    /* Also catches anything the hooks missed. */
    sample();
    char timestamp[64];
    now_timestamp(timestamp, sizeof timestamp);
    keep_alive(timestamp);
}

static void CALLBACK on_focus(HWINEVENTHOOK hook, DWORD event, HWND hwnd, LONG object, LONG child, DWORD thread, DWORD time) {
    sample();
}

static void CALLBACK on_title_change(HWINEVENTHOOK hook, DWORD event, HWND hwnd, LONG object, LONG child, DWORD thread, DWORD time) {
    if (object != OBJID_WINDOW || child != CHILDID_SELF || hwnd != GetForegroundWindow()) return;
    DWORD since = GetTickCount() - last_sample_tick;
    if (since >= MIN_SAMPLE_MS) sample();
    else if (!pending_timer) pending_timer = SetTimer(NULL, 0, MIN_SAMPLE_MS - since, on_pending);
}

int WINAPI WinMain(HINSTANCE instance, HINSTANCE previous, LPSTR command_line, int show) {
    CreateMutexW(NULL, FALSE, L"windots-window-watcher");
    if (GetLastError() == ERROR_ALREADY_EXISTS) return 0;

    wchar_t whost[256];
    DWORD size = 256;
    char host[256], bucket_id[300];
    GetComputerNameExW(ComputerNameDnsHostname, whost, &size);
    json_utf8(whost, host, sizeof host);
    snprintf(bucket_id, sizeof bucket_id, "aw-watcher-window_%s", host);
    connect_server(SERVER_PORT, bucket_id, host);

    SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, NULL, on_focus, 0, 0, WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
    SetTimer(NULL, 0, HEARTBEAT_MS, on_heartbeat);
    sample();

    MSG message;
    while (GetMessageW(&message, NULL, 0, 0) > 0) DispatchMessageW(&message);
    return 0;
}
