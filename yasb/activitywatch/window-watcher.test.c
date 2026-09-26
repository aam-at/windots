/*
 * Tests for window-watcher.c. Run by scripts\Test-Windots.ps1, or by hand:
 *   gcc -Wall -o window-watcher.test.exe window-watcher.test.c -lwinhttp
 *   window-watcher.test.exe            # logic, against a model of aw-server
 *   window-watcher.test.exe --server   # the same scenarios against a real
 *                                      # aw-server --testing on port 5666
 *
 * Each scenario is a script of focus changes and heartbeat ticks with the
 * events ActivityWatch should end up with. The model applies aw-server's
 * heartbeat merge rule (same data within pulsetime of the last event's end
 * extends it; anything else starts a new event); --server checks that the
 * real server agrees with it.
 */
#include "window-watcher.c"

static int failures;

#define CHECK(condition) do { if (!(condition)) { printf("window-watcher.test.c:%d: failed: %s\n", __LINE__, #condition); failures++; } } while (0)

static void check_str(int line, const char *actual, const char *expected) {
    if (strcmp(actual, expected) == 0) return;
    printf("window-watcher.test.c:%d: got  \"%s\"\n                         want \"%s\"\n", line, actual, expected);
    failures++;
}
#define CHECK_STR(actual, expected) check_str(__LINE__, actual, expected)

/* ---- Title and JSON handling ---- */

static const char *title_of(const wchar_t *raw) {
    static Window window;
    make_window(L"C:\\Program Files\\App\\app.exe", raw, &window);
    return window.title;
}

static void test_strip_status(void) {
    CHECK_STR(title_of(L"\u25D0 Fix bug"), "Fix bug");                /* Claude Code spinner */
    CHECK_STR(title_of(L"\u2733 Claude Code"), "Claude Code");
    CHECK_STR(title_of(L"\u280B Building"), "Building");              /* Braille spinner */
    CHECK_STR(title_of(L"\u25CF main.c - Zed"), "main.c - Zed");      /* unsaved dot */
    CHECK_STR(title_of(L"\U0001F3B5 Song"), "Song");                  /* emoji (surrogate pair) */
    CHECK_STR(title_of(L"(1) WhatsApp"), "(1) WhatsApp");             /* ASCII kept */
    CHECK_STR(title_of(L"\u041F\u0440\u0438\u0432\u0435\u0442"), "\xD0\x9F\xD1\x80\xD0\xB8\xD0\xB2\xD0\xB5\xD1\x82"); /* Cyrillic letters kept */
    CHECK_STR(title_of(L"\u65E5\u672C"), "\xE6\x97\xA5\xE6\x9C\xAC");  /* CJK kept */
    CHECK_STR(title_of(L"\u25CF"), "\xE2\x97\x8F");                    /* nothing left: keep it */
    CHECK_STR(title_of(L""), "");
}

static void test_json(void) {
    CHECK_STR(title_of(L"say \"hi\" C:\\x\n"), "say \\\"hi\\\" C:\\\\x\\u000a");
    Window window;
    make_window(L"C:\\Windows\\explorer.exe", L"x", &window);
    CHECK_STR(window.app, "explorer.exe");
    make_window(L"unknown", L"x", &window);
    CHECK_STR(window.app, "unknown");

    /* Truncation never splits a UTF-8 character. */
    char out[16];
    json_utf8(L"\u00E9\u00E9\u00E9\u00E9\u00E9\u00E9\u00E9\u00E9\u00E9\u00E9", out, sizeof out);
    size_t length = strlen(out);
    CHECK(length > 0 && length % 2 == 0);
    CHECK(MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, out, -1, NULL, 0) > 0);
}

/* ---- Scenarios ---- */

typedef struct {
    double at;
    const wchar_t *app, *title; /* NULL app: a heartbeat tick */
} Step;

typedef struct {
    const char *app, *title;
    double start, duration;
} Expected;

typedef struct {
    const char *name;
    Step steps[40];
    Expected events[8];
} Scenario;

#define TICK(t) {t, NULL, NULL}
#define WT L"C:\\Program Files\\WindowsApps\\WindowsTerminal.exe"

