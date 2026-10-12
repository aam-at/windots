/*
 * Turns the display off when the screen brightness drops to zero, like
 * Noctalia does on CachyOS. Runs in the background; a second copy exits.
 *
 * Windows posts an event for every brightness change (the "Display brightness"
 * power setting), so there is no polling. Raising the brightness from zero
 * wakes the display. If the display wakes while brightness is 0 (the mouse
 * moved), it is put back to sleep, so it stays off until brightness goes up.
 *
 * Build: pwsh -File ../Build-Native.ps1 brightness.c -Windows (setup runs it too).
 * Tests: brightness.test.c (scripts/Test-Windots.ps1 runs them).
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#define MUTEX_NAME "Local\\windots-brightness-off"
#define WINDOW_CLASS "windots-brightness"

/* aded5e82-b909-4619-9949-f5d71dac0bcb: "Display brightness" in powercfg. */
static const GUID DISPLAY_BRIGHTNESS = {
    0xaded5e82, 0xb909, 0x4619, {0x99, 0x49, 0xf5, 0xd7, 0x1d, 0xac, 0x0b, 0xcb}};
/* 6fe69556-704a-47a0-8f24-c28d936fda47: console display state, 0 off, 1 on, 2 dim. */
static const GUID DISPLAY_STATE = {
    0x6fe69556, 0x704a, 0x47a0, {0x8f, 0x24, 0xc2, 0x8d, 0x93, 0x6f, 0xda, 0x47}};

static int brightness = -1;

static int should_turn_off(int previous, int current) {
    return previous > 0 && current == 0;
}

static int should_turn_on(int previous, int current) {
    return previous == 0 && current > 0;
}

/* The display woke while brightness is 0 (the mouse touched it): put it back to sleep.
 */
static int should_sleep_again(int level, int state) { return level == 0 && state != 0; }

/* Sent to our own window, not HWND_BROADCAST: a broadcast waits on every open
 * window's message queue, so one slow window delayed the display by seconds
 * and could even replay a stale "off" after the wake. */
static void display_off(HWND window) {
    DefWindowProcA(window, WM_SYSCOMMAND, SC_MONITORPOWER, 2);
}

static void display_on(HWND window) {
    DefWindowProcA(window, WM_SYSCOMMAND, SC_MONITORPOWER, -1);
    /* A zero-distance mouse move is the input Windows needs to light the screen. */
    mouse_event(MOUSEEVENTF_MOVE, 0, 0, 0, 0);
}

static LRESULT CALLBACK on_message(HWND window, UINT message, WPARAM wparam,
                                   LPARAM lparam) {
    if (message == WM_POWERBROADCAST && wparam == PBT_POWERSETTINGCHANGE) {
        POWERBROADCAST_SETTING *setting = (POWERBROADCAST_SETTING *)lparam;
        if (setting->DataLength != sizeof(DWORD)) return TRUE;
        int value = (int)*(DWORD *)setting->Data;
        if (IsEqualGUID(&setting->PowerSetting, &DISPLAY_STATE)) {
            if (should_sleep_again(brightness, value)) display_off(window);
        } else if (IsEqualGUID(&setting->PowerSetting, &DISPLAY_BRIGHTNESS)) {
            if (should_turn_off(brightness, value))
                display_off(window);
            else if (should_turn_on(brightness, value))
                display_on(window);
            brightness = value;
        }
        return TRUE;
    }
    return DefWindowProcA(window, message, wparam, lparam);
}

int main(void) {
    HANDLE mutex = CreateMutexA(NULL, FALSE, MUTEX_NAME);
    if (!mutex || GetLastError() == ERROR_ALREADY_EXISTS) return 0;

    WNDCLASSA wc = {0};
    wc.lpfnWndProc = on_message;
    wc.lpszClassName = WINDOW_CLASS;
    RegisterClassA(&wc);

    HWND window = CreateWindowA(WINDOW_CLASS, WINDOW_CLASS, 0, 0, 0, 0, 0, HWND_MESSAGE,
                                NULL, NULL, NULL);
    if (!window) return 1;
    if (!RegisterPowerSettingNotification(window, &DISPLAY_BRIGHTNESS,
                                          DEVICE_NOTIFY_WINDOW_HANDLE) ||
        !RegisterPowerSettingNotification(window, &DISPLAY_STATE,
                                          DEVICE_NOTIFY_WINDOW_HANDLE))
        return 1;

    MSG msg;
    while (GetMessageA(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageA(&msg);
    }
    return 0;
}
