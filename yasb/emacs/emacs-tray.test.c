/*
 * Tests for emacs-tray.c's daemon state and icon choice. Run by
 * scripts\Test-Windots.ps1, or by hand:
 *   gcc -Wall -o emacs-tray.test.exe emacs-tray.test.c && emacs-tray.test.exe
 */
#define main emacs_tray_main
#include "emacs-tray.c"
#undef main

static int failures;

static void check(int line, int ok) {
    if (ok) return;
    printf("emacs-tray.test.c:%d: failed\n", line);
    failures++;
}

int main(void) {
    /* A server file naming this process is up; a missing file or the mutex decide the rest. */
    char temp[MAX_PATH], file[MAX_PATH];
    GetTempPathA(sizeof temp, temp);
    snprintf(file, sizeof file, "%sworking-server", temp);
    FILE *server = fopen(file, "w");
    fprintf(server, "127.0.0.1:1 %lu\nkey", GetCurrentProcessId());
    fclose(server);
    check(__LINE__, server_pid(file) == GetCurrentProcessId() && pid_alive(server_pid(file)));
    remove(file);
    check(__LINE__, server_pid(file) == 0 && !pid_alive(0));
    check(__LINE__, state("windots-test-profile") == STOPPED);
    HANDLE held = CreateMutexA(NULL, FALSE, "Local\\windots-emacs-daemon-windots-test-profile");
    check(__LINE__, state("windots-test-profile") == STARTING);
    CloseHandle(held);
    return failures != 0;
}
