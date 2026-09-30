#Requires AutoHotkey v2.0

; niri bindings (~/dotfiles/config/niri/common/binds.kdl and shells/noctalia.kdl)
; that behave the same in both desktop modes: session, launchers, shell panels,
; wellbeing, chat scratchpads, close, monitor off. Each mode binds its own Win+D overview. Win is Mod. Include it after #UseHook:
;   #Include %A_ScriptDir%\..\Niri-Common.ahk
; Left untouched on purpose (already match niri): Win+Tab overview, Win+E files,
; Win+V clipboard, Win+N notifications, Win+Shift+/ Shortcut Guide.

#Include %A_LineFile%\..\Session-Menu.ahk

; Exact titles: Claude Code names its terminal after the task, so a title that
; merely starts with "Quake" must not match the quake window.
SetTitleMatchMode 3

; Opens whatever browser is registered for https links.
OpenDefaultBrowser() {
    progId := RegRead("HKCU\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice", "ProgId")
    command := RegRead("HKCR\" progId "\shell\open\command")
    Run RegExReplace(command, '\s+(--single-argument\s+)?"?%1"?.*$')
}

; niri's scratch terminal: Windows Terminal's quake window, which Win+` then
; toggles. It opens on the hidden "Quake" profile, whose fixed tab title is how
; Komorebi's ignore rule leaves the drop-down to Terminal instead of tiling it.
; Terminal's own slide stops at the work area, under the YASB bar, so
; config\terminal\settings.json turns it off (dropdownDuration 0) and QuakeSlide fades
; the window in from the monitor's top edge instead, covering the bar.
QuakeRect := ""  ; rect saved by the last fade out; see QuakeSlide
ScratchTerminal() {
    global QuakeRect
    quake := "Quake ahk_class CASCADIA_HOSTING_WINDOW_CLASS"
    DetectHiddenWindows true
    if !WinExist(quake) {
        Run "wt.exe -w _quake -p Quake"
        QuakeRect := ""
        if WinWait(quake, , 5)
            QuakeSlide(WinExist(quake), true)
        return
    }
    hwnd := WinExist(quake)
    ; Each branch waits for Terminal to finish toggling, so a fast re-press is
    ; dropped (one thread per hotkey) instead of racing Terminal's hide or show.
    if WinActive(hwnd) {
        QuakeSlide(hwnd, false)
        Send "#``"
        WinWaitNotActive(hwnd, , 1)
        return
    }
    ; Every summon snaps it back under the bar, even when it was already up.
    Send "#``"
    if WinWaitActive(hwnd, , 1)
        QuakeSlide(hwnd, true)
}

; Terminal's autoHideWindow doesn't fire here and the topmost quake window
; covers the bar, so hide it on focus loss (EVENT_SYSTEM_FOREGROUND, no polling).
QuakeForeground(hook, event, hwnd, *) {
    static quake := "Quake ahk_class CASCADIA_HOSTING_WINDOW_CLASS", wasQuake := false
    DetectHiddenWindows true
    q := WinExist(quake)
    if wasQuake && hwnd != q
        SetTimer(() => (QuakeSlide(q, false), WinHide(q)), -1)
    wasQuake := hwnd = q
}
DllCall("SetWinEventHook", "UInt", 3, "UInt", 3, "Ptr", 0
    , "Ptr", CallbackCreate(QuakeForeground, "F", 7), "UInt", 0, "UInt", 0, "UInt", 0, "Ptr")

; Fades the quake window in at the monitor's top edge, or out where it stands (a
; fade is compositor work, so Terminal never re-lays-out). Going out saves its rect,
; since Terminal resets to half on show; a fresh window gets half the work area.
QuakeSlide(hwnd, down) {
    global QuakeRect
    SetWinDelay -1
    WinGetPos &x, &y, &w, &h, hwnd
    top := 0, half := h
    Loop MonitorGetCount() {
        MonitorGet A_Index, &l, &t, &r
        if x + w // 2 >= l && x + w // 2 < r {
            top := t
            MonitorGetWorkArea A_Index, , &wt, , &wb
            half := (wt - t) + (wb - wt) // 2
            break
        }
    }
    if down {
        if QuakeRect
            x := QuakeRect[1], w := QuakeRect[2], h := QuakeRect[3]
        else
            h := half
        WinSetTransparent 0, hwnd
        WinMove x, top, w, h, hwnd
    } else if x > -30000
        QuakeRect := [x, w, h]  ; hidden, Terminal parks it at x=-32000
    dur := 150, t0 := A_TickCount
    Loop {
        DllCall("dwmapi\DwmFlush")
        p := Min((A_TickCount - t0) / dur, 1)
        WinSetTransparent Round(255 * (down ? p : 1 - p)), hwnd
    } Until p = 1
}

; niri cooldown-ms=150: one wheel flick switches one workspace, not five.
WheelReady() {
    static last := 0
    if A_TickCount - last < 150
        return false
    last := A_TickCount
    return true
}

; Do Not Disturb has no API, so ..\scripts\Toggle-Dnd.ps1 presses the
; notification centre's own button and prints the new state for the tooltip.
ToggleDnd() {
    out := A_Temp "\windots-dnd.txt"
    script := A_LineFile "\..\..\scripts\Toggle-Dnd.ps1"
    RunWait(Format('{} /c powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{}" > "{}"', A_ComSpec, script, out), , "Hide")
    state := Trim(FileRead(out), " `r`n")
    ToolTip "Do not disturb: " (state = "On" ? "on" : state = "Off" ? "off" : state)
    SetTimer () => ToolTip(), -1500
}

; dotfiles' wellbeing helper, which shows its own popup: --focus toggles focus
; mode, --bedtime turns bedtime on or off.
Wellbeing(command) {
    dotfiles := EnvGet("DOTFILES") || EnvGet("USERPROFILE") "\dotfiles"
    Run(Format('"{}\tools\wellbeing\wellbeing.exe" {}', dotfiles, command))
}

; Power off the display without locking or sleeping (niri power-off-monitors).
MonitorOff() {
    hwnd := DllCall("FindWindow", "Str", "Progman", "Ptr", 0, "Ptr")
    PostMessage(0x0112, 0xF170, 2, , "ahk_id " hwnd)
}

; Chat scratchpads: Teams and WhatsApp float over whatever workspace is showing
; (komorebi.json ignores them instead of giving them one). The key brings the app's
; main window to the middle of the screen, and hides it again once focused.
; The main window is matched by class: the apps also own hidden helper windows
; (WhatsApp's tray icon host is titled and captioned too), and size is no guide
; since a minimized window is 314x50. Of several (Teams chat pop-outs) the
; first in z-order is the one used last.
ChatScratchpad(exe, class, app, *) {
    DetectHiddenWindows true   ; closed to the tray, their windows are hidden
    main := 0
    for hwnd in WinGetList("ahk_exe " exe " ahk_class " class) {
        if !(WinGetExStyle(hwnd) & 0x80) {   ; not a tool window (toasts, call monitor)
            main := hwnd
            break
        }
    }
    if !main
        return Run("shell:AppsFolder\" app)
    if WinActive(main)
        return WinMinimize(main)
    WinShow main
    if WinGetMinMax(main) != 0
        WinRestore main
    CoordMode "Mouse", "Screen"
    MouseGetPos &mx, &my
    MonitorGetWorkArea MonitorOf(mx, my), &left, &top, &right, &bottom
    w := (right - left) * 0.6, h := (bottom - top) * 0.8
    WinMove left + (right - left - w) / 2, top + (bottom - top - h) / 2, w, h, main
    WinActivate main
}
MonitorOf(x, y) {
    loop MonitorGetCount() {
        MonitorGet A_Index, &l, &t, &r, &b
        if x >= l && x < r && y >= t && y < b
            return A_Index
    }
    return MonitorGetPrimary()
}

; === System ===
#x::SessionMenuToggle()
#!l::LockScreen()

; Win+T / Win+Enter: open a terminal and focus it (a Win-key launch leaves it behind).
NewTerminal() {
    SetWinDelay 0   ; the default 100 ms pause after WinActivate is pure lag
    old := WinGetList("ahk_exe WindowsTerminal.exe")
    Run "wt.exe -w new"
    Loop 50 {
        Sleep 10
        for hwnd in WinGetList("ahk_exe WindowsTerminal.exe") {
            if !HasValue(old, hwnd) {
                WinActivate hwnd
                return
            }
        }
    }
    HasValue(arr, v) {
        for x in arr
            if x = v
                return true
        return false
    }
}

; === Application Launchers ===
#Space::Send "^!{Space}"        ; YASB Quick Launch (no Shift: Win+Ctrl+Alt+Shift is the Office/Copilot hotkey)
#t::NewTerminal()
#Enter::NewTerminal()
#`::ScratchTerminal()
#b::OpenDefaultBrowser()
#c::Run "code.exe"
#a::Run "shell:AppsFolder\Microsoft.MicrosoftOfficeHub_8wekyb3d8bbwe!Microsoft.MicrosoftOfficeHub"  ; Microsoft 365 Copilot
#+F23::Run "shell:AppsFolder\Microsoft.MicrosoftOfficeHub_8wekyb3d8bbwe!Microsoft.MicrosoftOfficeHub" ; Copilot key
#s::Send "#h"                   ; dictation

; === Windows AI (on-device, Copilot+) ===
; Windows' own keys are taken here (Win+Q closes, Win+S dictates), so these
; pass them through. #UseHook keeps the Sends from re-triggering our hotkeys.
#z::Send "#q"                   ; Click to Do: act on text or an image on screen
#/::Send "#s"                   ; Windows Search, which takes plain descriptions

; === Shell panels (Noctalia equivalents) ===
#m::Send "#a"                   ; quick settings
#!n::ToggleDnd()                ; Do Not Disturb (Win+N: notifications), Mod+Alt+N on Linux
#y::Run "ms-settings:personalization-background"

; === Wellbeing (the same Mod+Alt keys as on Linux) ===
#!z::Wellbeing("--focus")       ; focus mode (the bar timer's middle-click too)
#!s::Wellbeing("--bedtime")     ; bedtime on or off (not Win+Alt+B: Game Bar owns it)
#,::Run "ms-settings:personalization"

; === Window Management ===
#q::WinClose "A"
#w::ChatScratchpad("WhatsApp.Root.exe", "WinUIDesktopWin32WindowClass", "5319275A.WhatsAppDesktop_cv1g1gvanyjgm!App")
#+w::ChatScratchpad("ms-teams.exe", "TeamsWebView", "MSTeams_8wekyb3d8bbwe!MSTeams")

; === System Controls ===
#+p::MonitorOff()
