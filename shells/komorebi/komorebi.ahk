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
