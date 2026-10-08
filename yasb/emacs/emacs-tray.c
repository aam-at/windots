/*
 * Tray icons for the Doom and Spacemacs daemons. YASB's systray lists them in
 * its popup, next to the other tray apps. Each icon is the profile's official
 * logo: gray when the daemon is not running, rotating while Emacs-Daemon.ps1
 * starts it, full color when it is up. Left-click opens a frame; right-click
 * offers Open, Start, Stop and Restart (Open and Restart start a stopped daemon).
 *
 * Up: the server file (<data>\emacs\<profile>\server\<profile>, "addr:port PID")
 * names a live process. Starting: Emacs-Daemon.ps1 holds the named mutex for
 * the whole start, which takes about a minute for Doom.
 *
 * Icons: icons\<profile>.ico, <profile>-off.ico, <profile>-spin0..11.ico.
 * Build: pwsh -File ../Build-Native.ps1 emacs-tray.c -Windows (setup runs it too).
 * Tests: emacs-tray.test.c (scripts/Test-Windots.ps1 runs them).
 */
#include <windows.h>
#include <shellapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { STOPPED, STARTING, RUNNING };
enum { ICON_COLOR, ICON_OFF, ICON_SPIN };

#define FRAMES 12
#define FRAME_MS 80
#define TRAY_MESSAGE (WM_APP + 1)

static const char *profiles[] = {"doom", "spacemacs"};
static const char *titles[] = {"Doom Emacs", "Spacemacs"};
static const char *status_words[] = {"not running", "starting", "running"};
static HICON icons[2][ICON_SPIN + FRAMES];
static int shown[2] = {-1, -1};
static char dir[MAX_PATH];
static UINT taskbar_created;

static int pid_alive(DWORD pid) {
    HANDLE process = OpenProcess(SYNCHRONIZE, FALSE, pid);
    if (!process) return 0;
    int alive = WaitForSingleObject(process, 0) == WAIT_TIMEOUT;
    CloseHandle(process);
    return alive;
}

/* The server file's first line is "addr:port PID"; 0 when absent or unreadable. */
static DWORD server_pid(const char *path) {
    FILE *file = fopen(path, "r");
    if (!file) return 0;
    char line[128];
    char *space = fgets(line, sizeof line, file) ? strchr(line, ' ') : NULL;
    fclose(file);
    return space ? (DWORD)strtoul(space + 1, NULL, 10) : 0;
}

static int state(const char *profile) {
    const char *data = getenv("XDG_DATA_HOME");
    char path[MAX_PATH], mutex[96];
    if (data && *data)
        snprintf(path, sizeof path, "%s\\emacs\\%s\\server\\%s", data, profile,
                 profile);
    else
        snprintf(path, sizeof path, "%s\\.local\\share\\emacs\\%s\\server\\%s",
                 getenv("USERPROFILE"), profile, profile);
    if (pid_alive(server_pid(path))) return RUNNING;
    snprintf(mutex, sizeof mutex, "Local\\windots-emacs-daemon-%s", profile);
    HANDLE starting = OpenMutexA(SYNCHRONIZE, FALSE, mutex);
    if (!starting) return STOPPED;
    CloseHandle(starting);
    return STARTING;
}

/* Which icon to show: color when up, gray when not running, a spin frame by the clock
 * while starting. */
static int icon_index(int state, DWORD tick) {
    if (state == RUNNING) return ICON_COLOR;
    if (state == STOPPED) return ICON_OFF;
    return ICON_SPIN + (int)(tick / FRAME_MS % FRAMES);
}

/* conhost --headless runs pwsh with no console window, like the Start menu links. */
static void daemon_command(const char *dir, const char *action, const char *profile,
                           char *out, size_t size) {
    snprintf(out, size,
             "conhost.exe --headless pwsh -NoProfile -ExecutionPolicy Bypass -File "
             "\"%s\\..\\..\\scripts\\Emacs-Daemon.ps1\" %s %s",
             dir, action, profile);
}

static void run_action(const char *action, const char *profile) {
    char command[MAX_PATH + 192];
    daemon_command(dir, action, profile, command, sizeof command);
    WinExec(command, SW_HIDE);
}

