#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon
; Hook every hotkey so Send("#{Left}") etc. from inside a Win hotkey reaches
; Windows/FancyZones instead of re-triggering this script.
#UseHook

; Native Windows desktop controls with the niri muscle memory
; (~/dotfiles/config/niri/common/binds.kdl). Win is Mod, as in niri.
; Win+L is free for focus-right because setup\Install-Startup.ps1 sets
; DisableLockWorkstation; Win+Alt+L and the Win+X menu lock. Launchers, panels
; and other mode-independent keys live in ..\Niri-Common.ahk.
;
; Trade-offs against komorebi.ahk, taken so Windows keeps its own keys where it
; already does the job:
; - Win+Arrows stay Windows': Snap/FancyZones on Left/Right, maximize and
;   minimize on Up/Down. Komorebi aliases them to Win+H/J/K/L focus.
; - Win+Shift+Left/Right stay Windows' move-to-monitor, Win+Shift+Up/Down its
;   vertical stretch. Komorebi aliases them to Win+Shift+H/J/K/L.
; - Win+Ctrl+Left/Right stay Windows' previous/next desktop. Komorebi uses them
;   for monitor focus; Win+Ctrl+H/L do that here too.
; - Win+J/K cycle the windows on the focused monitor, topmost first. Windows
;   overlap or sit maximized here, so this stands in for Komorebi's stack cycle.
; - No column stacking (Win+[ ] .) or floating layer (Win+Shift+V): nothing
;   tiles. Win+Shift+T pins on top instead of floating.

