#Requires AutoHotkey v2.0

; niri bindings (~/dotfiles/config/niri/common/binds.kdl and shells/noctalia.kdl)
; that behave the same in both desktop modes: session, launchers, shell panels,
; close, monitor off. Each mode binds its own Win+D overview. Win is Mod. Include it after #UseHook:
;   #Include %A_ScriptDir%\..\Niri-Common.ahk
; Left untouched on purpose (already match niri): Win+Tab overview, Win+E files,
; Win+V clipboard, Win+N notifications, Win+Shift+/ Shortcut Guide.

#Include %A_LineFile%\..\Session-Menu.ahk

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

; niri cooldown-ms=150: one wheel flick switches one workspace, not five.
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

; === System ===
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

; === System Controls ===
#+p::MonitorOff()
