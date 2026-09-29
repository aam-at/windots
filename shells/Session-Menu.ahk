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

; niri Super+X session menu: the screen under the mouse dims and a Noctalia-
; style panel in the yasb dock's colours shows one round button per action.
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

; GDI+ for antialiased shapes; GDI regions and RoundRect have jagged edges.
DllCall("LoadLibrary", "Str", "gdiplus")
GdiplusInput := Buffer(24, 0), NumPut("UInt", 1, GdiplusInput)   ; GdiplusVersion 1
DllCall("gdiplus\GdiplusStartup", "Ptr*", 0, "Ptr", GdiplusInput, "Ptr", 0)

RoundedPath(path, x, y, w, h, r) {
    d := 2 * r
    for arc in [[x, y, 180], [x + w - d, y, 270], [x + w - d, y + h - d, 0], [x, y + h - d, 90]]
        DllCall("gdiplus\GdipAddPathArc", "Ptr", path, "Float", arc[1], "Float", arc[2], "Float", d, "Float", d, "Float", arc[3], "Float", 90)
    DllCall("gdiplus\GdipClosePathFigure", "Ptr", path)
}

; An antialiased w x h pill (a circle when w = h) of fill on the card colour,
; both hex RRGGBB, in physical pixels. Cached: the menu reuses the same few.
PillBitmap(w, h, fill) {
    static cache := Map()
    if cache.Has(key := w "x" h fill)
        return cache[key]
    DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", w, "Int", h, "Int", 0, "Int", 0x26200A, "Ptr", 0, "Ptr*", &bitmap := 0)
    DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", bitmap, "Ptr*", &g := 0)
    DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", g, "Int", 4)   ; AntiAlias
    DllCall("gdiplus\GdipGraphicsClear", "Ptr", g, "UInt", 0xFF000000 | ("0x" SessionCard))
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", 0xFF000000 | ("0x" fill), "Ptr*", &brush := 0)
    DllCall("gdiplus\GdipCreatePath", "Int", 0, "Ptr*", &path := 0)
    RoundedPath(path, 0.5, 0.5, w - 1, h - 1, (h - 1) / 2)
    DllCall("gdiplus\GdipFillPath", "Ptr", g, "Ptr", brush, "Ptr", path)
    DllCall("gdiplus\GdipDeletePath", "Ptr", path)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", brush)
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", g)
    DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "Ptr", bitmap, "Ptr*", &hbitmap := 0, "UInt", 0)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", bitmap)
    return cache[key] := hbitmap
}

