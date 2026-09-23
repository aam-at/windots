#Requires AutoHotkey v2.0.2
#SingleInstance Force

#Include %A_ScriptDir%\..\Hide-Taskbar.ahk

Komorebic(cmd, *) {
    RunWait(format("komorebic.exe {}", cmd), , "Hide")
}

!q::Komorebic("close")
!m::Komorebic("minimize")

; Focus windows
!h::Komorebic("focus left")
!j::Komorebic("focus down")
!k::Komorebic("focus up")
!l::Komorebic("focus right")

!+[::Komorebic("cycle-focus previous")
!+]::Komorebic("cycle-focus next")

; Move windows
!+h::Komorebic("move left")
!+j::Komorebic("move down")
!+k::Komorebic("move up")
!+l::Komorebic("move right")

; Stack windows
!Left::Komorebic("stack left")
!Down::Komorebic("stack down")
!Up::Komorebic("stack up")
!Right::Komorebic("stack right")
!;::Komorebic("unstack")
![::Komorebic("cycle-stack previous")
!]::Komorebic("cycle-stack next")

; Resize
!=::Komorebic("resize-axis horizontal increase")
!-::Komorebic("resize-axis horizontal decrease")
!+=::Komorebic("resize-axis vertical increase")
!+_::Komorebic("resize-axis vertical decrease")

; Manipulate windows
!t::Komorebic("toggle-float")
!f::Komorebic("toggle-monocle")
!Space::Komorebic("toggle-float")
!Enter::Komorebic("toggle-monocle")
!+m::Komorebic("toggle-maximize")
!+p::Komorebic("toggle-lock")

; Window manager options
!r::Komorebic("retile")
!p::Komorebic("toggle-pause")

; Layouts
!x::Komorebic("flip-layout horizontal")
!y::Komorebic("flip-layout vertical")
!b::Komorebic("change-layout bsp")
!g::Komorebic("change-layout grid")
!v::Komorebic("change-layout vertical-stack")
!u::Komorebic("change-layout ultrawide-vertical-stack")
!,::Komorebic("cycle-workspace previous")
!.::Komorebic("cycle-workspace next")

; Workspaces: Alt+1..6 focus, Alt+Shift+1..6 move the window there
loop 6 {
    Hotkey "!" A_Index, Komorebic.Bind("focus-workspace " (A_Index - 1))
    Hotkey "!+" A_Index, Komorebic.Bind("move-to-workspace " (A_Index - 1))
}

Capslock::Esc
Esc::Capslock
