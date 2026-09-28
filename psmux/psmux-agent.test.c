/*
 * Tests for psmux-agent.c. Run by scripts\Test-Windots.ps1, or by hand:
 *   gcc -Wall -I ~/dotfiles/tools/lib -o psmux-agent.test.exe psmux-agent.test.c -lws2_32
 */
/* The agent's main becomes agent_main; these tests are main. */
#define main agent_main
#include "psmux-agent.c"
#undef main

static int failures;

#define CHECK(condition) do { if (!(condition)) { printf("psmux-agent.test.c:%d: failed: %s\n", __LINE__, #condition); failures++; } } while (0)

static void check_str(int line, const char *actual, const char *expected) {
    if (strcmp(actual, expected) == 0) return;
    printf("psmux-agent.test.c:%d: got  \"%s\"\n                       want \"%s\"\n", line, actual, expected);
    failures++;
}
#define CHECK_STR(actual, expected) check_str(__LINE__, actual, expected)

static void test_status(void) {
    CHECK(cpu_percent(0, 0, 0, 0) == 0);                   /* no time passed */
    CHECK(cpu_percent(75, 100, 0, 0) == 25);
    CHECK(cpu_percent(1100, 2000, 1000, 1000) == 90);      /* deltas, not totals */
    CHECK(cpu_percent(500, 100, 0, 0) == 0);               /* torn sample */
    char out[256];
    format_status(12, 80, out, sizeof out);
    CHECK_STR(out, "#[fg=#b8bb26]CPU 12%#[default] #[fg=#fb4934]MEM 80%#[default]");
    format_status(30, 49, out, sizeof out);
    CHECK_STR(out, "#[fg=#fabd2f]CPU 30%#[default] #[fg=#b8bb26]MEM 49%#[default]");
}

static char sent[4096];
static int sends, send_ok = 1;
static int record(const char *body) { snprintf(sent, sizeof sent, "%s", body); sends++; return send_ok; }

static void test_heartbeat(void) {
    char line[] = "1790577849\tpwsh\tHOST\tnvim\tC:\\Users\\me \"x\"\n", body[4096];
    long long activity;
    CHECK(heartbeat_body("dev", line, "T", &activity, body, sizeof body));
    CHECK(activity == 1790577849);
    CHECK_STR(body, "{\"timestamp\": \"T\", \"duration\": 0, \"data\": {\"title\": \"dev\", \"session_name\": \"dev\", "
        "\"window_name\": \"pwsh\", \"pane_title\": \"HOST\", \"pane_current_command\": \"nvim\", "
        "\"pane_current_path\": \"C:\\\\Users\\\\me \\\"x\\\"\"}}");
    CHECK(heartbeat_body("dev", strcpy(line, "\t\t\t\t\n"), "T", &activity, body, sizeof body) == 0);
    CHECK(heartbeat_body("dev", strcpy(line, "no server\n"), "T", &activity, body, sizeof body) == 0);
    CHECK(heartbeat_body("dev", strcpy(line, "5\t\t\t\t"), "T", &activity, body, sizeof body) == 1); /* empty fields are fine */
}

static void test_track(void) {
    char line[64];
    track("a", strcpy(line, "100\tw\tt\tc\tp\n"), record);
    CHECK(sends == 1);
    track("a", strcpy(line, "100\tw\tt\tc\tp\n"), record);  /* no new activity */
    CHECK(sends == 1);
    track("b", strcpy(line, "100\tw\tt\tc\tp\n"), record);  /* per session */
    CHECK(sends == 2);
    send_ok = 0;
    track("a", strcpy(line, "101\tw\tt\tc\tp\n"), record);  /* aw-server down */
    send_ok = 1;
    track("a", strcpy(line, "101\tw\tt\tc\tp\n"), record);  /* so it goes out again */
    CHECK(sends == 4);
}

static void test_list_sessions(void) {
    GetTempPathA(sizeof psmux_dir, psmux_dir);
    strcat(psmux_dir, "psmux-agent-test");
    CreateDirectoryA(psmux_dir, NULL);
    const char *files[] = {"dev.port", "dev.key", "__warm__.port", "work__dev.port", "notes.port"};
    char path[MAX_PATH];
    for (int i = 0; i < 5; i++) {
        snprintf(path, sizeof path, "%s\\%s", psmux_dir, files[i]);
        fclose(fopen(path, "wb"));
    }
    char names[8][128];
    int count = list_sessions(names, 8);
    CHECK(count == 2);
    CHECK((strcmp(names[0], "dev") == 0 && strcmp(names[1], "notes") == 0) || (strcmp(names[0], "notes") == 0 && strcmp(names[1], "dev") == 0));
    /* An empty .port file is a server that isn't there. */
    char reply[64];
    CHECK(psmux_run("dev", "ls\n", reply, sizeof reply) == 0);
    for (int i = 0; i < 5; i++) {
        snprintf(path, sizeof path, "%s\\%s", psmux_dir, files[i]);
        DeleteFileA(path);
    }
    RemoveDirectoryA(psmux_dir);
}

int main(void) {
    test_status();
    test_heartbeat();
    test_track();
    test_list_sessions();
    if (failures) printf("%d failure(s)\n", failures);
    return failures != 0;
}
