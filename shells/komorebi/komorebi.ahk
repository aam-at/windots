#Requires AutoHotkey v2.0.2
#SingleInstance Force
; Hook every hotkey so Send("#{Tab}") etc. from inside a Win hotkey reaches
; Windows instead of re-triggering this script.
#UseHook

; Komorebi's Scrolling layout driven with the niri keys
; (~/dotfiles/config/niri/common/binds.kdl). Win is Mod, as in niri. Each
; column is a Komorebi stack, so niri's window-in-column actions map to stacks.
; Win+L is free for focus-right because setup\Install-Startup.ps1 sets
; DisableLockWorkstation; Win+Alt+L and the Win+X menu lock. Launchers, panels
; and other mode-independent keys live in ..\Niri-Common.ahk.

#Include %A_ScriptDir%\..\Niri-Common.ahk
#Include %A_ScriptDir%\Workspace-Overview.ahk

#d::WorkspaceOverviewToggle()

Komorebic(cmd, *) {
    RunWait(format("komorebic.exe {}", cmd), , "Hide")
}

; niri switch-preset-column-width: cycle 33% / 50% / 100% (visible columns).
; ponytail: one counter for all workspaces, not per-workspace state.
CycleColumns() {
    static presets := [3, 2, 1], i := 2
    i := Mod(i, presets.Length) + 1
    Komorebic("scrolling-layout-columns " presets[i])
}

; Chat scratchpads: komorebi.json ignores Teams and WhatsApp, so they float over
; whatever workspace is showing instead of taking one. The key brings the app's
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
#w::ChatScratchpad("WhatsApp.Root.exe", "WinUIDesktopWin32WindowClass", "5319275A.WhatsAppDesktop_cv1g1gvanyjgm!App")
#+w::ChatScratchpad("ms-teams.exe", "TeamsWebView", "MSTeams_8wekyb3d8bbwe!MSTeams")

; === Window Management ===
#f::Komorebic("toggle-monocle")
#+f::Komorebic("toggle-maximize")
#+t::Komorebic("toggle-float")
#+v::Komorebic("toggle-workspace-layer")

; === Focus Navigation ===
#h::Komorebic("focus left")
#j::Komorebic("cycle-stack next")
#k::Komorebic("cycle-stack previous")
#l::Komorebic("focus right")
#Left::Komorebic("focus left")
#Down::Komorebic("cycle-stack next")
#Up::Komorebic("cycle-stack previous")
#Right::Komorebic("focus right")

; === Window Movement ===
#+h::Komorebic("move left")
#+j::Komorebic("cycle-stack-index next")
#+k::Komorebic("cycle-stack-index previous")
#+l::Komorebic("move right")
#+Left::Komorebic("move left")
#+Down::Komorebic("cycle-stack-index next")
#+Up::Komorebic("cycle-stack-index previous")
#+Right::Komorebic("move right")

; === Monitor Navigation ===
#^h::Komorebic("cycle-monitor previous")
#^l::Komorebic("cycle-monitor next")
#^Left::Komorebic("cycle-monitor previous")
#^Right::Komorebic("cycle-monitor next")
#+^h::Komorebic("cycle-move-to-monitor previous")
#+^l::Komorebic("cycle-move-to-monitor next")
#+^Left::Komorebic("cycle-move-to-monitor previous")
#+^Right::Komorebic("cycle-move-to-monitor next")

; === Workspace Navigation ===
#u::Komorebic("cycle-workspace next")
#i::Komorebic("cycle-workspace previous")
#PgDn::Komorebic("cycle-workspace next")
#PgUp::Komorebic("cycle-workspace previous")
#^u::Komorebic("cycle-move-to-workspace next")
#^i::Komorebic("cycle-move-to-workspace previous")
#^Down::Komorebic("cycle-move-to-workspace next")
#^Up::Komorebic("cycle-move-to-workspace previous")
#^PgDn::Komorebic("cycle-move-to-workspace next")
#^PgUp::Komorebic("cycle-move-to-workspace previous")

; === Mouse Wheel Navigation ===
#WheelDown:: WheelReady() && Komorebic("cycle-workspace next")
#WheelUp:: WheelReady() && Komorebic("cycle-workspace previous")
#^WheelDown:: WheelReady() && Komorebic("cycle-move-to-workspace next")
#^WheelUp:: WheelReady() && Komorebic("cycle-move-to-workspace previous")
#WheelRight::Komorebic("focus right")
#WheelLeft::Komorebic("focus left")
#^WheelRight::Komorebic("move right")
#^WheelLeft::Komorebic("move left")
#+WheelDown::Komorebic("focus right")
#+WheelUp::Komorebic("focus left")
#^+WheelDown::Komorebic("move right")
#^+WheelUp::Komorebic("move left")

; === Numbered Workspaces: Win+1..9 go, Win+Shift+1..9 move (follows the window) ===
loop 9 {
    Hotkey "#" A_Index, Komorebic.Bind("focus-workspace " (A_Index - 1))
    Hotkey "#+" A_Index, Komorebic.Bind("move-to-workspace " (A_Index - 1))
}

; === Column Management (consume-or-expel = stack into the neighbour) ===
#[::Komorebic("stack left")
#]::Komorebic("stack right")
#.::Komorebic("unstack")

; === Sizing & Layout ===
#r::CycleColumns()
#-::Komorebic("resize-axis horizontal decrease")
#=::Komorebic("resize-axis horizontal increase")
#+-::Komorebic("resize-axis vertical decrease")
#+=::Komorebic("resize-axis vertical increase")

; niri toggle-keyboard-shortcuts-inhibit: hand every Win chord back to Windows
; (games, remote desktops, VMs) until pressed again.
#SuspendExempt
#Esc:: {
    Suspend
    ToolTip A_IsSuspended ? "Komorebi keys off" : "Komorebi keys on"
    SetTimer () => ToolTip(), -1500
}
#SuspendExempt False
