#Requires AutoHotkey v2.0

; Session menu (lock, sleep, hibernate, log out, restart, shut down) shared by
; the desktop shells. Include it, then bind a key to SessionMenuToggle():
;   #Include %A_ScriptDir%\..\Session-Menu.ahk
;   #x::SessionMenuToggle()
; LockScreen() is usable on its own too.

; Install-Startup.ps1 sets DisableLockWorkstation to free Win+L, which also blocks
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

; YASB 2.0.7 never reconnects to the virtual desktop COM service (desktop pills
; stop following) or the dock's window tracking when Explorer restarts, so
; relaunch it whenever Explorer broadcasts TaskbarCreated. YASB's own systray
; broadcasts it too on startup, so only a new Explorer taskbar window counts.
OnMessage DllCall("RegisterWindowMessage", "Str", "TaskbarCreated", "UInt"), RestartYasb
YasbTaskbar := WinExist("ahk_class Shell_TrayWnd")
RestartYasb(*) {
    SetTimer RelaunchYasb, -3000    ; let Explorer settle first
}
RelaunchYasb() {
    global YasbTaskbar
    if (taskbar := WinExist("ahk_class Shell_TrayWnd")) = YasbTaskbar
        return
    YasbTaskbar := taskbar
    ; Both the scoop shim and the real yasb.exe are running.
    while ProcessExist("yasb.exe")
        ProcessClose "yasb.exe"
    Run "yasb.exe"
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

; A card of tiles over the dimmed monitor, shared with komorebi\Workspace-Overview.ahk.
; Popup is the open one: {kind, overlay, card, tiles, byHwnd, selected, paint,
; cleanup?}. paint(tile, on) redraws a tile's selection; cleanup() runs on close.
Popup := 0
PopupActive(kind) => Popup && Popup.kind = kind && WinActive("ahk_id " Popup.card.Hwnd)
OnMessage 0x0200, PopupHover      ; WM_MOUSEMOVE
OnMessage 0x0201, PopupClickAway  ; WM_LBUTTONDOWN

; Win11 rounded corners and a subtle border (COLORREF is 0x00BBGGRR).
PopupRoundCorners(card, border) {
    DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", card.Hwnd, "UInt", 33, "Int*", 2, "UInt", 4)
    DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", card.Hwnd, "UInt", 34, "UInt*", border, "UInt", 4)
}

PopupSelect(i) {
    paint := Popup.paint
    i := Mod(i - 1 + Popup.tiles.Length, Popup.tiles.Length) + 1
    for index in [Popup.selected, i]
        if index
            paint(Popup.tiles[index], index = i)
    Popup.selected := i
}

PopupClose() {
    global Popup
    SetTimer PopupWatchFocus, 0
    if !Popup
        return
    closing := Popup, Popup := 0
    closing.overlay.Destroy()   ; the owned card goes with it
    if closing.HasProp("cleanup")
        cleanup := closing.cleanup, cleanup()
}

PopupWatchFocus() {
    if Popup && !WinActive("ahk_id " Popup.card.Hwnd)
        PopupClose()
}

PopupHover(wParam, lParam, msg, hwnd) {
    if Popup && Popup.byHwnd.Has(hwnd) && Popup.byHwnd[hwnd] != Popup.selected
        PopupSelect(Popup.byHwnd[hwnd])
}

PopupClickAway(wParam, lParam, msg, hwnd) {
    if Popup && hwnd = Popup.overlay.Hwnd
        PopupClose()
}

SessionMenuRegisterKeys() {
    HotIf (*) => PopupActive("session")
    for i, action in SessionActions {
        Hotkey action.key, SessionMenuRun.Bind(i)
        Hotkey String(i), SessionMenuRun.Bind(i)
    }
    for key, step in Map("Left", -1, "+Tab", -1, "Right", 1, "Tab", 1)
        Hotkey key, ((step, *) => PopupSelect(Popup.selected + step)).Bind(step)
    Hotkey "Enter", (*) => SessionMenuRun(Popup.selected)
    Hotkey "Space", (*) => SessionMenuRun(Popup.selected)
    Hotkey "Esc", (*) => PopupClose()
    HotIf
}
SessionMenuRegisterKeys()

SessionMenuToggle() {
    global Popup
    if Popup {
        kind := Popup.kind
        PopupClose()
        if kind = "session"
            return
    }

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

    PopupRoundCorners(card, 0x454950)

    Popup := {kind: "session", overlay: overlay, card: card, tiles: tiles, byHwnd: byHwnd, selected: 0, paint: SessionMenuPaint}
    PopupSelect(1)
    card.Show("Hide")
    WinGetPos , , &w, &h, card
    WinMove left + (right - left - w) // 2, top + (bottom - top - h) // 2, , , card
    card.Show()
    loop 6 {
        ; A key or click during the fade's Sleep can close (destroy) the menu.
        if !Popup || Popup.overlay != overlay
            return
        WinSetTransparent A_Index * 25, overlay
        Sleep 10
    }
    SetTimer PopupWatchFocus, 100
}

SessionMenuPaint(tile, on) {
    tile.bg.Opt("Background" (on ? "504945" : "3c3836"))
    tile.label.SetFont(on ? "cfbf1c7" : "cebdbb2")
    tile.bar.Visible := on
    for control in [tile.bg, tile.icon, tile.label, tile.hint]
        control.Redraw()
}

SessionMenuRun(i, *) {
    action := SessionActions[i].fn
    PopupClose()
    action()
}
