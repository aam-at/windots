/*
 * Tests for window-watcher.c. Run by scripts\Test-Windots.ps1, or by hand:
 *   gcc -Wall -I ~/dotfiles/tools/lib -o window-watcher.test.exe window-watcher.test.c -lws2_32
 *   window-watcher.test.exe            # logic, against a model of aw-server
 *   window-watcher.test.exe --server   # the same scenarios against a real
 *                                      # aw-server --testing on port 5666
 *
 * Each scenario is a script of focus changes, heartbeat ticks and input
 * checks, with the events ActivityWatch should end up with. The model
 * applies aw-server's heartbeat merge rule (aw_transform heartbeat_merge);
 * --server checks that the real server agrees with it.
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

enum { STEP_END, STEP_FOCUS, STEP_TICK, STEP_INPUT };

typedef struct {
    int kind; /* STEP_* */
    double at;
    const wchar_t *app, *title; /* STEP_FOCUS */
    double idle;                /* STEP_INPUT: seconds since the last input */
} Step;

/* An event, by the bucket's own data: app and title, or status. */
typedef struct {
    const char *first, *second;
    double start, duration;
} Expected;

typedef struct {
    const char *name;
    Bucket *bucket;
    Step steps[100];
    Expected events[8];
} Scenario;

#define AT(t, app, title) {STEP_FOCUS, t, app, title, 0}
#define TICK(t) {STEP_TICK, t, NULL, NULL, 0}
#define IDLE(t, idle) {STEP_INPUT, t, NULL, NULL, idle}
#define WT L"C:\\Program Files\\WindowsApps\\WindowsTerminal.exe"

static Scenario scenarios[] = {
    {"spinner title stays one event", &window_bucket,
        {AT(0, WT, L"\u25D0 Task"), AT(1, WT, L"\u25D1 Task"), AT(2, WT, L"\u25D0 Task"), AT(3, WT, L"\u25D1 Task"), AT(4, WT, L"\u25D0 Task"),
         AT(5, WT, L"\u25D1 Task"), AT(6, WT, L"\u25D0 Task"), AT(7, WT, L"\u25D1 Task"), AT(8, WT, L"\u25D0 Task"), AT(9, WT, L"\u25D1 Task"),
         TICK(10), AT(15, WT, L"\u2733 Task"), TICK(20), TICK(30)},
        {{"WindowsTerminal.exe", "Task", 0, 30}}},
    {"a switch closes the old event at that moment", &window_bucket,
        {AT(0, WT, L"Claude"), TICK(10), TICK(20), AT(25.5, L"msedge.exe", L"Docs"), AT(28.5, WT, L"Claude"), TICK(30), TICK(40)},
        {{"WindowsTerminal.exe", "Claude", 0, 25.5}, {"msedge.exe", "Docs", 25.5, 3}, {"WindowsTerminal.exe", "Claude", 28.5, 11.5}}},
    {"a new title in the same app is a new event", &window_bucket,
        {AT(0, L"zed.exe", L"\u25CF a.c - Zed"), AT(5, L"zed.exe", L"a.c - Zed"), AT(7, L"zed.exe", L"b.c - Zed"), TICK(10)},
        {{"zed.exe", "a.c - Zed", 0, 7}, {"zed.exe", "b.c - Zed", 7, 3}}},
    {"sleep splits the event instead of counting the gap", &window_bucket,
        {AT(0, WT, L"x"), TICK(10), TICK(100), TICK(110)},
        {{"WindowsTerminal.exe", "x", 0, 10}, {"WindowsTerminal.exe", "x", 100, 10}}},
    {"rapid switching keeps every duration", &window_bucket,
        {AT(0, L"a.exe", L"A"), AT(0.4, L"b.exe", L"B"), AT(0.9, L"a.exe", L"A"), AT(1.5, L"b.exe", L"B"), TICK(2)},
        {{"a.exe", "A", 0, 0.4}, {"b.exe", "B", 0.4, 0.5}, {"a.exe", "A", 0.9, 0.6}, {"b.exe", "B", 1.5, 0.5}}},
    /* Input until 60 s, none until 300 s, then input again: away from 3 min
       after the last input, and exactly one afk event for the gap. */
    {"away after 3 minutes, one event until back", &afk_bucket,
        {IDLE(0, 0), IDLE(5, 0), IDLE(10, 0), IDLE(30, 0), IDLE(60, 0), IDLE(65, 5), IDLE(120, 60), IDLE(235, 175),
         IDLE(240, 180), IDLE(245, 185), IDLE(250, 190), IDLE(295, 235), IDLE(300, 0), IDLE(305, 0), IDLE(400, 0)},
        {{"not-afk", NULL, 0, 60}, {"afk", NULL, 60.001, 239.999}, {"not-afk", NULL, 300.001, 99.999}}},
    /* The input at 180 s reaches the server with the next spaced heartbeat
       (30 s after the one at 175 s), not at once. */
    {"short pauses stay not-afk", &afk_bucket,
        {IDLE(0, 0), IDLE(5, 5), IDLE(100, 100), IDLE(175, 175), IDLE(180, 0), IDLE(200, 20), IDLE(210, 30)},
        {{"not-afk", NULL, 0, 180}}},
    /* Idle on start (e.g. the watcher starts on a locked screen). */
    {"already away on start", &afk_bucket,
        {IDLE(1000, 500), IDLE(1005, 505), IDLE(1010, 0), IDLE(1015, 5)},
        {{"not-afk", NULL, 500, 0}, {"afk", NULL, 500.001, 509.999}, {"not-afk", NULL, 1010.001, 0}}},
};

