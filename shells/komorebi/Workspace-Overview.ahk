#Requires AutoHotkey v2.0

; niri Super+D overview for Komorebi, styled like ..\Session-Menu.ahk: the
; focused monitor dims and a gruvbox card shows each workspace as a miniature
; of the monitor (the used workspaces plus one empty one, as in niri). While
; open: 1-9 jump to a workspace, arrows / hjkl move the selection, Enter/Space
; confirm, Esc, Win+D or a click on the dimmed area cancel. Hold Shift with a
; number, Enter or a click to take the focused window along.
; Include it and bind a key to WorkspaceOverviewToggle().
;
; Windows on other workspaces are cloaked, and DWM thumbnails of cloaked
; windows come out blank, so tiles are drawn with PrintWindow instead. It hangs
; on hidden windows, hence komorebi.json's window_hiding_behaviour "Cloak".

Overview := 0   ; {overlay, card, tiles, byHwnd, selected, cols} while open

OverviewOpen(*) => Overview && WinActive("ahk_id " Overview.card.Hwnd)
OverviewRegisterKeys() {
    HotIf OverviewOpen
    loop 9
        for key in [String(A_Index), "+" A_Index]
            Hotkey key, OverviewGo.Bind(A_Index)
    for key, step in Map("Left", -1, "h", -1, "+Tab", -1, "Right", 1, "l", 1, "Tab", 1)
        Hotkey key, OverviewStep.Bind(step)
    for key, dir in Map("Up", -1, "k", -1, "Down", 1, "j", 1)
        Hotkey key, ((dir, *) => OverviewStep(dir * Overview.cols)).Bind(dir)
    for key in ["Enter", "+Enter", "Space"]
        Hotkey key, (*) => OverviewGo(Overview.tiles[Overview.selected].index)
    Hotkey "Esc", (*) => OverviewClose()
    HotIf
}
OverviewRegisterKeys()
OnMessage 0x0200, OverviewHover      ; WM_MOUSEMOVE
OnMessage 0x0201, OverviewClickAway  ; WM_LBUTTONDOWN

; komorebic state as an object, parsed by MSHTML's JSON (AHK has no parser).
; JS arrays index as arr.%i% from 0.
; komorebic-no-console has no console window to flash, so its output can be
; read straight from a pipe: ~100ms, against ~650ms through cmd /c > file.
KomorebiState() {
    exec := ComObject("WScript.Shell").Exec("komorebic-no-console.exe state")
    doc := ComObject("htmlfile")
    doc.write('<meta http-equiv="X-UA-Compatible" content="IE=9">')
    return doc.parentWindow.JSON.parse(exec.StdOut.ReadAll())
}

; The windows a workspace shows, bottom to top: the monocle or maximized window
; if there is one (Komorebi hides the columns then), else each column's focused
; window (the rest of a stack is hidden); then the floating ones. .total counts
; every window, shown or not.
WorkspaceWindows(ws) {
    hwnds := [], hwnds.total := 0, columns := []
    Focused(ring) {
        hwnds.total += ring.elements.length
        return ring.elements.%ring.focused%.hwnd
    }
    containers := ws.containers.elements
    loop containers.length
        columns.Push(Focused(containers.%A_Index - 1%.windows))
    if ws.monocle_container
        hwnds.Push(Focused(ws.monocle_container.windows))
    else if ws.maximized_window
        hwnds.Push(ws.maximized_window.hwnd), hwnds.total += 1
    else
        hwnds.Push(columns*)
    floating := ws.floating_windows.elements
    loop floating.length
        hwnds.Push(floating.%A_Index - 1%.hwnd), hwnds.total += 1
    return hwnds
}

; The desktop wallpaper as {bitmap, w, h}, or 0. TranscodedWallpaper is the
; copy Windows actually shows, whatever the source (slideshow, Spotlight).
LoadWallpaper() {
    path := A_AppData "\Microsoft\Windows\Themes\TranscodedWallpaper"
    try bitmap := LoadPicture(path)
    catch
        return 0
    info := Buffer(32, 0)   ; BITMAP: bmType, bmWidth, bmHeight, ...
    DllCall("GetObject", "Ptr", bitmap, "Int", info.Size, "Ptr", info)
    return {bitmap: bitmap, w: NumGet(info, 4, "Int"), h: NumGet(info, 8, "Int")}
}

