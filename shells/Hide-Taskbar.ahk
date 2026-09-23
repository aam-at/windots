#Requires AutoHotkey v2.0

; Hides the Windows taskbar for the desktop shells: the YASB bar is on top and
; the YASB dock slides in from the bottom edge, where the auto-hidden taskbar
; would otherwise pop up too. Include it once:
;   #Include %A_ScriptDir%\..\Hide-Taskbar.ahk
; Explorer recreates the taskbar when it restarts, so hide it again then. The
; taskbar comes back on sign-out or an Explorer restart without this script.

HideTaskbar(*) {
    for windowClass in ["Shell_TrayWnd", "Shell_SecondaryTrayWnd"]
        for hwnd in WinGetList("ahk_class " windowClass)
            WinHide hwnd
}

ShowTaskbar(*) {
    DetectHiddenWindows true
    for windowClass in ["Shell_TrayWnd", "Shell_SecondaryTrayWnd"]
        for hwnd in WinGetList("ahk_class " windowClass)
            WinShow hwnd
}

HideTaskbar()
; Explorer broadcasts TaskbarCreated after a restart; give it a moment to settle.
OnMessage DllCall("RegisterWindowMessage", "Str", "TaskbarCreated", "UInt"), (*) => SetTimer(HideTaskbar, -2000)
OnExit ShowTaskbar