static void menu(HWND window, int which) {
    const char *actions[] = {NULL, "open", "start", "stop", "restart"};
    int current = state(profiles[which]);
    HMENU popup = CreatePopupMenu();
    UINT disabled = current == STARTING ? MF_GRAYED : 0;
    AppendMenuA(popup, MF_STRING | disabled, 1, "Open");
    AppendMenuA(popup, MF_STRING | (current == STOPPED ? 0 : MF_GRAYED), 2, "Start");
    AppendMenuA(popup, MF_STRING | (current == RUNNING ? 0 : MF_GRAYED), 3, "Stop");
    AppendMenuA(popup, MF_STRING | disabled, 4, "Restart");
    POINT cursor;
    GetCursorPos(&cursor);
    SetForegroundWindow(window);
    int choice = TrackPopupMenu(popup, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTALIGN,
                                cursor.x, cursor.y, 0, window, NULL);
    PostMessageA(window, WM_NULL, 0, 0);
    DestroyMenu(popup);
    if (choice >= 1 && choice <= 4) run_action(actions[choice], profiles[which]);
}

/* Adds the icon, or changes it when the state or spin frame differs from what is shown.
   A failed add (no tray host yet, early at sign-in) is retried on the next tick. */
static void refresh(HWND window, int which) {
    int current = state(profiles[which]);
    int index = icon_index(current, GetTickCount());
    if (index == shown[which]) return;
    NOTIFYICONDATAA data = {sizeof data};
    data.hWnd = window;
    data.uID = which;
    data.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    data.uCallbackMessage = TRAY_MESSAGE;
    data.hIcon = icons[which][index];
    snprintf(data.szTip, sizeof data.szTip, "%s: %s", titles[which],
             status_words[current]);
    if (Shell_NotifyIconA(shown[which] < 0 ? NIM_ADD : NIM_MODIFY, &data))
        shown[which] = index;
}

static LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM wparam,
                                    LPARAM lparam) {
    if (message == WM_TIMER) {
        for (int i = 0; i < 2; i++) refresh(window, i);
    } else if (message == taskbar_created) {
        /* Explorer or YASB's systray (re)started and lost every icon: add them again.
         */
        shown[0] = shown[1] = -1;
    } else if (message == TRAY_MESSAGE && wparam < 2) {
        if (lparam == WM_LBUTTONUP)
            run_action("open", profiles[wparam]);
        else if (lparam == WM_RBUTTONUP)
            menu(window, (int)wparam);
    } else if (message == WM_DESTROY) {
        for (int i = 0; i < 2; i++) {
            NOTIFYICONDATAA data = {sizeof data};
            data.hWnd = window;
            data.uID = i;
            Shell_NotifyIconA(NIM_DELETE, &data);
        }
        PostQuitMessage(0);
    }
    return DefWindowProcA(window, message, wparam, lparam);
}

static HICON load_icon(const char *profile, const char *name) {
    char path[MAX_PATH];
    int size = GetSystemMetrics(SM_CXSMICON);
    snprintf(path, sizeof path, "%s\\icons\\%s%s.ico", dir, profile, name);
    return LoadImageA(NULL, path, IMAGE_ICON, size, size, LR_LOADFROMFILE);
}

int main(void) {
    GetModuleFileNameA(NULL, dir, sizeof dir);
    *strrchr(dir, '\\') = 0;
    for (int i = 0; i < 2; i++) {
        icons[i][ICON_COLOR] = load_icon(profiles[i], "");
        icons[i][ICON_OFF] = load_icon(profiles[i], "-off");
        for (int frame = 0; frame < FRAMES; frame++) {
            char name[16];
            snprintf(name, sizeof name, "-spin%d", frame);
            icons[i][ICON_SPIN + frame] = load_icon(profiles[i], name);
        }
    }
    taskbar_created = RegisterWindowMessageA("TaskbarCreated");
    WNDCLASSA window_class = {0};
    window_class.lpfnWndProc = window_proc;
    window_class.hInstance = GetModuleHandleA(NULL);
    window_class.lpszClassName = "windots-emacs-tray";
    RegisterClassA(&window_class);
    HWND window =
        CreateWindowExA(WS_EX_TOOLWINDOW, window_class.lpszClassName, "", WS_POPUP, 0,
                        0, 0, 0, NULL, NULL, window_class.hInstance, NULL);
    for (int i = 0; i < 2; i++) refresh(window, i);
    SetTimer(window, 1, FRAME_MS, NULL);
    MSG message;
    while (GetMessageA(&message, NULL, 0, 0) > 0) DispatchMessageA(&message);
    return 0;
}