/* Scenario time t is seconds after 2026-01-01T00:00:00Z. */
static ULONGLONG ticks_at(double t) {
    SYSTEMTIME base = {2026, 1, 4, 1, 0, 0, 0, 0};
    FILETIME file;
    SystemTimeToFileTime(&base, &file);
    return ((ULONGLONG)file.dwHighDateTime << 32 | file.dwLowDateTime) + (ULONGLONG)(t * TICKS_PER_SECOND + 0.5);
}

static double seconds_of(const char *timestamp) {
    int year, month, day, hour, minute;
    double second;
    sscanf(timestamp, "%d-%d-%dT%d:%d:%lf", &year, &month, &day, &hour, &minute, &second);
    return (day - 1) * 86400.0 + hour * 3600.0 + minute * 60.0 + second;
}

/* The value after "key": in a JSON object, crudely; enough for aw-server's
   flat event objects and the watcher's own data. */
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

typedef struct {
    char first[64], second[64]; /* app and title, or status */
    double start, duration;
} Event;

static Event events[64];
static int event_count, heartbeats_sent;

static void read_data(const char *data, Event *event) {
    if (value_of(data, "status")) {
        copy_string(value_of(data, "status"), event->first, sizeof event->first);
        event->second[0] = 0;
    }
    else {
        copy_string(value_of(data, "app"), event->first, sizeof event->first);
        copy_string(value_of(data, "title"), event->second, sizeof event->second);
    }
}

/* aw-server's heartbeat rule (aw_transform heartbeat_merge): same data, at
   or after the last event's start and within pulsetime of its end, extends
   it to the heartbeat's end; anything else starts a new event. */
static void model_server(Bucket *bucket, ULONGLONG at, double duration, const char *data) {
    char timestamp[64];
    heartbeats_sent++;
    format_timestamp(at, timestamp, sizeof timestamp);
    double t = seconds_of(timestamp);
    Event heartbeat = {.start = t, .duration = duration};
    read_data(data, &heartbeat);
    Event *last = event_count ? &events[event_count - 1] : NULL;
    if (last && strcmp(last->first, heartbeat.first) == 0 && strcmp(last->second, heartbeat.second) == 0
        && t >= last->start && t <= last->start + last->duration + bucket->pulsetime) {
        double end = t - last->start + duration;
        if (end > last->duration) last->duration = end;
        return;
    }
    events[event_count++] = heartbeat;
}

static void play(const Scenario *scenario) {
    have_current = 0;
    afk = 0;
    afk_state_start = 0;
    afk_last_sent = 0;
    for (const Step *step = scenario->steps; step->kind != STEP_END; step++) {
        if (step->kind == STEP_TICK) keep_alive(ticks_at(step->at));
        else if (step->kind == STEP_INPUT) observe_input(ticks_at(step->at), step->idle);
        else {
            Window window;
            make_window(step->app, step->title, &window);
            observe(&window, ticks_at(step->at));
        }
    }
}

