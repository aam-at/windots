/*
 * psmux's one background helper. It stands in for three things that ran as
 * PowerShell on Linux-plugin cadences:
 *  - psmux-cpu: a pwsh start plus two WMI queries every 5 s per session.
 *    Here, GetSystemTimes and GlobalMemoryStatusEx fill @sysstat, which
 *    psmux.conf's status-right shows.
 *  - psmux-continuum: a resident pwsh (~70 MB) polling `psmux ls` every
 *    10 s. Here, psmux-resurrect's save.ps1 runs every SAVE_MINUTES, and
 *    restore.ps1 when psmux starts (sessions appear where there were none).
 *  - aw-watcher-tmux: a heartbeat to the aw-watcher-tmux bucket
 *    (akohlbecker/aw-watcher-tmux's data) for each session whose activity
 *    time moved.
 * psmux runs one server per session, each on the loopback port and key in
 * ~/.psmux/<session>.port and .key, taking the same command lines as the
 * CLI after "AUTH <key>". Talking to them directly means no process starts
 * on a tick: this idles at ~0% in ~2 MB.
 *
 * Setup starts it at login (Install-Startup.ps1), not psmux.conf: psmux runs
 * `run` commands through pwsh, a second of CPU for every new session. A
 * mutex keeps one.
 * Build: pwsh -File ../yasb/Build-Native.ps1 psmux-agent.c -Libs ws2_32 -Windows
 *        (setup runs it too).
 * Tests: psmux-agent.test.c (scripts/Test-Windots.ps1 runs them).
 */
#include "http.h"
#include "json.h"
#include <windows.h>

#define TICK_MS 5000
/* aw-watcher-tmux's: events of one session merge across 2 min of quiet. */
#define AW_PULSETIME 120
/* @continuum-save-interval's value in the Linux config. */
#define SAVE_MINUTES 15
#define MAX_SESSIONS 64

/* One line of `display -p`; tabs because paths and titles hold anything else. */
#define SESSION_FORMAT                                                                 \
    "#{session_activity}\t#{window_name}\t#{pane_title}\t#{pane_current_command}\t#{"  \
    "pane_current_path}"

typedef struct {
    char name[128];
    long long activity;
} Seen;

static Seen seen[MAX_SESSIONS];
static int seen_count;
static int bucket_ready;
static char host[256];
static char psmux_dir[MAX_PATH];

/* ---- Status ---- */

static ULONGLONG filetime(FILETIME t) {
    return (ULONGLONG)t.dwHighDateTime << 32 | t.dwLowDateTime;
}

/* Busy share of the time between two GetSystemTimes samples; kernel time
   includes idle time. */
static int cpu_percent(ULONGLONG idle, ULONGLONG total, ULONGLONG previous_idle,
                       ULONGLONG previous_total) {
    ULONGLONG elapsed = total - previous_total;
    if (!elapsed || idle - previous_idle > elapsed) return 0;
    return (int)((elapsed - (idle - previous_idle)) * 100 / elapsed);
}

/* psmux-cpu's thresholds, in the theme's green, yellow and red. */
static const char *level_colour(int percent, int medium, int high) {
    return percent >= high ? "#fb4934" : percent >= medium ? "#fabd2f" : "#b8bb26";
}

static void format_status(int cpu, int memory, char *out, size_t size) {
    snprintf(out, size, "#[fg=%s]CPU %d%%#[default] #[fg=%s]MEM %d%%#[default]",
             level_colour(cpu, 30, 80), cpu, level_colour(memory, 50, 80), memory);
}

static void read_status(char *out, size_t size) {
    static ULONGLONG previous_idle, previous_total;
    FILETIME idle, kernel, user;
    GetSystemTimes(&idle, &kernel, &user);
    ULONGLONG total = filetime(kernel) + filetime(user);
    int cpu = cpu_percent(filetime(idle), total, previous_idle, previous_total);
    previous_idle = filetime(idle);
    previous_total = total;
    MEMORYSTATUSEX memory = {sizeof memory};
    GlobalMemoryStatusEx(&memory);
    format_status(cpu, (int)memory.dwMemoryLoad, out, size);
}