; The card's colours: the dock's glass and the bar's capsules.
SessionCard := "1d2021", SessionSurface := "32302f"

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

    ; The yasb dock's dark glass with a Noctalia panel layout: a header (icon,
    ; title, close button) over a divider, then a macOS-style row of round
    ; buttons. The selected one fills with its accent, Material style.
    colW := 92, gap := 6, pad := 28, dot := 60, tileY := 96
    width := SessionActions.Length * (colW + gap) - gap
    s := A_ScreenDPI / 96, px := (n) => Round(n * s)   ; bitmaps are physical pixels
    card := Gui("-Caption +ToolWindow +AlwaysOnTop +Owner" overlay.Hwnd)
    card.BackColor := SessionCard
    card.MarginX := pad, card.MarginY := 20

    card.AddPicture(Format("x{} y20 w36 h36", pad), "HBITMAP:*" PillBitmap(px(36), px(36), SessionSurface))
    card.SetFont("s13 w400 cfabd2f", "Segoe Fluent Icons")
    card.AddText(Format("x{} y20 w36 h36 Center +0x200 BackgroundTrans", pad), Chr(0xE7E8))
    card.SetFont("s12 w600 cebdbb2", "Segoe UI Variable Display")
    card.AddText(Format("x{} y18", pad + 48), "Session")
    uptime := A_TickCount // 60000
    card.SetFont("s9 w400 ca89984", "Segoe UI Variable Text")
    card.AddText(Format("x{} y40", pad + 48), Format("{}@{}  ·  up {}h {}m", A_UserName, A_ComputerName, uptime // 60, Mod(uptime, 60)))
    closeX := pad + width - 30
    close := card.AddPicture(Format("x{} y23 w30 h30", closeX), "HBITMAP:*" PillBitmap(px(30), px(30), SessionSurface))
    card.SetFont("s8 w400 ca89984", "Segoe Fluent Icons")
    closeGlyph := card.AddText(Format("x{} y23 w30 h30 Center +0x200 BackgroundTrans", closeX), Chr(0xE711))
    for control in [close, closeGlyph]
        control.OnEvent("Click", (*) => PopupClose())
    card.AddText(Format("x{} y72 w{} h1 Background{}", pad, width, SessionSurface))

    tiles := [], byHwnd := Map()
    for i, action in SessionActions {
        x := pad + (i - 1) * (colW + gap), dotX := x + (colW - dot) // 2, chipX := x + (colW - 22) // 2
        tile := {color: action.color,
            off: PillBitmap(px(dot), px(dot), SessionSurface), on: PillBitmap(px(dot), px(dot), action.color),
            chipOff: PillBitmap(px(22), px(18), SessionSurface), chipOn: PillBitmap(px(22), px(18), ColorMix(action.color, SessionCard, 0.25))}
        tile.bg := card.AddPicture(Format("x{} y{} w{} h{}", dotX, tileY, dot, dot), "HBITMAP:*" tile.off)
        card.SetFont("s19 w400 c" action.color, "Segoe Fluent Icons")
        tile.icon := card.AddText(Format("x{} y{} w{} h{} Center +0x200 BackgroundTrans", dotX, tileY, dot, dot), Chr(action.glyph))
        card.SetFont("s10 w500 cd5c4a1", "Segoe UI Variable Text")
        tile.label := card.AddText(Format("x{} y{} w{} Center BackgroundTrans", x, tileY + dot + 10, colW), action.label)
        tile.chip := card.AddPicture(Format("x{} y{} w22 h18", chipX, tileY + dot + 36), "HBITMAP:*" tile.chipOff)
        card.SetFont("s8 w600 c928374", "Segoe UI Variable Text")
        tile.hint := card.AddText(Format("x{} y{} w22 h18 Center +0x200 BackgroundTrans", chipX, tileY + dot + 36), StrUpper(action.key))
        for control in [tile.bg, tile.icon, tile.label, tile.chip, tile.hint] {
            control.OnEvent("Click", SessionMenuRun.Bind(i))
            byHwnd[control.Hwnd] := i
        }
        tiles.Push(tile)
    }
    card.AddText(Format("x{} y{} w1 h1", pad, tileY + dot + 58), "")   ; bottom margin

    PopupRoundCorners(card, 0x475153)   ; the dock's glass edge

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
    tile.bg.Value := "HBITMAP:*" (on ? tile.on : tile.off)
    tile.icon.SetFont("c" (on ? SessionCard : tile.color))
    tile.label.SetFont(on ? "cfbf1c7" : "cd5c4a1")
    tile.chip.Value := "HBITMAP:*" (on ? tile.chipOn : tile.chipOff)
    tile.hint.SetFont(on ? "cfbf1c7" : "c928374")
    for control in [tile.bg, tile.icon, tile.label, tile.chip, tile.hint]
        control.Redraw()
}

; Blend hex colors a and b: t of a, the rest b.
ColorMix(a, b, t) {
    out := ""
    loop 3
        out .= Format("{:02x}", Round(t * ("0x" SubStr(a, 2 * A_Index - 1, 2)) + (1 - t) * ("0x" SubStr(b, 2 * A_Index - 1, 2))))
    return out
}

SessionMenuRun(i, *) {
    action := SessionActions[i].fn
    PopupClose()
    action()
}