static void check_events(const Scenario *scenario, const char *where) {
    int expected = 0;
    while (expected < 8 && scenario->events[expected].first) expected++;
    int ok = event_count == expected;
    for (int i = 0; ok && i < expected; i++) {
        const Expected *want = &scenario->events[i];
        const Event *got = &events[i];
        ok = strcmp(got->first, want->first) == 0 && strcmp(got->second, want->second ? want->second : "") == 0
            && got->start > want->start - 0.0005 && got->start < want->start + 0.0005
            && got->duration > want->duration - 0.0005 && got->duration < want->duration + 0.0005;
    }
    if (ok) return;
    printf("%s: \"%s\"\n  got:\n", where, scenario->name);
    for (int i = 0; i < event_count; i++)
        printf("    %-20s %-10s %9.3f + %8.3f\n", events[i].first, events[i].second, events[i].start, events[i].duration);
    printf("  want:\n");
    for (int i = 0; i < expected; i++)
        printf("    %-20s %-10s %9.3f + %8.3f\n", scenario->events[i].first, scenario->events[i].second ? scenario->events[i].second : "",
            scenario->events[i].start, scenario->events[i].duration);
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

/* An hour of steady input, checked every 5 s: unchanged state goes out
   every 30 s, not on every check, and the event still covers the hour. */
static void test_afk_heartbeats_are_spaced(void) {
    send_heartbeat = model_server;
    event_count = heartbeats_sent = 0;
    afk = 0, afk_state_start = 0, afk_last_sent = 0;
    for (int t = 0; t <= 3600; t += 5) observe_input(ticks_at(t), 0);
    CHECK(heartbeats_sent == 3600 / 30 + 1);
    CHECK(event_count == 1 && events[0].duration > 3599.999);
}

/* ---- Real aw-server ---- */

static int test_scenarios_against_server(void) {
    static char response[1 << 16];
    http_port = 5666;
    if (!http_request("GET", "/api/0/info", NULL, response, sizeof response)) {
        printf("aw-server --testing is not running on port 5666\n");
        return 0;
    }
    send_heartbeat = heartbeat_to_server;
    for (size_t i = 0; i < sizeof scenarios / sizeof *scenarios; i++) {
        Scenario *scenario = &scenarios[i];
        char id[64], path[160];
        snprintf(id, sizeof id, "windots-test-window-watcher-%zu", i);
        snprintf(path, sizeof path, "/api/0/buckets/%s?force=1", id);
        http_request("DELETE", path, NULL, NULL, 0);
        Bucket saved = *scenario->bucket;
        setup_bucket(scenario->bucket, id, "test", scenario->bucket == &afk_bucket ? "afkstatus" : "currentwindow", "test");
        play(scenario);

        snprintf(path, sizeof path, "/api/0/buckets/%s/events?limit=100", id);
        http_request("GET", path, NULL, response, sizeof response);
        /* Newest first; one object per "id". */
        event_count = 0;
        for (const char *at = strstr(response, "\"id\""); at && event_count < 64; at = strstr(at + 1, "\"id\"")) {
            Event *event = &events[event_count++];
            const char *end = strstr(at + 1, "\"id\"");
            char object[1024] = "", timestamp[64];
            size_t length = end ? (size_t)(end - at) : strlen(at);
            snprintf(object, sizeof object, "%.*s", (int)(length < sizeof object ? length : sizeof object - 1), at);
            copy_string(value_of(object, "timestamp"), timestamp, sizeof timestamp);
            read_data(object, event);
            event->start = seconds_of(timestamp);
            event->duration = atof(value_of(object, "duration"));
        }
        for (int a = 0, b = event_count - 1; a < b; a++, b--) {
            Event swap = events[a];
            events[a] = events[b], events[b] = swap;
        }
        check_events(scenario, "aw-server");
        http_request("DELETE", path, NULL, NULL, 0);
        snprintf(path, sizeof path, "/api/0/buckets/%s?force=1", id);
        http_request("DELETE", path, NULL, NULL, 0);
        *scenario->bucket = saved;
    }
    printf("checked %zu scenarios against aw-server\n", sizeof scenarios / sizeof *scenarios);
    return 1;
}

int main(int argc, char **argv) {
    test_strip_status();
    test_json();
    test_scenarios_against_model();
    test_afk_heartbeats_are_spaced();
    if (argc > 1 && strcmp(argv[1], "--server") == 0 && !test_scenarios_against_server()) return 2;
    if (failures) printf("%d window-watcher test(s) failed\n", failures);
    else printf("window-watcher tests passed\n");
    return failures != 0;
}