/* ---- psmux servers ---- */

static int read_small_file(const char *session, const char *extension, char *out,
                           size_t size) {
    char path[MAX_PATH];
    snprintf(path, sizeof path, "%s\\%s.%s", psmux_dir, session, extension);
    FILE *file = fopen(path, "rb");
    if (!file) return 0;
    size_t n = fread(out, 1, size - 1, file);
    fclose(file);
    while (n && (out[n - 1] == '\n' || out[n - 1] == '\r' || out[n - 1] == ' ')) n--;
    out[n] = 0;
    return n > 0;
}

/* Runs newline-separated commands on a session's server; their output goes
   to out. 0 if the server isn't there (a stale .port file). */
static int psmux_run(const char *session, const char *commands, char *out,
                     size_t size) {
    char port[16], key[64];
    if (!read_small_file(session, "port", port, sizeof port) ||
        !read_small_file(session, "key", key, sizeof key))
        return 0;
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) return 0;
    DWORD timeout = 2000;
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char *)&timeout, sizeof timeout);
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, (const char *)&timeout, sizeof timeout);
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_port = htons((unsigned short)atoi(port));
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    char request[4096];
    int length = snprintf(request, sizeof request, "AUTH %s\n%s", key, commands);
    size_t total = 0;
    int n;
    /* The server answers "OK", runs the commands, and closes. */
    if (connect(s, (struct sockaddr *)&address, sizeof address) == 0 &&
        send(s, request, length, 0) == length)
        while (total + 1 < size &&
               (n = recv(s, out + total, (int)(size - 1 - total), 0)) > 0)
            total += (size_t)n;
    closesocket(s);
    out[total] = 0;
    if (strncmp(out, "OK\n", 3) != 0) return 0;
    memmove(out, out + 3, total - 2);
    return 1;
}

/* Session names: ~/.psmux/<name>.port, minus psmux's own (__warm__) and
   those of -L namespaces (<socket>__<name>). */
static int list_sessions(char names[][128], int max) {
    char pattern[MAX_PATH];
    snprintf(pattern, sizeof pattern, "%s\\*.port", psmux_dir);
    WIN32_FIND_DATAA found;
    HANDLE find = FindFirstFileA(pattern, &found);
    if (find == INVALID_HANDLE_VALUE) return 0;
    int count = 0;
    do {
        char *dot = strrchr(found.cFileName, '.');
        if (!dot || strstr(found.cFileName, "__") || dot - found.cFileName >= 128)
            continue;
        snprintf(names[count], 128, "%.*s", (int)(dot - found.cFileName),
                 found.cFileName);
        count++;
    } while (count < max && FindNextFileA(find, &found));
    FindClose(find);
    return count;
}

/* ---- ActivityWatch ---- */

/* Splits line at tabs in place; returns the field count. */
static int split_tabs(char *line, char **fields, int max) {
    int n = 0;
    fields[n++] = line;
    for (char *c = line; *c && n < max; c++)
        if (*c == '\t') *c = 0, fields[n++] = c + 1;
    return n;
}

/* The heartbeat body for a session from its SESSION_FORMAT line (edited in
   place), and its activity time. 0 if the line isn't one. */
static int heartbeat_body(const char *session, char *line, const char *timestamp,
                          long long *activity, char *body, size_t size) {
    line[strcspn(line, "\r\n")] = 0;
    char *fields[5];
    if (split_tabs(line, fields, 5) != 5 || sscanf(fields[0], "%lld", activity) != 1)
        return 0;
    char name[256], window[512], title[512], command[512], path[1024];
    json_escape(session, name, sizeof name);
    json_escape(fields[1], window, sizeof window);
    json_escape(fields[2], title, sizeof title);
    json_escape(fields[3], command, sizeof command);
    json_escape(fields[4], path, sizeof path);
    snprintf(body, size,
             "{\"timestamp\": \"%s\", \"duration\": 0, \"data\": {\"title\": \"%s\", "
             "\"session_name\": \"%s\", \"window_name\": \"%s\", "
             "\"pane_title\": \"%s\", \"pane_current_command\": \"%s\", "
             "\"pane_current_path\": \"%s\"}}",
             timestamp, name, name, window, title, command, path);
    return 1;
}