; Fill a w x h DC with the wallpaper, cropped to fill like Windows' "Fill".
DrawWallpaper(dc, wall, w, h) {
    if !wall {
        fill := Buffer(16, 0), NumPut("Int", w, "Int", h, fill, 8)
        brush := DllCall("CreateSolidBrush", "UInt", 0x21201d, "Ptr")   ; 1d2021 as 0x00BBGGRR
        DllCall("FillRect", "Ptr", dc, "Ptr", fill, "Ptr", brush)
        return DllCall("DeleteObject", "Ptr", brush)
    }
    scale := Min(wall.w / w, wall.h / h), sw := Round(w * scale), sh := Round(h * scale)
    src := DllCall("CreateCompatibleDC", "Ptr", dc, "Ptr")
    old := DllCall("SelectObject", "Ptr", src, "Ptr", wall.bitmap, "Ptr")
    DllCall("SetStretchBltMode", "Ptr", dc, "Int", 4)   ; HALFTONE
    DllCall("StretchBlt", "Ptr", dc, "Int", 0, "Int", 0, "Int", w, "Int", h,
        "Ptr", src, "Int", (wall.w - sw) // 2, "Int", (wall.h - sh) // 2, "Int", sw, "Int", sh, "UInt", 0xCC0020)
    DllCall("SelectObject", "Ptr", src, "Ptr", old)
    DllCall("DeleteDC", "Ptr", src)
}

; A window we couldn't capture: a dark panel with its app's icon in the middle.
DrawPlaceholder(dc, hwnd, x, y, w, h) {
    inset := Max(1, w // 60)
    panel := Buffer(16), NumPut("Int", x + inset, "Int", y + inset, "Int", x + w - inset, "Int", y + h - inset, panel)
    brush := DllCall("CreateSolidBrush", "UInt", 0x363c3c, "Ptr")   ; 3c3836 as 0x00BBGGRR
    DllCall("FillRect", "Ptr", dc, "Ptr", panel, "Ptr", brush)
    DllCall("DeleteObject", "Ptr", brush)
    size := Min(w, h) // 4
    try {
        icon := LoadPicture(WinGetProcessPath(hwnd), "Icon1 w" size " h" size, &imageType)
        DllCall("DrawIconEx", "Ptr", dc, "Int", x + (w - size) // 2, "Int", y + (h - size) // 2,
            "Ptr", icon, "Int", size, "Int", size, "UInt", 0, "Ptr", 0, "UInt", 3)   ; DI_NORMAL
        DllCall("DestroyIcon", "Ptr", icon)
    }
}

; A w x h bitmap of the monitor (rect, physical pixels): the wallpaper with each
; window drawn scaled to its place; off-screen Scrolling columns clip at the edges.
; ponytail: one PrintWindow per window on every open, cache per workspace if it gets slow.
SnapWorkspace(hwnds, rect, w, h, wall) {
    DetectHiddenWindows true   ; AHK's Win* functions skip cloaked windows otherwise
    screen := DllCall("GetDC", "Ptr", 0, "Ptr")
    tile := DllCall("CreateCompatibleDC", "Ptr", screen, "Ptr")
    bitmap := DllCall("CreateCompatibleBitmap", "Ptr", screen, "Int", w, "Int", h, "Ptr")
    DllCall("SelectObject", "Ptr", tile, "Ptr", bitmap)
    DrawWallpaper(tile, wall, w, h)
    DllCall("SetStretchBltMode", "Ptr", tile, "Int", 4)   ; HALFTONE
    k := w / rect.right
    for hwnd in hwnds {
        ; PrintWindow waits on the window, so a hung app would freeze every hotkey.
        if !DllCall("IsWindow", "Ptr", hwnd) || DllCall("IsHungAppWindow", "Ptr", hwnd)
            continue
        WinGetPos &wx, &wy, &ww, &wh, hwnd
        x := Round((wx - rect.left) * k), y := Round((wy - rect.top) * k), dw := Round(ww * k), dh := Round(wh * k)
        win := DllCall("CreateCompatibleDC", "Ptr", screen, "Ptr")
        shot := DllCall("CreateCompatibleBitmap", "Ptr", screen, "Int", ww, "Int", wh, "Ptr")
        DllCall("SelectObject", "Ptr", win, "Ptr", shot)
        DllCall("PrintWindow", "Ptr", hwnd, "Ptr", win, "UInt", 2)   ; PW_RENDERFULLCONTENT
        ; Apps that stop rendering while cloaked leave the bitmap black.
        blank := true
        for p in [[0.5, 0.5], [0.25, 0.3], [0.75, 0.3], [0.25, 0.7], [0.75, 0.7]]
            blank := blank && !DllCall("GetPixel", "Ptr", win, "Int", ww * p[1], "Int", wh * p[2])
        if blank
            DrawPlaceholder(tile, hwnd, x, y, dw, dh)
        else
            DllCall("StretchBlt", "Ptr", tile, "Int", x, "Int", y, "Int", dw, "Int", dh,
                "Ptr", win, "Int", 0, "Int", 0, "Int", ww, "Int", wh, "UInt", 0xCC0020)
        DllCall("DeleteDC", "Ptr", win)
        DllCall("DeleteObject", "Ptr", shot)
    }
    DllCall("DeleteDC", "Ptr", tile)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", screen)
    return bitmap
}

; GDI+ for antialiased rounded tiles; GDI's RoundRect has jagged corners.
DllCall("LoadLibrary", "Str", "gdiplus")
GdiplusInput := Buffer(24, 0), NumPut("UInt", 1, GdiplusInput)   ; GdiplusVersion 1
DllCall("gdiplus\GdiplusStartup", "Ptr*", 0, "Ptr", GdiplusInput, "Ptr", 0)

RoundedPath(path, x, y, w, h, r) {
    d := 2 * r
    for arc in [[x, y, 180], [x + w - d, y, 270], [x + w - d, y + h - d, 0], [x, y + h - d, 90]]
        DllCall("gdiplus\GdipAddPathArc", "Ptr", path, "Float", arc[1], "Float", arc[2], "Float", d, "Float", d, "Float", arc[3], "Float", 90)
    DllCall("gdiplus\GdipClosePathFigure", "Ptr", path)
}

; A copy of a w x h tile bitmap with rounded corners (cut to the card colour)
; and either the selection ring or, unselected, a dimmed face and faint outline.
DecorateTile(base, w, h, selected, r, ring) {
    screen := DllCall("GetDC", "Ptr", 0, "Ptr")
    dst := DllCall("CreateCompatibleDC", "Ptr", screen, "Ptr")
    bitmap := DllCall("CreateCompatibleBitmap", "Ptr", screen, "Int", w, "Int", h, "Ptr")
    DllCall("SelectObject", "Ptr", dst, "Ptr", bitmap)
    DllCall("gdiplus\GdipCreateFromHDC", "Ptr", dst, "Ptr*", &g := 0)
    DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", g, "Int", 4)   ; AntiAlias
    ; Copy through GDI+ so every pixel gets alpha 255: GDI leaves alpha 0, and
    ; a Picture control treats a 32-bit bitmap with any alpha as transparent.
    DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "Ptr", base, "Ptr", 0, "Ptr*", &image := 0)
    DllCall("gdiplus\GdipDrawImageRectI", "Ptr", g, "Ptr", image, "Int", 0, "Int", 0, "Int", w, "Int", h)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", image)
    Fill(argb, path := 0) {
        DllCall("gdiplus\GdipCreateSolidFill", "UInt", argb, "Ptr*", &brush := 0)
        if path
            DllCall("gdiplus\GdipFillPath", "Ptr", g, "Ptr", brush, "Ptr", path)
        else
            DllCall("gdiplus\GdipFillRectangleI", "Ptr", g, "Ptr", brush, "Int", 0, "Int", 0, "Int", w, "Int", h)
        DllCall("gdiplus\GdipDeleteBrush", "Ptr", brush)
    }
    Outline(argb, width) {
        DllCall("gdiplus\GdipCreatePath", "Int", 0, "Ptr*", &path := 0)
        RoundedPath(path, width / 2, width / 2, w - width, h - width, r - width / 2)
        DllCall("gdiplus\GdipCreatePen1", "UInt", argb, "Float", width, "Int", 2, "Ptr*", &pen := 0)
        DllCall("gdiplus\GdipDrawPath", "Ptr", g, "Ptr", pen, "Ptr", path)
        DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
        DllCall("gdiplus\GdipDeletePath", "Ptr", path)
    }
    if !selected
        Fill(0x40000000)   ; 25% black
    ; The rectangle minus the rounded tile (alternate fill) = the four corners.
    DllCall("gdiplus\GdipCreatePath", "Int", 0, "Ptr*", &corners := 0)
    DllCall("gdiplus\GdipAddPathRectangleI", "Ptr", corners, "Int", -1, "Int", -1, "Int", w + 2, "Int", h + 2)
    RoundedPath(corners, 0, 0, w, h, r)
    Fill(0xFF282828, corners)
    DllCall("gdiplus\GdipDeletePath", "Ptr", corners)
    if selected
        Outline(0xFFFABD2F, ring)
    else
        Outline(0x30EBDBB2, Max(1, ring // 3))
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", g)
    DllCall("DeleteDC", "Ptr", dst)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", screen)
    return bitmap
}

; The wallpaper scaled to w x h, cached across opens until it changes: loading
; and halftone-scaling the full-size image costs ~15ms a tile otherwise.
TileWallpaper(w, h) {
    static cache := 0
    path := A_AppData "\Microsoft\Windows\Themes\TranscodedWallpaper"
    stamp := FileExist(path) ? FileGetTime(path) : ""
    if cache && cache.w = w && cache.h = h && cache.stamp = stamp
        return cache
    if cache
        DllCall("DeleteObject", "Ptr", cache.bitmap)
    cache := 0
    if !(full := LoadWallpaper())
        return 0
    screen := DllCall("GetDC", "Ptr", 0, "Ptr")
    dc := DllCall("CreateCompatibleDC", "Ptr", screen, "Ptr")
    bitmap := DllCall("CreateCompatibleBitmap", "Ptr", screen, "Int", w, "Int", h, "Ptr")
    DllCall("SelectObject", "Ptr", dc, "Ptr", bitmap)
    DrawWallpaper(dc, full, w, h)
    DllCall("DeleteDC", "Ptr", dc)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", screen)
    DllCall("DeleteObject", "Ptr", full.bitmap)
    return cache := {bitmap: bitmap, w: w, h: h, stamp: stamp}
}

; The monitor as it is on screen, scaled to w x h: ~20ms, where PrintWindow
; takes ~60ms a workspace. Only right for the workspace that is showing.
GrabScreen(rect, w, h) {
    screen := DllCall("GetDC", "Ptr", 0, "Ptr")
    dc := DllCall("CreateCompatibleDC", "Ptr", screen, "Ptr")
    bitmap := DllCall("CreateCompatibleBitmap", "Ptr", screen, "Int", w, "Int", h, "Ptr")
    DllCall("SelectObject", "Ptr", dc, "Ptr", bitmap)
    DllCall("SetStretchBltMode", "Ptr", dc, "Int", 4)   ; HALFTONE
    DllCall("StretchBlt", "Ptr", dc, "Int", 0, "Int", 0, "Int", w, "Int", h,
        "Ptr", screen, "Int", rect.left, "Int", rect.top, "Int", rect.right, "Int", rect.bottom, "UInt", 0xCC0020)
    DllCall("DeleteDC", "Ptr", dc)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", screen)
    return bitmap
}

; Give a tile new selected/unselected bitmaps made from base (which is freed).
SetTileBase(tile, base, look) {
    if tile.HasProp("on")
        DllCall("DeleteObject", "Ptr", tile.on), DllCall("DeleteObject", "Ptr", tile.off)
    tile.on := DecorateTile(base, look.w, look.h, true, look.radius, look.ring)
    tile.off := DecorateTile(base, look.w, look.h, false, look.radius, look.ring)
    DllCall("DeleteObject", "Ptr", base)
}

; Opens fast, then fills in: the dim and the card come up at once with the
; current workspace grabbed from the screen and the others as bare wallpaper,
; then each other workspace gets its PrintWindow snapshot in turn.
WorkspaceOverviewToggle() {
    global Overview
    if Overview
        return OverviewClose()

    try state := KomorebiState()
    catch   ; komorebi not running (or restarting): no state to show
        return
    monitor := state.monitors.elements.%state.monitors.focused%
    workspaces := monitor.workspaces.elements
    focused := monitor.workspaces.focused + 1
    windows := [], last := 0
    loop Min(workspaces.length, 9) {
        windows.Push(WorkspaceWindows(workspaces.%A_Index - 1%))
        if windows[A_Index].Length
            last := A_Index
    }
    count := Min(Max(last + 1, focused), windows.Length)

    ; Komorebi rects are physical pixels, with right/bottom as width/height.
    ; Both windows skip DPI scaling so control and bitmap coordinates match.
    rect := monitor.size
    s := A_ScreenDPI / 96
    pad := Round(36 * s), gap := Round(28 * s), radius := Round(10 * s), ring := Round(3 * s)
    headerH := Round(96 * s), captionH := Round(44 * s), footerH := Round(36 * s)
    cols := Min(count, 3), rows := Ceil(count / cols), aspect := rect.right / rect.bottom
    tileW := Floor(Min(
        (rect.right * 0.9 - 2 * pad - (cols - 1) * gap) / cols,
        ((rect.bottom * 0.88 - headerH - footerH - 2 * pad - (rows - 1) * gap) / rows - captionH) * aspect))
    tileH := Floor(tileW / aspect)
    gridW := cols * (tileW + gap) - gap
    look := {w: tileW, h: tileH, radius: radius, ring: ring}

    current := GrabScreen(rect, tileW, tileH)   ; before the dim covers it
    overlay := Gui("-Caption +ToolWindow +AlwaysOnTop -DPIScale")
    overlay.BackColor := "000000"
    WinSetTransparent 150, overlay
    overlay.Show(Format("x{} y{} w{} h{} NoActivate", rect.left, rect.top, rect.right, rect.bottom))

    card := Gui("-Caption +ToolWindow +AlwaysOnTop -DPIScale +Owner" overlay.Hwnd)
    card.BackColor := "282828"
    card.MarginX := pad, card.MarginY := pad
    card.SetFont("s18 w600 cebdbb2", "Segoe UI Variable Display")
    card.AddText("xm", "Workspaces")
    used := 0
    for list in windows
        used += list.Length > 0
    card.SetFont("s10 w400 c928374", "Segoe UI")
    card.AddText("xm y+4", Format("Monitor {}  ·  {} of {} in use", state.monitors.focused + 1, used, workspaces.length))

    wall := TileWallpaper(tileW, tileH)
    tiles := [], byHwnd := Map()
    loop count {
        i := A_Index, ws := workspaces.%i - 1%, list := windows[i]
        x := pad + Mod(i - 1, cols) * (tileW + gap)
        y := pad + headerH + (i - 1) // cols * (tileH + captionH + gap)
        tile := {index: i, pending: i != focused && list.Length > 0}
        SetTileBase(tile, i = focused ? current : SnapWorkspace([], rect, tileW, tileH, wall), look)
        ; "*": the picture shows a copy, so both states stay ours to swap in.
        tile.pic := card.AddPicture(Format("x{} y{} w{} h{}", x, y, tileW, tileH), "HBITMAP:*" tile.off)
        ; Caption: "● 2  name" on the left, window count on the right.
        cy := y + tileH + Round(10 * s)
        card.SetFont("s11 w600 c" (i = focused ? "fabd2f" : "ebdbb2"), "Segoe UI")
        name := ws.name != "" && ws.name != String(i) ? "   " ws.name : ""
        tile.caption := card.AddText(Format("x{} y{} w{} BackgroundTrans", x + Round(2 * s), cy, tileW // 2), (i = focused ? "●  " : "") i name)
        card.SetFont("s10 w400 c928374", "Segoe UI")
        tile.meta := card.AddText(Format("x{} y{} w{} Right BackgroundTrans", x + tileW // 2, cy + Round(2 * s), tileW // 2 - Round(2 * s)),
            list.total ? list.total (list.total = 1 ? " window" : " windows") : "empty")
        for control in [tile.pic, tile.caption, tile.meta] {
            control.OnEvent("Click", OverviewGo.Bind(i))
            byHwnd[control.Hwnd] := i
        }
        tiles.Push(tile)
    }
    card.SetFont("s9 w400 c7c6f64", "Segoe UI")
    card.AddText(Format("x{} y{} w{} Center", pad, pad + headerH + rows * (tileH + captionH + gap) - Round(8 * s), gridW),
        "1–9  jump        ←↑↓→  hjkl  move        Enter  open        Shift  take window        Esc  close")

    ; Win11 rounded corners and a subtle border (COLORREF is 0x00BBGGRR).
    DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", card.Hwnd, "UInt", 33, "Int*", 2, "UInt", 4)
    DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", card.Hwnd, "UInt", 34, "UInt*", 0x3c3836, "UInt", 4)

    Overview := {overlay: overlay, card: card, tiles: tiles, byHwnd: byHwnd, selected: 0, cols: cols}
    OverviewSelect(focused)
    card.Show("Hide")
    WinGetPos , , &w, &h, card
    card.Show(Format("x{} y{}", rect.left + (rect.right - w) // 2, rect.top + (rect.bottom - h) // 2))
    SetTimer OverviewWatchFocus, 100

    for tile in tiles {
        ; A key or click while a snapshot is drawn can close the overview.
        if !Overview || Overview.card != card
            return
        if !tile.pending
            continue
        SetTileBase(tile, SnapWorkspace(windows[tile.index], rect, tileW, tileH, wall), look)
        tile.pic.Value := "HBITMAP:*" (Overview.tiles[Overview.selected] = tile ? tile.on : tile.off)
    }
}

OverviewStep(step, *) => OverviewSelect(Overview.selected + step)

OverviewSelect(i) {
    state := Overview
    i := Mod(i - 1 + state.tiles.Length, state.tiles.Length) + 1
    for index in [state.selected, i] {
        if !index
            continue
        tile := state.tiles[index]
        tile.pic.Value := "HBITMAP:*" (index = i ? tile.on : tile.off)
    }
    state.selected := i
}

; i is the workspace number, which is also the tile number. With Shift held the
; focused window moves there too (Komorebi's focus, not the overview card's).
OverviewGo(i, *) {
    command := GetKeyState("Shift") ? "move-to-workspace " : "focus-workspace "
    OverviewClose()
    RunWait("komorebic.exe " command (i - 1), , "Hide")
}

OverviewClose() {
    global Overview
    SetTimer OverviewWatchFocus, 0
    if Overview {
        Overview.overlay.Destroy()   ; the owned card goes with it
        for tile in Overview.tiles
            DllCall("DeleteObject", "Ptr", tile.on), DllCall("DeleteObject", "Ptr", tile.off)
    }
    Overview := 0
}

OverviewWatchFocus() {
    if Overview && !WinActive("ahk_id " Overview.card.Hwnd)
        OverviewClose()
}

OverviewHover(wParam, lParam, msg, hwnd) {
    if Overview && Overview.byHwnd.Has(hwnd) && Overview.byHwnd[hwnd] != Overview.selected
        OverviewSelect(Overview.byHwnd[hwnd])
}

OverviewClickAway(wParam, lParam, msg, hwnd) {
    if Overview && hwnd = Overview.overlay.Hwnd
        OverviewClose()
}
