/*
 * Tests for caffeinate.c's status line, and its toggle end to end. Run by
 * scripts\Test-Windots.ps1, or by hand:
 *   gcc -Wall -o caffeinate.test.exe caffeinate.test.c && caffeinate.test.exe
 */
#define main caffeinate_main
#include "caffeinate.c"
#undef main

static int failures;

static void check(int line, int ok) {
    if (ok) return;
    printf("caffeinate.test.c:%d: failed\n", line);
    failures++;
}

int main(void) {
    char json[64];
    describe(1, json, sizeof json);
    check(__LINE__, strcmp(json, "{\"icon\": \"\xf0\x90\x80\x89\"}") == 0);
    describe(0, json, sizeof json);
    check(__LINE__, strcmp(json, "{\"icon\": \"\xef\x85\xa5\"}") == 0);

    /* Holder in this process on a thread: the event is its running flag. */
    check(__LINE__, open_running(SYNCHRONIZE) == NULL);
    HANDLE holder = CreateThread(NULL, 0, (LPTHREAD_START_ROUTINE)hold, NULL, 0, NULL);
    for (int i = 0; i < 100 && !open_running(SYNCHRONIZE); i++) Sleep(10);
    check(__LINE__, open_running(SYNCHRONIZE) != NULL);
    check(__LINE__, toggle() == 0);
    check(__LINE__, WaitForSingleObject(holder, 2000) == WAIT_OBJECT_0);
    return failures != 0;
}
