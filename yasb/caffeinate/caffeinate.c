/*
 * Keeps the PC awake, like Noctalia's caffeine widget, for the YASB caffeinate
 * widget. Three modes:
 *   caffeinate.exe           holds the awake state until told to stop (a
 *                            detached background process; a second one exits)
 *   caffeinate.exe --toggle  stops the holder, or starts one
 *   caffeinate.exe --status  prints {"icon": "<glyph>"} for the widget
 *
 * The awake state belongs to a thread, so a process has to stay alive to hold
 * it; a named event is both its "running" flag and its stop signal.
 *
 * Build: pwsh -File ../Build-Native.ps1 caffeinate.c -Windows (setup runs it too).
 * Tests: caffeinate.test.c (scripts/Test-Windots.ps1 runs them).
 */
#include <windows.h>
#include <stdio.h>
#include <string.h>

#define EVENT_NAME "Local\\windots-caffeinate"

/* Tabler Icons glyphs as UTF-8: the filled mug while awake, the outline mug-off otherwise. */
static void describe(int awake, char *out, size_t size) {
    snprintf(out, size, "{\"icon\": \"%s\"}", awake ? "\xf0\x90\x80\x89" : "\xef\x85\xa5");
}

static HANDLE open_running(DWORD access) {
    return OpenEventA(access, FALSE, EVENT_NAME);
}

static int hold(void) {
    HANDLE stop = CreateEventA(NULL, TRUE, FALSE, EVENT_NAME);
    if (!stop || GetLastError() == ERROR_ALREADY_EXISTS) return 0;
    SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED);
    WaitForSingleObject(stop, INFINITE);
    return 0;
}

static int toggle(void) {
    HANDLE running = open_running(EVENT_MODIFY_STATE);
    if (running) return SetEvent(running) ? 0 : 1;
    char path[MAX_PATH], command[MAX_PATH + 2];
    GetModuleFileNameA(NULL, path, sizeof path);
    snprintf(command, sizeof command, "\"%s\"", path);
    return WinExec(command, SW_HIDE) > 31 ? 0 : 1;
}

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "--toggle") == 0) return toggle();
    if (argc > 1 && strcmp(argv[1], "--status") == 0) {
        char json[64];
        describe(open_running(SYNCHRONIZE) != NULL, json, sizeof json);
        puts(json);
        return 0;
    }
    return hold();
}
