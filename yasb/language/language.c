/*
 * Prints the focused window's input language as JSON for the YASB language
 * widget: {"code": "en", "name": "English (United States)"}. Native so the
 * widget can poll twice a second: YASB's own language widget polls too, in
 * whole seconds only, since Windows sends no system-wide event on a switch
 * (WM_INPUTLANGCHANGE reaches only the focused window).
 *
 * The layout is per thread, so it is read from the foreground window's
 * thread, as YASB's widget does; with no foreground window, from this one.
 *
 * Build: pwsh -File ../Build-Native.ps1 language.c (setup runs it too).
 * Tests: language.test.c (scripts/Test-Windots.ps1 runs them).
 */
#include <windows.h>
#include <stdio.h>

/* The widget's JSON line for a keyboard layout handle. */
static void describe(HKL layout, char *out, size_t size) {
    LCID locale = MAKELCID(LOWORD((ULONG_PTR)layout), SORT_DEFAULT);
    char code[16] = "", name[128] = "";
    WCHAR wide[128] = L"";
    GetLocaleInfoA(locale, LOCALE_SISO639LANGNAME, code, sizeof code);
    /* English, so it stays ASCII and needs no JSON escaping. The A function
       rejects this Windows 7 field (ERROR_INVALID_FLAGS); only W has it. */
    if (GetLocaleInfoW(locale, LOCALE_SENGLISHDISPLAYNAME, wide, ARRAYSIZE(wide)))
        WideCharToMultiByte(CP_UTF8, 0, wide, -1, name, sizeof name, NULL, NULL);
    snprintf(out, size, "{\"code\": \"%s\", \"name\": \"%s\"}", code, name);
}

int main(void) {
    HWND window = GetForegroundWindow();
    DWORD thread = window ? GetWindowThreadProcessId(window, NULL) : 0;
    char json[192];
    describe(GetKeyboardLayout(thread), json, sizeof json);
    puts(json);
    return 0;
}