static const Scenario scenarios[] = {
    {"spinner title stays one event",
        {{0, WT, L"\u25D0 Task"}, {1, WT, L"\u25D1 Task"}, {2, WT, L"\u25D0 Task"}, {3, WT, L"\u25D1 Task"}, {4, WT, L"\u25D0 Task"},
         {5, WT, L"\u25D1 Task"}, {6, WT, L"\u25D0 Task"}, {7, WT, L"\u25D1 Task"}, {8, WT, L"\u25D0 Task"}, {9, WT, L"\u25D1 Task"},
         TICK(10), {15, WT, L"\u2733 Task"}, TICK(20), TICK(30)},
        {{"WindowsTerminal.exe", "Task", 0, 30}}},
    {"a switch closes the old event at that moment",
        {{0, WT, L"Claude"}, TICK(10), TICK(20), {25.5, L"msedge.exe", L"Docs"}, {28.5, WT, L"Claude"}, TICK(30), TICK(40)},
        {{"WindowsTerminal.exe", "Claude", 0, 25.5}, {"msedge.exe", "Docs", 25.5, 3}, {"WindowsTerminal.exe", "Claude", 28.5, 11.5}}},
    {"a new title in the same app is a new event",
        {{0, L"zed.exe", L"\u25CF a.c - Zed"}, {5, L"zed.exe", L"a.c - Zed"}, {7, L"zed.exe", L"b.c - Zed"}, TICK(10)},
        {{"zed.exe", "a.c - Zed", 0, 7}, {"zed.exe", "b.c - Zed", 7, 3}}},
    {"sleep splits the event instead of counting the gap",
        {{0, WT, L"x"}, TICK(10), TICK(100), TICK(110)},
        {{"WindowsTerminal.exe", "x", 0, 10}, {"WindowsTerminal.exe", "x", 100, 10}}},
    {"rapid switching keeps every duration",
        {{0, L"a.exe", L"A"}, {0.4, L"b.exe", L"B"}, {0.9, L"a.exe", L"A"}, {1.5, L"b.exe", L"B"}, TICK(2)},
        {{"a.exe", "A", 0, 0.4}, {"b.exe", "B", 0.4, 0.5}, {"a.exe", "A", 0.9, 0.6}, {"b.exe", "B", 1.5, 0.5}}},
};

/* Scenario time t is seconds after 2026-01-01T00:00:00Z. */
static void stamp(double t, char *out, size_t size) {
    SYSTEMTIME base = {2026, 1, 4, 1, 0, 0, 0, 0}, when;
    FILETIME file;
    SystemTimeToFileTime(&base, &file);
    ULONGLONG ticks = ((ULONGLONG)file.dwHighDateTime << 32 | file.dwLowDateTime) + (ULONGLONG)(t * 1e7 + 0.5);
    file.dwLowDateTime = (DWORD)ticks, file.dwHighDateTime = (DWORD)(ticks >> 32);
    FileTimeToSystemTime(&file, &when);
    format_timestamp(&when, out, size);
}

static double seconds_of(const char *timestamp) {
    int year, month, day, hour, minute;
    double second;
    sscanf(timestamp, "%d-%d-%dT%d:%d:%lf", &year, &month, &day, &hour, &minute, &second);
    return (day - 1) * 86400.0 + hour * 3600.0 + minute * 60.0 + second;
}

typedef struct {
    char app[64], title[64];
    double start, duration;
} Event;

static Event events[64];
static int event_count;

/* aw-server's heartbeat rule (aw_server/api.py heartbeat). */
static void model_server(const Window *window, const char *timestamp) {
    double t = seconds_of(timestamp), pulsetime = atof(PULSETIME);
    Event *last = event_count ? &events[event_count - 1] : NULL;
    if (last && strcmp(last->app, window->app) == 0 && strcmp(last->title, window->title) == 0
        && t >= last->start && t <= last->start + last->duration + pulsetime) {
        if (t - last->start > last->duration) last->duration = t - last->start;
        return;
    }
    Event *event = &events[event_count++];
    snprintf(event->app, sizeof event->app, "%s", window->app);
    snprintf(event->title, sizeof event->title, "%s", window->title);
    event->start = t, event->duration = 0;
}

static void play(const Scenario *scenario) {
    have_current = 0;
    for (const Step *step = scenario->steps; step->at || step->app || step == scenario->steps; step++) {
        char timestamp[64];
        stamp(step->at, timestamp, sizeof timestamp);
        if (!step->app) keep_alive(timestamp);
        else {
            Window window;
            make_window(step->app, step->title, &window);
            observe(&window, timestamp);
        }
    }
}

