#Requires AutoHotkey v2.0

; Session menu (lock, sleep, hibernate, log out, restart, shut down) shared by
; the desktop shells. Include it, then bind a key to SessionMenuToggle():
;   #Include %A_ScriptDir%\..\Session-Menu.ahk
;   #x::SessionMenuToggle()
; LockScreen() is usable on its own too.

; Native mode sets DisableLockWorkstation to free Win+L, which also blocks
; LockWorkStation, so lift it just long enough for the lock to happen.
LockScreen(*) {
    policy := "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System"
    disabled := RegRead(policy, "DisableLockWorkstation", 0)
    if disabled
        try RegWrite 0, "REG_DWORD", policy, "DisableLockWorkstation"
    DllCall("LockWorkStation")
    if disabled {
        Sleep 2000
        try RegWrite 1, "REG_DWORD", policy, "DisableLockWorkstation"
    }
}

; This laptop only has Modern Standby (S0 low power idle) and hibernate.
; ponytail: SetSuspendState may hibernate instead of standby on S0ix firmware; the power button is the fallback.
SleepComputer() {
    LockScreen()
    DllCall("PowrProf\SetSuspendState", "Int", 0, "Int", 0, "Int", 0)
}

HibernateComputer() {
    LockScreen()
    DllCall("PowrProf\SetSuspendState", "Int", 1, "Int", 0, "Int", 0)
}

; niri Super+X session menu, Noctalia/COSMIC style: the screen under the mouse
; dims and a rounded gruvbox card shows one tile per action.
; While open: the tile letter or 1-6 runs it, Left/Right/Tab move the
; selection, Enter/Space confirm, Esc or a click on the dimmed area cancels.
SessionActions := [
    {label: "Lock", key: "l", glyph: 0xE72E, color: "83a598", fn: LockScreen},
    {label: "Sleep", key: "s", glyph: 0xE708, color: "d3869b", fn: SleepComputer},
    {label: "Hibernate", key: "h", glyph: 0xE823, color: "8ec07c", fn: HibernateComputer},
    {label: "Log out", key: "o", glyph: 0xE77B, color: "fabd2f", fn: (*) => Shutdown(0)},
    {label: "Restart", key: "r", glyph: 0xE72C, color: "fe8019", fn: (*) => Shutdown(2)},
    {label: "Shut down", key: "p", glyph: 0xE7E8, color: "fb4934", fn: (*) => Shutdown(1 | 8)},
]
SessionMenu := 0    ; {overlay, card, tiles, byHwnd, selected} while open

SessionMenuOpen(*) => SessionMenu && WinActive("ahk_id " SessionMenu.card.Hwnd)
SessionMenuRegisterKeys() {
    HotIf SessionMenuOpen
    for i, action in SessionActions {
        Hotkey action.key, SessionMenuRun.Bind(i)
        Hotkey String(i), SessionMenuRun.Bind(i)
    }
    Hotkey "Left", (*) => SessionMenuSelect(SessionMenu.selected - 1)
    Hotkey "+Tab", (*) => SessionMenuSelect(SessionMenu.selected - 1)
    Hotkey "Right", (*) => SessionMenuSelect(SessionMenu.selected + 1)
    Hotkey "Tab", (*) => SessionMenuSelect(SessionMenu.selected + 1)
    Hotkey "Enter", (*) => SessionMenuRun(SessionMenu.selected)
    Hotkey "Space", (*) => SessionMenuRun(SessionMenu.selected)
    Hotkey "Esc", (*) => SessionMenuClose()
    HotIf
}
SessionMenuRegisterKeys()
OnMessage 0x0200, SessionMenuHover      ; WM_MOUSEMOVE
OnMessage 0x0201, SessionMenuClickAway  ; WM_LBUTTONDOWN

