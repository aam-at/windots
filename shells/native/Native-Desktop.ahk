#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon

; Native Windows desktop controls with the Niri/Noctalia muscle memory.
; Left Alt is the mode key, matching the Komorebi shell. FancyZones handles
; Win+Arrow after its snap-hotkey override is enabled.

ToggleMaximize() {
    if WinGetMinMax("A") = 1
        WinRestore "A"
    else
        WinMaximize "A"
}

; Overview and launchers
<!d::Send "#{Tab}"
<!Space::Send "#s"
<!t::Run "wt.exe"
<!Enter::Run "wt.exe"
<!`::Run "wt.exe"
<!e::Run "explorer.exe"
<!b::Run "zen.exe"
<!c::Run "code.exe"
<!v::Send "#v"
<!m::Send "#a"
<!n::Send "#n"
<!y::Run "ms-settings:personalization-background"
<!,::Run "ms-settings:personalization"

; Window controls
<!q::WinClose "A"
<!f::ToggleMaximize()
#f::ToggleMaximize()
<!+f::Send "{F11}"

; Window placement through FancyZones
<!h::Send "#{Left}"
<!j::Send "#{Down}"
<!k::Send "#{Up}"
<!l::Send "#{Right}"
<!+h::Send "#+{Left}"
<!+j::Send "#+{Down}"
<!+k::Send "#+{Up}"
<!+l::Send "#+{Right}"

; Windows virtual desktops: U/I mirrors Niri's workspace down/up bindings.
; Alt+1..9 are registered by Windows Virtual Desktop Helper as direct desktop
; jumps. Alt+Shift+1..9 moves the active window to that numbered desktop.
; Windows only exposes adjacent-window moves, so normalize at the left edge
; first; extra left presses are harmless at desktop 1.
MoveWindowToDesktop(target) {
    Loop 20 {
        Send "#^+{Left}"
        Sleep 15
    }
    rightMoves := target - 1
    Loop rightMoves {
        Send "#^+{Right}"
        Sleep 15
    }
}

<!+1::MoveWindowToDesktop(1)
<!+2::MoveWindowToDesktop(2)
<!+3::MoveWindowToDesktop(3)
<!+4::MoveWindowToDesktop(4)
<!+5::MoveWindowToDesktop(5)
<!+6::MoveWindowToDesktop(6)
<!+7::MoveWindowToDesktop(7)
<!+8::MoveWindowToDesktop(8)
<!+9::MoveWindowToDesktop(9)
<!u::Send "#^{Right}"
<!i::Send "#^{Left}"
<!^u::Send "#^+{Right}"
<!^i::Send "#^+{Left}"