static Seen *seen_session(const char *name) {
    for (int i = 0; i < seen_count; i++)
        if (strcmp(seen[i].name, name) == 0) return &seen[i];
    if (seen_count == MAX_SESSIONS)
        seen_count =
            0; /* ponytail: forgets all past 64 sessions; a rare repeat heartbeat */
    Seen *entry = &seen[seen_count++];
    snprintf(entry->name, sizeof entry->name, "%s", name);
    entry->activity = 0;
    return entry;
}

/* Where heartbeats go; the tests record them instead. */
static int send_heartbeat(const char *body) {
    char bucket[512];
    snprintf(bucket, sizeof bucket,
             "{\"client\": \"aw-watcher-tmux\", \"type\": \"tmux.sessions\", "
             "\"hostname\": \"%s\"}",
             host);
    /* aw-server may start after psmux: retry the bucket until it's there. */
    if (!bucket_ready &&
        !(bucket_ready = http_post("/api/0/buckets/aw-watcher-tmux", bucket)))
        return 0;
    char path[128];
    snprintf(path, sizeof path, "/api/0/buckets/aw-watcher-tmux/heartbeat?pulsetime=%d",
             AW_PULSETIME);
    if (!http_post(path, body)) bucket_ready = 0;
    return bucket_ready;
}

/* Heartbeats a session whose activity moved since the last one that went out. */
static void track(const char *session, char *line, int (*send)(const char *)) {
    char timestamp[64], body[4096];
    long long activity;
    format_timestamp(now_ticks(), timestamp, sizeof timestamp);
    if (!heartbeat_body(session, line, timestamp, &activity, body, sizeof body)) return;
    Seen *entry = seen_session(session);
    if (activity > entry->activity && send(body)) entry->activity = activity;
}

/* ---- psmux-resurrect ---- */

static void run_resurrect(const char *script) {
    char command[MAX_PATH * 2];
    snprintf(command, sizeof command,
             "conhost.exe --headless pwsh -NoProfile -File "
             "\"%s\\plugins\\psmux-resurrect\\scripts\\%s\"",
             psmux_dir, script);
    WinExec(command, SW_HIDE);
}

int main(void) {
    CreateMutexW(NULL, FALSE, L"windots-psmux-agent");
    if (GetLastError() == ERROR_ALREADY_EXISTS) return 0;

    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
    snprintf(psmux_dir, sizeof psmux_dir, "%s\\.psmux", getenv("USERPROFILE"));
    char raw_host[256];
    DWORD host_size = sizeof raw_host;
    GetComputerNameExA(ComputerNameDnsHostname, raw_host, &host_size);
    json_escape(raw_host, host, sizeof host);

    static char names[MAX_SESSIONS][128];
    char status[256], commands[512], reply[8192];
    read_status(status, sizeof status);

    char last[MAX_PATH];
    snprintf(last, sizeof last, "%s\\resurrect\\last", psmux_dir);
    ULONGLONG next_save = GetTickCount64() + SAVE_MINUTES * 60000ULL;
    /* -1: unknown, so starting beside running sessions (a rebuild) doesn't restore. */
    for (int previous_live = -1;;) {
        Sleep(TICK_MS);
        read_status(status, sizeof status);
        snprintf(commands, sizeof commands,
                 "set -g @sysstat \"%s\"\ndisplay -p \"" SESSION_FORMAT "\"\n", status);
        int live = 0, count = list_sessions(names, MAX_SESSIONS);
        for (int i = 0; i < count; i++)
            if (psmux_run(names[i], commands, reply, sizeof reply))
                live++, track(names[i], reply, send_heartbeat);
        /* psmux just started: continuum's restore. */
        if (previous_live == 0 && live &&
            GetFileAttributesA(last) != INVALID_FILE_ATTRIBUTES)
            run_resurrect("restore.ps1");
        previous_live = live;
        if (live && GetTickCount64() >= next_save) {
            run_resurrect("save.ps1");
            next_save = GetTickCount64() + SAVE_MINUTES * 60000ULL;
        }
    }
}
