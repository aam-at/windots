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
<!s::Send "#h"

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
; jumps. Alt+Shift+1..9 moves the active window to that numbered desktop and
; follows it there. Windows has no built-in shortcut or public API for moving
; another process's window between desktops, so this uses
; VirtualDesktopAccessor.dll (https://github.com/Ciantic/VirtualDesktopAccessor).
hVirtualDesktopAccessor := DllCall("LoadLibrary", "Str", A_ScriptDir "\VirtualDesktopAccessor.dll", "Ptr")
VDA_GoToDesktopNumber := DllCall("GetProcAddress", "Ptr", hVirtualDesktopAccessor, "AStr", "GoToDesktopNumber", "Ptr")
VDA_MoveWindowToDesktopNumber := DllCall("GetProcAddress", "Ptr", hVirtualDesktopAccessor, "AStr", "MoveWindowToDesktopNumber", "Ptr")
VDA_GetCurrentDesktopNumber := DllCall("GetProcAddress", "Ptr", hVirtualDesktopAccessor, "AStr", "GetCurrentDesktopNumber", "Ptr")
VDA_GetDesktopCount := DllCall("GetProcAddress", "Ptr", hVirtualDesktopAccessor, "AStr", "GetDesktopCount", "Ptr")

MoveWindowToDesktop(target) {
    global VDA_GoToDesktopNumber, VDA_MoveWindowToDesktopNumber
    hwnd := WinExist("A")
    if !hwnd
        return
    DllCall(VDA_MoveWindowToDesktopNumber, "Ptr", hwnd, "Int", target - 1, "Int")
    DllCall(VDA_GoToDesktopNumber, "Int", target - 1, "Int")
}

MoveWindowToRelativeDesktop(delta) {
    global VDA_GoToDesktopNumber, VDA_MoveWindowToDesktopNumber, VDA_GetCurrentDesktopNumber, VDA_GetDesktopCount
    hwnd := WinExist("A")
    if !hwnd
        return
    current := DllCall(VDA_GetCurrentDesktopNumber, "Int")
    count := DllCall(VDA_GetDesktopCount, "Int")
    target := Mod(current + delta + count, count)
    DllCall(VDA_MoveWindowToDesktopNumber, "Ptr", hwnd, "Int", target, "Int")
    DllCall(VDA_GoToDesktopNumber, "Int", target, "Int")
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
<!^u::MoveWindowToRelativeDesktop(1)
<!^i::MoveWindowToRelativeDesktop(-1)
<!WheelDown::Send "#^{Right}"
<!WheelUp::Send "#^{Left}"
<!^WheelDown::MoveWindowToRelativeDesktop(1)
<!^WheelUp::MoveWindowToRelativeDesktop(-1)

; Power off the display without locking or sleeping (niri: power-off-monitors)
MonitorOff() {
    hwnd := DllCall("FindWindow", "Str", "Progman", "Ptr", 0, "Ptr")
    PostMessage(0x0112, 0xF170, 2, , "ahk_id " hwnd)
}
<!+p::MonitorOff()