static void check_events(const Scenario *scenario, const char *where) {
    int expected = 0;
    while (expected < 8 && scenario->events[expected].app) expected++;
    int ok = event_count == expected;
    for (int i = 0; ok && i < expected; i++) {
        const Expected *want = &scenario->events[i];
        const Event *got = &events[i];
        ok = strcmp(got->app, want->app) == 0 && strcmp(got->title, want->title) == 0
            && got->start > want->start - 0.001 && got->start < want->start + 0.001
            && got->duration > want->duration - 0.001 && got->duration < want->duration + 0.001;
    }
    if (ok) return;
    printf("%s: \"%s\"\n  got:\n", where, scenario->name);
    for (int i = 0; i < event_count; i++)
        printf("    %-20s %-10s %7.3f + %7.3f\n", events[i].app, events[i].title, events[i].start, events[i].duration);
    printf("  want:\n");
    for (int i = 0; i < expected; i++)
        printf("    %-20s %-10s %7.3f + %7.3f\n", scenario->events[i].app, scenario->events[i].title, scenario->events[i].start, scenario->events[i].duration);
    failures++;
}

static void test_scenarios_against_model(void) {
    send_heartbeat = model_server;
    for (size_t i = 0; i < sizeof scenarios / sizeof *scenarios; i++) {
        event_count = 0;
        play(&scenarios[i]);
        check_events(&scenarios[i], "model");
    }
}

/* ---- Real aw-server ---- */

/* The value after "key": in a JSON object, crudely; enough for aw-server's
   flat event objects. */
static const char *value_of(const char *object, const char *key) {
    char quoted[32];
    snprintf(quoted, sizeof quoted, "\"%s\"", key);
    const char *at = strstr(object, quoted);
    if (!at) return NULL;
    at += strlen(quoted);
    while (*at == ' ' || *at == ':') at++;
    return at;
}

static void copy_string(const char *value, char *out, size_t size) {
    size_t n = 0;
    if (value && *value == '"')
        for (value++; *value && *value != '"' && n + 1 < size; value++) out[n++] = *value;
    out[n] = 0;
}

static int test_scenarios_against_server(void) {
    static char response[1 << 16];
    connect_server(5666, "windots-test-probe", "test");
    if (!request(L"GET", "/api/0/info", NULL, response, sizeof response)) {
        printf("aw-server --testing is not running on port 5666\n");
        return 0;
    }
    send_heartbeat = heartbeat_to_server;
    for (size_t i = 0; i < sizeof scenarios / sizeof *scenarios; i++) {
        char bucket[64], path[160];
        snprintf(bucket, sizeof bucket, "windots-test-window-watcher-%zu", i);
        snprintf(path, sizeof path, "/api/0/buckets/%s?force=1", bucket);
        request(L"DELETE", path, NULL, NULL, 0);
        connect_server(5666, bucket, "test");
        play(&scenarios[i]);

        snprintf(path, sizeof path, "/api/0/buckets/%s/events?limit=100", bucket);
        request(L"GET", path, NULL, response, sizeof response);
        /* Newest first; one object per "id". */
        event_count = 0;
        for (const char *at = strstr(response, "\"id\""); at && event_count < 64; at = strstr(at + 1, "\"id\"")) {
            Event *event = &events[event_count++];
            const char *end = strstr(at + 1, "\"id\"");
            char object[1024] = "";
            size_t length = end ? (size_t)(end - at) : strlen(at);
            snprintf(object, sizeof object, "%.*s", (int)(length < sizeof object ? length : sizeof object - 1), at);
            char timestamp[64];
            copy_string(value_of(object, "timestamp"), timestamp, sizeof timestamp);
            copy_string(value_of(object, "app"), event->app, sizeof event->app);
            copy_string(value_of(object, "title"), event->title, sizeof event->title);
            event->start = seconds_of(timestamp);
            event->duration = atof(value_of(object, "duration"));
        }
        for (int a = 0, b = event_count - 1; a < b; a++, b--) {
            Event swap = events[a];
            events[a] = events[b], events[b] = swap;
        }
        check_events(&scenarios[i], "aw-server");
        snprintf(path, sizeof path, "/api/0/buckets/%s?force=1", bucket);
        request(L"DELETE", path, NULL, NULL, 0);
    }
    return 1;
}

int main(int argc, char **argv) {
    test_strip_status();
    test_json();
    test_scenarios_against_model();
    if (argc > 1 && strcmp(argv[1], "--server") == 0 && !test_scenarios_against_server()) return 2;
    if (failures) printf("%d window-watcher test(s) failed\n", failures);
    else printf("window-watcher tests passed\n");
    return failures != 0;
}