; VirtualDesktopAccessor switches and moves windows between desktops, which
; Windows has no public API for (https://github.com/Ciantic/VirtualDesktopAccessor).
; setup\Install-Apps.ps1 downloads it to %LOCALAPPDATA%\VirtualDesktopAccessor.
VDA_Path := EnvGet("LOCALAPPDATA") "\VirtualDesktopAccessor\VirtualDesktopAccessor.dll"
hVirtualDesktopAccessor := DllCall("LoadLibrary", "Str", VDA_Path, "Ptr")
if !hVirtualDesktopAccessor {
    MsgBox "Cannot load " VDA_Path "`nRun setup\Install-Apps.ps1 to download it.", "Native Desktop", "Iconx"
    ExitApp 1
}
VDA_GoToDesktopNumber := DllCall("GetProcAddress", "Ptr", hVirtualDesktopAccessor, "AStr", "GoToDesktopNumber", "Ptr")
VDA_MoveWindowToDesktopNumber := DllCall("GetProcAddress", "Ptr", hVirtualDesktopAccessor, "AStr", "MoveWindowToDesktopNumber", "Ptr")
VDA_GetCurrentDesktopNumber := DllCall("GetProcAddress", "Ptr", hVirtualDesktopAccessor, "AStr", "GetCurrentDesktopNumber", "Ptr")
VDA_GetDesktopCount := DllCall("GetProcAddress", "Ptr", hVirtualDesktopAccessor, "AStr", "GetDesktopCount", "Ptr")

; A desktop switch, by VDA or Windows itself, can leave the foreground on the
; old desktop's now-cloaked window: WinExist("A") is then 0, so Win+H/J/K/L do
; nothing, and new windows (Win+T) open behind. VDA posts this message on every
; switch; focus the new desktop's top window unless Windows already did.
VDA_RegisterPostMessageHook := DllCall("GetProcAddress", "Ptr", hVirtualDesktopAccessor, "AStr", "RegisterPostMessageHook", "Ptr")
DllCall(VDA_RegisterPostMessageHook, "Ptr", A_ScriptHwnd, "Int", 0x1400 + 30, "Int")
OnMessage 0x1400 + 30, (*) => WinExist("A") || FocusTopWindow()

#Include %A_ScriptDir%\..\Niri-Common.ahk

#d::Send "#{Tab}"   ; niri overview: Task View

; === Helpers ===

ToggleMaximize() {
    if WinGetMinMax("A") = 1
        WinRestore "A"
    else
        WinMaximize "A"
}

IsFocusable(hwnd, minimized := false) {
    ; A window can close between WinGetList and these queries (e.g. the quake
    ; terminal hiding), which makes them throw "Target window not found".
    try {
        if (!minimized && WinGetMinMax(hwnd) = -1) || WinGetTitle(hwnd) = ""
            return false
        if WinGetClass(hwnd) ~= "^(Progman|WorkerW|Shell_TrayWnd|Shell_SecondaryTrayWnd)$"
            return false
        ; WS_VISIBLE and not WS_EX_TOOLWINDOW
        if !(WinGetStyle(hwnd) & 0x10000000) || (WinGetExStyle(hwnd) & 0x80)
            return false
    } catch
        return false
    ; Windows on other virtual desktops and suspended UWP frames are cloaked.
    cloaked := 0
    DllCall("dwmapi\DwmGetWindowAttribute", "Ptr", hwnd, "UInt", 14, "UInt*", &cloaked, "UInt", 4)
    return !cloaked
}

; Topmost window on this desktop, or the desktop itself when it has none.
FocusTopWindow() {
    for hwnd in WinGetList()   ; z-order, topmost first
        if IsFocusable(hwnd)
            return WinActivate(hwnd)
    WinActivate "ahk_class Progman"
}

; niri focus-column-left/right: activate the nearest
; window whose centre lies in that direction, preferring ones in line.
; ponytail: centre-distance heuristic; overlapping windows with the same centre are skipped.
FocusDirection(dir, *) {
    if !(hwnd := WinExist("A"))
        return
    WinGetPos &x, &y, &w, &h, hwnd
    cx := x + w / 2, cy := y + h / 2
    best := 0, bestScore := 0
    for candidate in WinGetList() {
        if candidate = hwnd || !IsFocusable(candidate)
            continue
        WinGetPos &x2, &y2, &w2, &h2, candidate
        dx := x2 + w2 / 2 - cx, dy := y2 + h2 / 2 - cy
        along := dir = "left" ? -dx : dx
        if along <= 0
            continue
        score := along + 2 * Abs(dy)
        if !best || score < bestScore
            best := candidate, bestScore := score
    }
    if best
        WinActivate best
}

; niri focus-window-down/up (Komorebi cycle-stack): walk the windows on the
; active window's monitor in z-order. Next sends the active window to the back.
CycleWindow(next) {
    if !(hwnd := WinExist("A"))
        return
    ; The desktop or taskbar has focus: use the monitor under the mouse.
    onShell := WinGetClass(hwnd) ~= "^(Progman|WorkerW|Shell_TrayWnd|Shell_SecondaryTrayWnd)$"
    if onShell {
        CoordMode "Mouse", "Screen"
        MouseGetPos &x, &y
        monitor := MonitorOf(x, y)
    } else {
        WinGetPos &x, &y, &w, &h, hwnd
        monitor := MonitorOf(x + w / 2, y + h / 2)
    }
    windows := []
    for candidate in WinGetList() {   ; z-order, topmost first
        if candidate != hwnd && IsFocusable(candidate, true) {
            ; A minimized window has no usable position, so it joins the cycle on every monitor.
            try {
                WinGetPos &x, &y, &w, &h, candidate
                if WinGetMinMax(candidate) = -1 || MonitorOf(x + w / 2, y + h / 2) = monitor
                    windows.Push(candidate)
            }
        }
    }
    if !windows.Length
        return
    if next {
        if !onShell
            WinMoveBottom hwnd
        WinActivate windows[1]
    } else
        WinActivate windows[-1]
}

; niri center-column
CenterWindow() {
    if !(hwnd := WinExist("A"))
        return
    if WinGetMinMax(hwnd) != 0
        WinRestore hwnd
    WinGetPos &x, &y, &w, &h, hwnd
    MonitorGetWorkArea MonitorOf(x + w / 2, y + h / 2), &left, &top, &right, &bottom
    WinMove left + (right - left - w) // 2, top + (bottom - top - h) // 2, , , hwnd
}

; niri focus-monitor-left/right (Komorebi cycle-monitor): activate the topmost
; window on the previous or next monitor, in monitor index order.
FocusMonitor(delta) {
    if !(hwnd := WinExist("A"))
        return
    WinGetPos &x, &y, &w, &h, hwnd
    count := MonitorGetCount()
    target := Mod(MonitorOf(x + w / 2, y + h / 2) - 1 + delta + count, count) + 1
    for candidate in WinGetList() {   ; z-order, topmost first
        if candidate = hwnd || !IsFocusable(candidate)
            continue
        WinGetPos &x, &y, &w, &h, candidate
        if MonitorOf(x + w / 2, y + h / 2) = target
            return WinActivate(candidate)
    }
}

; niri set-column-width/set-window-height by a tenth of the work area, about
; the window's centre.
ResizeActive(dw, dh) {
    if !(hwnd := WinExist("A"))
        return
    if WinGetMinMax(hwnd) != 0
        WinRestore hwnd
    WinGetPos &x, &y, &w, &h, hwnd
    MonitorGetWorkArea MonitorOf(x + w / 2, y + h / 2), &left, &top, &right, &bottom
    dw *= (right - left) / 10, dh *= (bottom - top) / 10
    WinMove x - dw / 2, y - dh / 2, w + dw, h + dh, hwnd
}

; niri switch-preset-column-width: cycle 1/3, 1/2 and full work-area width.
; ponytail: one counter for all windows, as komorebi.ahk's CycleColumns.
CycleWidth() {
    static presets := [1 / 3, 1 / 2, 1], i := 2
    if !(hwnd := WinExist("A"))
        return
    i := Mod(i, presets.Length) + 1
    if WinGetMinMax(hwnd) != 0
        WinRestore hwnd
    WinGetPos &x, &y, &w, &h, hwnd
    MonitorGetWorkArea MonitorOf(x + w / 2, y + h / 2), &left, &top, &right, &bottom
    nw := (right - left) * presets[i]
    nx := Min(Max(x + (w - nw) / 2, left), right - nw)
    WinMove nx, , nw, , hwnd
}

GoToDesktop(target, *) {
    DllCall(VDA_GoToDesktopNumber, "Int", target - 1, "Int")
}

MoveWindowToDesktop(target, *) {
    if !(hwnd := WinExist("A"))
        return
    DllCall(VDA_MoveWindowToDesktopNumber, "Ptr", hwnd, "Int", target - 1, "Int")
    DllCall(VDA_GoToDesktopNumber, "Int", target - 1, "Int")
}

MoveWindowToRelativeDesktop(delta) {
    if !(hwnd := WinExist("A"))
        return
    current := DllCall(VDA_GetCurrentDesktopNumber, "Int")
    count := DllCall(VDA_GetDesktopCount, "Int")
    target := Mod(current + delta + count, count)
    DllCall(VDA_MoveWindowToDesktopNumber, "Ptr", hwnd, "Int", target, "Int")
    DllCall(VDA_GoToDesktopNumber, "Int", target, "Int")
}

; === Window Management ===
#f::ToggleMaximize()
#+f::Send "{F11}"
#+t::Send "#^t"                 ; PowerToys Always On Top (niri toggle-window-floating)
#+c::CenterWindow()

; === Sizing ===
#r::CycleWidth()
#-::ResizeActive(-1, 0)
#=::ResizeActive(1, 0)
#+-::ResizeActive(0, -1)
#+=::ResizeActive(0, 1)

; === Focus Navigation ===
#h::FocusDirection("left")
#j::CycleWindow(true)
#k::CycleWindow(false)
#l::FocusDirection("right")

; === Window Movement (FancyZones snaps on Win+Arrow) ===
#+h::Send "#{Left}"
#+j::Send "#{Down}"
#+k::Send "#{Up}"
#+l::Send "#{Right}"

; === Monitor Navigation ===
#^h::FocusMonitor(-1)
#^l::FocusMonitor(1)
#+^h::Send "#+{Left}"
#+^l::Send "#+{Right}"

; === Workspace Navigation ===
#u::Send "#^{Right}"
#i::Send "#^{Left}"
#PgDn::Send "#^{Right}"
#PgUp::Send "#^{Left}"
#^u::MoveWindowToRelativeDesktop(1)
#^i::MoveWindowToRelativeDesktop(-1)
#^Down::MoveWindowToRelativeDesktop(1)
#^Up::MoveWindowToRelativeDesktop(-1)
#^PgDn::MoveWindowToRelativeDesktop(1)
#^PgUp::MoveWindowToRelativeDesktop(-1)

; === Mouse Wheel Navigation ===
#WheelDown:: WheelReady() && Send("#^{Right}")
#WheelUp:: WheelReady() && Send("#^{Left}")
#^WheelDown:: WheelReady() && MoveWindowToRelativeDesktop(1)
#^WheelUp:: WheelReady() && MoveWindowToRelativeDesktop(-1)
#WheelRight::FocusDirection("right")
#WheelLeft::FocusDirection("left")
#^WheelRight::Send "#{Right}"
#^WheelLeft::Send "#{Left}"
#+WheelDown::FocusDirection("right")
#+WheelUp::FocusDirection("left")
#^+WheelDown::Send "#{Right}"
#^+WheelUp::Send "#{Left}"

; === Numbered Workspaces: Win+1..9 go, Win+Shift+1..9 move (follows the window) ===
loop 9 {
    Hotkey "#" A_Index, GoToDesktop.Bind(A_Index)
    Hotkey "#+" A_Index, MoveWindowToDesktop.Bind(A_Index)
}

; niri toggle-keyboard-shortcuts-inhibit: hand every Win chord back to Windows
; (games, remote desktops, VMs) until pressed again.
#SuspendExempt
#Esc:: {
    Suspend
    ToolTip A_IsSuspended ? "Native desktop keys off" : "Native desktop keys on"
    SetTimer () => ToolTip(), -1500
}
#SuspendExempt False
