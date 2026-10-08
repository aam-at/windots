/*
 * Tests for dictate.c. Run by scripts\Test-Windots.ps1, or by hand:
 *   gcc -Wall -I ~/dotfiles/tools/lib -o dictate.test.exe dictate.test.c -lwinmm
 */
/* The recorder's main becomes dictate_main; these tests are main. */
#define main dictate_main
#include "dictate.c"
#undef main

static int failures;

#define CHECK(condition)                                                               \
    do {                                                                               \
        if (!(condition)) {                                                            \
            printf("dictate.test.c:%d: failed: %s\n", __LINE__, #condition);           \
            failures++;                                                                \
        }                                                                              \
    } while (0)

static void check_str(int line, const char *actual, const char *expected) {
    if (strcmp(actual, expected) == 0) return;
    printf("dictate.test.c:%d: got  \"%s\"\n                  want \"%s\"\n", line,
           actual, expected);
    failures++;
}
#define CHECK_STR(actual, expected) check_str(__LINE__, actual, expected)

static void test_script_path(void) {
    char out[MAX_PATH];
    script_path_for("C:\\Users\\me\\windots\\yasb\\dictation\\dictate.exe", out,
                    sizeof out);
    CHECK_STR(out, "C:\\Users\\me\\windots\\yasb\\dictation\\..\\..\\scripts\\Toggle-"
                   "Dictation.ps1");
    script_path_for("dictate.exe", out,
                    sizeof out); /* no directory: relative to here */
    CHECK_STR(out, "\\..\\..\\scripts\\Toggle-Dictation.ps1");
}

static void test_status_json(void) {
    char out[128];
    status_json(
        "", out,
        sizeof out); /* idle: the microphone icon, so the widget stays on the bar */
    CHECK_STR(out, "{\"icon\": \"\\ue720\", \"text\": \"Dictation\"}");
    status_json("idle", out, sizeof out); /* unknown states are idle too */
    CHECK_STR(out, "{\"icon\": \"\\ue720\", \"text\": \"Dictation\"}");
    /* The icons are JSON escapes (\\u...), so the line stays ASCII. */
    status_json("starting", out, sizeof out); /* mic not live yet: wait */
    CHECK_STR(out, "{\"icon\": \"\\ud83d\\udfe1\", \"text\": \"Starting\"}");
    status_json("recording", out, sizeof out);
    CHECK_STR(out, "{\"icon\": \"\\ud83d\\udd34\", \"text\": \"Recording\"}");
    status_json("processing", out,
                sizeof out); /* from the stop press, before the worker starts */
    CHECK_STR(out, "{\"icon\": \"\\u23f3\", \"text\": \"Transcribing\"}");
    status_json("hot", out, sizeof out); /* the mic idling open looks idle */
    CHECK_STR(out, "{\"icon\": \"\\ue720\", \"text\": \"Dictation\"}");
}

int main(void) {
    test_status_json();
    test_script_path();
    if (failures) printf("%d failed\n", failures);
    return failures != 0;
}