SessionMenuToggle() {
    global SessionMenu
    if SessionMenu
        return SessionMenuClose()

    ; Dim the whole monitor under the mouse (physical pixels, hence -DPIScale).
    CoordMode "Mouse", "Screen"
    MouseGetPos &mx, &my
    monitor := MonitorGetPrimary()
    loop MonitorGetCount() {
        MonitorGet A_Index, &l, &t, &r, &b
        if mx >= l && mx < r && my >= t && my < b
            monitor := A_Index
    }
    MonitorGet monitor, &left, &top, &right, &bottom
    overlay := Gui("-Caption +ToolWindow +AlwaysOnTop -DPIScale")
    overlay.BackColor := "000000"
    WinSetTransparent 0, overlay
    overlay.Show(Format("x{} y{} w{} h{} NoActivate", left, top, right - left, bottom - top))

    tileW := 118, tileH := 132, gap := 12, pad := 28, tileY := 92
    width := SessionActions.Length * (tileW + gap) - gap
    card := Gui("-Caption +ToolWindow +AlwaysOnTop +Owner" overlay.Hwnd)
    card.BackColor := "282828"
    card.MarginX := pad, card.MarginY := 24
    card.SetFont("s17 w600 cebdbb2", "Segoe UI Variable Display")
    card.AddText("xm", "Session")
    uptime := A_TickCount // 60000
    card.SetFont("s10 w400 ca89984", "Segoe UI")
    card.AddText("xm y+2", Format("{}@{}  ·  up {}h {}m", A_UserName, A_ComputerName, uptime // 60, Mod(uptime, 60)))

    tiles := [], byHwnd := Map()
    for i, action in SessionActions {
        x := pad + (i - 1) * (tileW + gap)
        tile := {}
        tile.bg := card.AddText(Format("x{} y{} w{} h{} Background3c3836", x, tileY, tileW, tileH))
        tile.bar := card.AddText(Format("x{} y{} w{} h3 Hidden Background{}", x, tileY + tileH - 3, tileW, action.color))
        card.SetFont("s26 w400 c" action.color, "Segoe Fluent Icons")
        tile.icon := card.AddText(Format("x{} y{} w{} h44 Center BackgroundTrans", x, tileY + 20, tileW), Chr(action.glyph))
        card.SetFont("s11 w600 cebdbb2", "Segoe UI")
        tile.label := card.AddText(Format("x{} y{} w{} Center BackgroundTrans", x, tileY + 72, tileW), action.label)
        card.SetFont("s9 w400 c928374", "Segoe UI")
        tile.hint := card.AddText(Format("x{} y{} w{} Center BackgroundTrans", x, tileY + 98, tileW), StrUpper(action.key) "  ·  " i)
        for control in [tile.bg, tile.icon, tile.label, tile.hint] {
            control.OnEvent("Click", SessionMenuRun.Bind(i))
            byHwnd[control.Hwnd] := i
        }
        tiles.Push(tile)
    }
    card.SetFont("s9 w400 c7c6f64", "Segoe UI")
    card.AddText(Format("x{} y{} w{}", pad, tileY + tileH + 16, width),
        "←  →  select      Enter  confirm      Esc  cancel")

    ; Win11 rounded corners and a subtle border (COLORREF is 0x00BBGGRR).
    DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", card.Hwnd, "UInt", 33, "Int*", 2, "UInt", 4)
    DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", card.Hwnd, "UInt", 34, "UInt*", 0x454950, "UInt", 4)

    SessionMenu := {overlay: overlay, card: card, tiles: tiles, byHwnd: byHwnd, selected: 0}
    SessionMenuSelect(1)
    card.Show("Hide")
    WinGetPos , , &w, &h, card
    WinMove left + (right - left - w) // 2, top + (bottom - top - h) // 2, , , card
    card.Show()
    loop 6 {
        WinSetTransparent A_Index * 25, overlay
        Sleep 10
    }
    SetTimer SessionMenuWatchFocus, 100
}

SessionMenuSelect(i) {
    state := SessionMenu
    i := Mod(i - 1 + state.tiles.Length, state.tiles.Length) + 1
    for index in [state.selected, i] {
        if !index
            continue
        tile := state.tiles[index], on := index = i
        tile.bg.Opt("Background" (on ? "504945" : "3c3836"))
        tile.label.SetFont(on ? "cfbf1c7" : "cebdbb2")
        tile.bar.Visible := on
        for control in [tile.bg, tile.icon, tile.label, tile.hint]
            control.Redraw()
    }
    state.selected := i
}

SessionMenuRun(i, *) {
    action := SessionActions[i].fn
    SessionMenuClose()
    action()
}

SessionMenuClose() {
    global SessionMenu
    SetTimer SessionMenuWatchFocus, 0
    if SessionMenu
        SessionMenu.overlay.Destroy()   ; the owned card goes with it
    SessionMenu := 0
}

SessionMenuWatchFocus() {
    if SessionMenu && !WinActive("ahk_id " SessionMenu.card.Hwnd)
        SessionMenuClose()
}

SessionMenuHover(wParam, lParam, msg, hwnd) {
    if SessionMenu && SessionMenu.byHwnd.Has(hwnd) && SessionMenu.byHwnd[hwnd] != SessionMenu.selected
        SessionMenuSelect(SessionMenu.byHwnd[hwnd])
}

SessionMenuClickAway(wParam, lParam, msg, hwnd) {
    if SessionMenu && hwnd = SessionMenu.overlay.Hwnd
        SessionMenuClose()
}
