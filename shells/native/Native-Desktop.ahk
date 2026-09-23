#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon
; Hook every hotkey so Send("#{Left}") etc. from inside a Win hotkey reaches
; Windows/FancyZones instead of re-triggering this script.
#UseHook

; Native Windows desktop controls with the niri muscle memory
; (~/dotfiles/config/niri/common/binds.kdl). Win is Mod, as in niri.
; Win+L is free for focus-right because setup\Install-Startup.ps1 sets
; DisableLockWorkstation in Native mode; Win+Alt+L and the Win+X menu lock.
; Left untouched on purpose (already match niri): Win+Tab overview, Win+E files,
; Win+V clipboard, Win+N notifications, Win+Shift+/ Shortcut Guide.

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

#Include %A_ScriptDir%\..\Session-Menu.ahk
#Include %A_ScriptDir%\..\Hide-Taskbar.ahk

; === Helpers ===

ToggleMaximize() {
    if WinGetMinMax("A") = 1
        WinRestore "A"
    else
        WinMaximize "A"
}

; Opens whatever browser is registered for https links.
OpenDefaultBrowser() {
    progId := RegRead("HKCU\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice", "ProgId")
    command := RegRead("HKCR\" progId "\shell\open\command")
    Run RegExReplace(command, '\s+(--single-argument\s+)?"?%1"?.*$')
}

; niri's scratch terminal: Windows Terminal's quake window (Win+` toggles it
; once Terminal is running).
ScratchTerminal() {
    if ProcessExist("WindowsTerminal.exe")
        Send "#``"
    else
        Run "wt.exe -w _quake"
}

IsFocusable(hwnd) {
    if WinGetMinMax(hwnd) = -1 || WinGetTitle(hwnd) = ""
        return false
    if WinGetClass(hwnd) ~= "^(Progman|WorkerW|Shell_TrayWnd|Shell_SecondaryTrayWnd)$"
        return false
    ; WS_VISIBLE and not WS_EX_TOOLWINDOW
    if !(WinGetStyle(hwnd) & 0x10000000) || (WinGetExStyle(hwnd) & 0x80)
        return false
    ; Windows on other virtual desktops and suspended UWP frames are cloaked.
    cloaked := 0
    DllCall("dwmapi\DwmGetWindowAttribute", "Ptr", hwnd, "UInt", 14, "UInt*", &cloaked, "UInt", 4)
    return !cloaked
}

; niri focus-column-left/right and focus-window-up/down: activate the nearest
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
        switch dir {
            case "left": along := -dx, across := Abs(dy)
            case "right": along := dx, across := Abs(dy)
            case "up": along := -dy, across := Abs(dx)
            case "down": along := dy, across := Abs(dx)
        }
        if along <= 0
            continue
        score := along + 2 * across
        if !best || score < bestScore
            best := candidate, bestScore := score
    }
    if best
        WinActivate best
}

; niri center-column
CenterWindow() {
    if !(hwnd := WinExist("A"))
        return
    if WinGetMinMax(hwnd) != 0
        WinRestore hwnd
    WinGetPos &x, &y, &w, &h, hwnd
    cx := x + w / 2, cy := y + h / 2
    loop MonitorGetCount() {
        MonitorGetWorkArea A_Index, &left, &top, &right, &bottom
        if cx >= left && cx < right && cy >= top && cy < bottom {
            WinMove left + (right - left - w) // 2, top + (bottom - top - h) // 2, , , hwnd
            return
        }
    }
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

; niri cooldown-ms=150: one wheel flick switches one desktop, not five.
WheelReady() {
    static last := 0
    if A_TickCount - last < 150
        return false
    last := A_TickCount
    return true
}

; Power off the display without locking or sleeping (niri power-off-monitors).
MonitorOff() {
    hwnd := DllCall("FindWindow", "Str", "Progman", "Ptr", 0, "Ptr")
    PostMessage(0x0112, 0xF170, 2, , "ahk_id " hwnd)
}

; === System & Overview ===
#d::Send "#{Tab}"
#x::SessionMenuToggle()
#!l::LockScreen()

; === Application Launchers ===
#Space::Send "#!{Space}"        ; PowerToys Command Palette
#t::Run "wt.exe"
#Enter::Run "wt.exe"
#`::ScratchTerminal()
#b::OpenDefaultBrowser()
#c::Run "code.exe"
#a::Run "shell:AppsFolder\Microsoft.MicrosoftOfficeHub_8wekyb3d8bbwe!Microsoft.MicrosoftOfficeHub"  ; Microsoft 365 Copilot
#+F23::Run "shell:AppsFolder\Microsoft.MicrosoftOfficeHub_8wekyb3d8bbwe!Microsoft.MicrosoftOfficeHub" ; Copilot key
#s::Send "#h"                   ; dictation

; === Shell panels (Noctalia equivalents) ===
#m::Send "#a"                   ; quick settings
#y::Run "ms-settings:personalization-background"
#,::Run "ms-settings:personalization"

; === Window Management ===
#q::WinClose "A"
#f::ToggleMaximize()
#+f::Send "{F11}"
#+t::Send "#^t"                 ; PowerToys Always On Top (niri toggle-window-floating)
#+c::CenterWindow()

; === Focus Navigation ===
#h::FocusDirection("left")
#j::FocusDirection("down")
#k::FocusDirection("up")
#l::FocusDirection("right")
#Left::FocusDirection("left")
#Down::FocusDirection("down")
#Up::FocusDirection("up")
#Right::FocusDirection("right")

; === Window Movement (FancyZones snaps on Win+Arrow) ===
#+h::Send "#{Left}"
#+j::Send "#{Down}"
#+k::Send "#{Up}"
#+l::Send "#{Right}"
#+Left::Send "#{Left}"
#+Down::Send "#{Down}"
#+Up::Send "#{Up}"
#+Right::Send "#{Right}"

; === Move to Monitor ===
#+^h::Send "#+{Left}"
#+^l::Send "#+{Right}"
#+^Left::Send "#+{Left}"
#+^Right::Send "#+{Right}"

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

; === Numbered Workspaces: Win+1..9 go, Win+Shift+1..9 move (follows the window) ===
loop 9 {
    Hotkey "#" A_Index, GoToDesktop.Bind(A_Index)
    Hotkey "#+" A_Index, MoveWindowToDesktop.Bind(A_Index)
}

; === System Controls ===
#+p::MonitorOff()

; niri toggle-keyboard-shortcuts-inhibit: hand every Win chord back to Windows
; (games, remote desktops, VMs) until pressed again.
#SuspendExempt
#Esc:: {
    Suspend
    ToolTip A_IsSuspended ? "Native desktop keys off" : "Native desktop keys on"
    SetTimer () => ToolTip(), -1500
}
#SuspendExempt False
