#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon

; Native Windows desktop controls with the Niri/Noctalia muscle memory.
; FancyZones handles Win+Arrow after its snap-hotkey override is enabled.

; Overview and launchers
#d::Send "#{Tab}"
#Space::Send "#s"
#t::Run "wt.exe"
#Enter::Run "wt.exe"
#`::Run "wt.exe"
#e::Run "explorer.exe"
#b::Run "zen.exe"
#c::Run "code.exe"
#v::Send "#v"
#m::Send "#a"
#n::Send "#n"
#y::Run "ms-settings:personalization-background"
#,::Run "ms-settings:personalization"

; Window controls
#q::WinClose "A"
#f::WinMaximize "A"
#+f::Send "{F11}"

; Window placement through FancyZones
#h::Send "#{Left}"
#j::Send "#{Down}"
#k::Send "#{Up}"
#l::Send "#{Right}"
#+h::Send "#+{Left}"
#+j::Send "#+{Down}"
#+k::Send "#+{Up}"
#+l::Send "#+{Right}"

; Windows virtual desktops: U/I mirrors Niri's workspace down/up bindings.
#u::Send "#^{Right}"
#i::Send "#^{Left}"
#^u::Send "#^+{Right}"
#^i::Send "#^+{Left}"
