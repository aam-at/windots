//! Clipboard history dropdown for the YASB clipboard widget: a popup under the
//! click that lists Windows clipboard history (Win+V's store: text, and images
//! as thumbnails), filters as you type, and puts the chosen entry back on the
//! clipboard.
//! Usage: clipboard.exe [preview_length]  (characters of text shown per entry, default 60)
//! Keys: type to filter, Up/Down, Enter, Esc; click a row; wheel scrolls.
//! Build: cargo build --release (setup runs it and copies clipboard.exe here).
#![windows_subsystem = "windows"]

use std::cell::RefCell;
use windows::{
    ApplicationModel::DataTransfer::{
        Clipboard, ClipboardHistoryItem, ClipboardHistoryItemsResultStatus, DataPackageView,
        StandardDataFormats,
    },
    Graphics::Imaging::{
        BitmapAlphaMode, BitmapDecoder, BitmapInterpolationMode, BitmapPixelFormat,
        BitmapTransform, ColorManagementMode, ExifOrientationMode,
    },
    Storage::Streams::{Buffer, DataReader, IBuffer},
    Win32::{
        Foundation::*,
        Graphics::{Dwm::*, Gdi::*},
        System::{LibraryLoader::GetModuleHandleW, SystemInformation::GetTickCount64},
        UI::{HiDpi::*, Input::KeyboardAndMouse::*, WindowsAndMessaging::*},
    },
    core::*,
};

const WIDTH: i32 = 380;
const HEADER: i32 = 44;
const ROW: i32 = 34;
const IMAGE_ROW: i32 = 76;
const THUMB: i32 = 64;
const PAD: i32 = 8;
const CLEAR_W: i32 = 60;
const CLEAR_H: i32 = 28;
/// The list is as tall as this many text rows; taller image rows use it up faster.
const MAX_ROWS: i32 = 8;
const DEFAULT_PREVIEW: usize = 60;

const fn rgb(r: u32, g: u32, b: u32) -> COLORREF {
    COLORREF(r | g << 8 | b << 16)
}
const BG: COLORREF = rgb(0x1d, 0x20, 0x21);
const SELECTED: COLORREF = rgb(0x3c, 0x38, 0x36);
const TEXT: COLORREF = rgb(0xeb, 0xdb, 0xb2);
const DIM: COLORREF = rgb(0x92, 0x83, 0x74);
const EDGE: COLORREF = rgb(0x3c, 0x38, 0x36);
const THUMB_BAR: COLORREF = rgb(0x66, 0x5c, 0x54);

/// A decoded thumbnail: a premultiplied BGRA DIB, in physical pixels.
struct Thumb {
    bitmap: HBITMAP,
    width: i32,
    height: i32,
}

struct Entry {
    /// One-line text preview, or "Image  W×H".
    label: String,
    thumb: Option<Thumb>,
    item: ClipboardHistoryItem,
}

#[derive(Default)]
struct State {
    entries: Vec<Entry>, // newest first
    query: String,
    selected: usize, // position in shown()
    scroll: usize,   // position in shown() of the first visible row
    scale: f32,
    font: HFONT,
    preview: usize,
    clear_hover: bool,
}

impl State {
    fn px(&self, logical: i32) -> i32 {
        (logical as f32 * self.scale).round() as i32
    }

    /// Indexes into `entries` that match the query.
    fn shown(&self) -> Vec<usize> {
        let query = self.query.to_lowercase();
        (0..self.entries.len())
            .filter(|&i| self.entries[i].label.to_lowercase().contains(&query))
            .collect()
    }

    fn row_height(&self, index: usize) -> i32 {
        self.px(if self.entries[index].thumb.is_some() { IMAGE_ROW } else { ROW })
    }

    /// (position in shown(), top within the list, height) of the rows that fit
    /// in the list starting at `scroll`.
    fn layout(&self) -> Vec<(usize, i32, i32)> {
        let limit = self.px(ROW * MAX_ROWS);
        let mut rows: Vec<(usize, i32, i32)> = vec![];
        let mut top = 0;
        for (position, &index) in self.shown().iter().enumerate().skip(self.scroll) {
            let height = self.row_height(index);
            if top + height > limit && !rows.is_empty() {
                break;
            }
            rows.push((position, top, height));
            top += height;
        }
        rows
    }

    /// The last scroll position that still fills the list.
    fn max_scroll(&self) -> usize {
        let limit = self.px(ROW * MAX_ROWS);
        let shown = self.shown();
        let mut used = 0;
        let mut first = shown.len();
        for (position, &index) in shown.iter().enumerate().rev() {
            used += self.row_height(index);
            if used > limit {
                break;
            }
            first = position;
        }
        first.min(shown.len().saturating_sub(1))
    }

    /// The header's "Clear" button, in client coordinates.
    fn clear_rect(&self, width: i32) -> RECT {
        let right = width - self.px(PAD + 6);
        let top = (self.px(HEADER) - self.px(CLEAR_H)) / 2;
        RECT { left: right - self.px(CLEAR_W), top, right, bottom: top + self.px(CLEAR_H) }
    }

    fn height(&self) -> i32 {
        let list: i32 = self.layout().iter().map(|r| r.2).sum();
        self.px(HEADER + PAD * 2) + list.max(self.px(ROW))
    }
}

thread_local! {
    static STATE: RefCell<State> = RefCell::new(State::default());
}

fn tick_file() -> std::path::PathBuf {
    std::env::temp_dir().join("windots-clipboard.tick")
}

fn preview_of(text: &str, max: usize) -> String {
    let line = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if line.chars().count() > max {
        line.chars().take(max).collect::<String>() + "…"
    } else {
        line
    }
}

/// The image scaled to fit `size` pixels, as a DIB, plus its full dimensions.
fn thumbnail(content: &DataPackageView, size: i32) -> Result<(Thumb, u32, u32)> {
    let stream = content.GetBitmapAsync()?.join()?.OpenReadAsync()?.join()?;
    let decoder = BitmapDecoder::CreateAsync(&stream)?.join()?;
    let (w, h) = (decoder.PixelWidth()?, decoder.PixelHeight()?);
    let k = (size as f32 / w.max(h) as f32).min(1.0);
    let (tw, th) = (((w as f32 * k) as u32).max(1), ((h as f32 * k) as u32).max(1));
    let transform = BitmapTransform::new()?;
    transform.SetScaledWidth(tw)?;
    transform.SetScaledHeight(th)?;
    transform.SetInterpolationMode(BitmapInterpolationMode::Fant)?;
    let bitmap = decoder
        .GetSoftwareBitmapTransformedAsync(
            BitmapPixelFormat::Bgra8,
            BitmapAlphaMode::Premultiplied,
            &transform,
            ExifOrientationMode::IgnoreExifOrientation,
            ColorManagementMode::DoNotColorManage,
        )?
        .join()?;
    let len = tw * th * 4;
    let buffer = Buffer::Create(len)?;
    buffer.SetLength(len)?;
    let buffer: IBuffer = buffer.cast()?;
    bitmap.CopyToBuffer(&buffer)?;
    let mut pixels = vec![0u8; len as usize];
    DataReader::FromBuffer(&buffer)?.ReadBytes(&mut pixels)?;

    unsafe {
        let info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: tw as i32,
                biHeight: -(th as i32), // top-down
                biPlanes: 1,
                biBitCount: 32,
                ..Default::default()
            },
            ..Default::default()
        };
        let mut bits = std::ptr::null_mut();
        let bitmap = CreateDIBSection(None, &info, DIB_RGB_COLORS, &mut bits, None, 0)?;
        std::ptr::copy_nonoverlapping(pixels.as_ptr(), bits as *mut u8, pixels.len());
        Ok((Thumb { bitmap, width: tw as i32, height: th as i32 }, w, h))
    }
}

fn load(preview: usize, thumb_size: i32) -> Result<Vec<Entry>> {
    let found = Clipboard::GetHistoryItemsAsync()?.join()?;
    if found.Status()? != ClipboardHistoryItemsResultStatus::Success {
        return Ok(vec![]);
    }
    let mut entries = vec![];
    for item in found.Items()? {
        let content = item.Content()?;
        if content.Contains(&StandardDataFormats::Bitmap()?)? {
            if let Ok((thumb, w, h)) = thumbnail(&content, thumb_size) {
                entries.push(Entry { label: format!("Image  {w}×{h}"), thumb: Some(thumb), item });
            }
        } else if content.Contains(&StandardDataFormats::Text()?)? {
            let text = content.GetTextAsync()?.join()?.to_string();
            entries.push(Entry { label: preview_of(&text, preview), thumb: None, item });
        }
    }
    Ok(entries)
}

fn choose(window: HWND, position: usize) {
    let item = STATE.with_borrow(|s| {
        let index = *s.shown().get(position)?;
        Some(s.entries[index].item.clone())
    });
    if let Some(item) = item {
        let _ = Clipboard::SetHistoryItemAsContent(&item);
    }
    unsafe {
        let _ = DestroyWindow(window);
    }
}

/// Clear the history (pinned items stay), then show what is left.
fn clear_history(window: HWND) {
    let _ = Clipboard::ClearHistory();
    let (preview, size) = STATE.with_borrow(|s| (s.preview, s.px(THUMB)));
    STATE.with_borrow_mut(|s| {
        s.entries = load(preview, size).unwrap_or_default();
        (s.selected, s.scroll) = (0, 0);
    });
    refresh(window);
}

/// Keep the selection in view and resize the popup to the rows shown.
fn refresh(window: HWND) {
    STATE.with_borrow_mut(|s| {
        let count = s.shown().len();
        s.selected = s.selected.min(count.saturating_sub(1));
        s.scroll = s.scroll.min(s.max_scroll());
        if s.selected < s.scroll {
            s.scroll = s.selected;
        }
        while s.scroll < s.selected && !s.layout().iter().any(|r| r.0 == s.selected) {
            s.scroll += 1;
        }
        unsafe {
            let _ = SetWindowPos(
                window,
                None,
                0,
                0,
                s.px(WIDTH),
                s.height(),
                SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE,
            );
        }
    });
    unsafe {
        let _ = InvalidateRect(Some(window), None, false);
    }
}

unsafe fn paint(window: HWND) {
    unsafe {
        let mut ps = PAINTSTRUCT::default();
        let screen = BeginPaint(window, &mut ps);
        let mut client = RECT::default();
        let _ = GetClientRect(window, &mut client);
        let (w, h) = (client.right, client.bottom);
        let dc = CreateCompatibleDC(Some(screen));
        let bitmap = CreateCompatibleBitmap(screen, w, h);
        let old_bitmap = SelectObject(dc, bitmap.into());

        STATE.with_borrow(|s| {
            let brush = |color| CreateSolidBrush(color);
            let fill = |rect: &RECT, color| {
                let b = brush(color);
                FillRect(dc, rect, b);
                let _ = DeleteObject(b.into());
            };
            let text = |label: &str, rect: &mut RECT, color, flags| {
                SetTextColor(dc, color);
                let mut wide: Vec<u16> = label.encode_utf16().collect();
                DrawTextW(dc, &mut wide, rect, flags | DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX);
            };
            fill(&client, BG);
            let old_font = SelectObject(dc, s.font.into());
            SetBkMode(dc, TRANSPARENT);

            let margin = s.px(PAD + 6);
            let button = s.clear_rect(w);
            let mut header = RECT { left: margin, top: 0, right: button.left - s.px(PAD), bottom: s.px(HEADER) };
            if s.query.is_empty() {
                text("Search clipboard history", &mut header, DIM, DT_END_ELLIPSIS);
            } else {
                text(&s.query, &mut header, TEXT, DT_END_ELLIPSIS);
            }
            if s.clear_hover {
                let b = brush(SELECTED);
                let old_brush = SelectObject(dc, b.into());
                let pen = SelectObject(dc, GetStockObject(NULL_PEN));
                let arc = s.px(8);
                let _ = RoundRect(dc, button.left, button.top, button.right, button.bottom, arc, arc);
                SelectObject(dc, pen);
                SelectObject(dc, old_brush);
                let _ = DeleteObject(b.into());
            }
            let mut label = button;
            text("Clear", &mut label, if s.clear_hover { TEXT } else { DIM }, DT_CENTER);
            fill(&RECT { left: 0, top: s.px(HEADER) - 1, right: w, bottom: s.px(HEADER) }, EDGE);

            let list_top = s.px(HEADER + PAD);
            let shown = s.shown();
            if shown.is_empty() {
                let mut r = RECT { left: margin, top: list_top, right: w - margin, bottom: list_top + s.px(ROW) };
                text("Nothing here", &mut r, DIM, DT_LEFT);
            }
            for (position, top, height) in s.layout() {
                let entry = &s.entries[shown[position]];
                let rect = RECT {
                    left: s.px(PAD),
                    top: list_top + top,
                    right: w - s.px(PAD),
                    bottom: list_top + top + height,
                };
                if position == s.selected {
                    let b = brush(SELECTED);
                    let old_brush = SelectObject(dc, b.into());
                    let pen = SelectObject(dc, GetStockObject(NULL_PEN));
                    let arc = s.px(10);
                    let _ = RoundRect(dc, rect.left, rect.top, rect.right, rect.bottom, arc, arc);
                    SelectObject(dc, pen);
                    SelectObject(dc, old_brush);
                    let _ = DeleteObject(b.into());
                }
                let mut r = RECT { left: rect.left + s.px(PAD), right: rect.right - s.px(PAD), ..rect };
                if let Some(thumb) = &entry.thumb {
                    let (x, y) = (r.left, rect.top + (height - thumb.height) / 2);
                    let mem = CreateCompatibleDC(Some(dc));
                    let old = SelectObject(mem, thumb.bitmap.into());
                    let blend = BLENDFUNCTION {
                        BlendOp: AC_SRC_OVER as u8,
                        SourceConstantAlpha: 255,
                        AlphaFormat: AC_SRC_ALPHA as u8,
                        ..Default::default()
                    };
                    let _ = AlphaBlend(dc, x, y, thumb.width, thumb.height, mem, 0, 0, thumb.width, thumb.height, blend);
                    SelectObject(mem, old);
                    let _ = DeleteDC(mem);
                    r.left += s.px(THUMB + PAD);
                }
                text(&entry.label, &mut r, TEXT, DT_END_ELLIPSIS);
            }
            // Scrollbar: only when some rows are off screen.
            let visible = s.layout().len();
            if visible < shown.len() {
                let list_h = h - list_top - s.px(PAD);
                let bar_h = (list_h * visible as i32 / shown.len() as i32).max(s.px(24));
                let travel = list_h - bar_h;
                let top = list_top + travel * s.scroll as i32 / s.max_scroll().max(1) as i32;
                let x = w - s.px(7);
                fill(&RECT { left: x, top, right: x + s.px(4), bottom: top + bar_h }, THUMB_BAR);
            }
            SelectObject(dc, old_font);
        });

        let _ = BitBlt(screen, 0, 0, w, h, Some(dc), 0, 0, SRCCOPY);
        SelectObject(dc, old_bitmap);
        let _ = DeleteObject(bitmap.into());
        let _ = DeleteDC(dc);
        let _ = EndPaint(window, &ps);
    }
}

unsafe extern "system" fn proc(window: HWND, message: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match message {
        WM_PAINT => unsafe { paint(window) },
        WM_ERASEBKGND => return LRESULT(1),
        WM_ACTIVATE if (wparam.0 & 0xffff) as u32 == WA_INACTIVE => unsafe {
            let _ = DestroyWindow(window);
        },
        WM_DESTROY => unsafe {
            // Clicking the widget again deactivates us first, then starts a new
            // process; the stamp lets that one see it was a toggle and exit.
            let _ = std::fs::write(tick_file(), GetTickCount64().to_string());
            PostQuitMessage(0);
        },
        WM_KEYDOWN => {
            let count = STATE.with_borrow(|s| s.shown().len());
            match VIRTUAL_KEY(wparam.0 as u16) {
                VK_ESCAPE => unsafe {
                    let _ = DestroyWindow(window);
                },
                VK_RETURN => choose(window, STATE.with_borrow(|s| s.selected)),
                VK_DOWN => {
                    STATE.with_borrow_mut(|s| s.selected = (s.selected + 1).min(count.saturating_sub(1)));
                    refresh(window);
                }
                VK_UP => {
                    STATE.with_borrow_mut(|s| s.selected = s.selected.saturating_sub(1));
                    refresh(window);
                }
                _ => {}
            }
        }
        WM_CHAR => {
            match wparam.0 as u32 {
                8 => STATE.with_borrow_mut(|s| {
                    s.query.pop();
                }),
                c @ 32.. => {
                    if let Some(c) = char::from_u32(c) {
                        STATE.with_borrow_mut(|s| s.query.push(c));
                    }
                }
                _ => {}
            }
            STATE.with_borrow_mut(|s| (s.selected, s.scroll) = (0, 0));
            refresh(window);
        }
        WM_MOUSEMOVE | WM_LBUTTONUP => {
            let x = (lparam.0 & 0xffff) as i16 as i32;
            let y = (lparam.0 >> 16) as i16 as i32;
            let mut client = RECT::default();
            unsafe {
                let _ = GetClientRect(window, &mut client);
            }
            let on_clear = STATE.with_borrow(|s| {
                let r = s.clear_rect(client.right);
                x >= r.left && x < r.right && y >= r.top && y < r.bottom
            });
            if on_clear && message == WM_LBUTTONUP {
                clear_history(window);
                return LRESULT(0);
            }
            let hit = STATE.with_borrow(|s| {
                let y = y - s.px(HEADER + PAD);
                s.layout().iter().find(|r| y >= r.1 && y < r.1 + r.2).map(|r| r.0)
            });
            if let Some(row) = hit.filter(|_| !on_clear) {
                if message == WM_LBUTTONUP {
                    choose(window, row);
                    return LRESULT(0);
                }
                STATE.with_borrow_mut(|s| s.selected = row);
            }
            STATE.with_borrow_mut(|s| s.clear_hover = on_clear);
            refresh(window);
        }
        WM_MOUSEWHEEL => {
            let delta = (wparam.0 >> 16) as i16;
            STATE.with_borrow_mut(|s| {
                s.scroll = if delta > 0 { s.scroll.saturating_sub(1) } else { (s.scroll + 1).min(s.max_scroll()) };
            });
            refresh(window);
        }
        _ => return unsafe { DefWindowProcW(window, message, wparam, lparam) },
    }
    LRESULT(0)
}

fn main() -> Result<()> {
    if let Ok(text) = std::fs::read_to_string(tick_file()) {
        if let Ok(closed) = text.trim().parse::<u64>() {
            if unsafe { GetTickCount64() }.saturating_sub(closed) < 400 {
                return Ok(());
            }
        }
    }
    let preview = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(DEFAULT_PREVIEW);
    unsafe {
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        let instance: HINSTANCE = GetModuleHandleW(None)?.into();
        let class = w!("WindotsClipboard");
        RegisterClassW(&WNDCLASSW {
            style: CS_DROPSHADOW,
            lpfnWndProc: Some(proc),
            hInstance: instance,
            hCursor: LoadCursorW(None, IDC_ARROW)?,
            lpszClassName: class,
            ..Default::default()
        });

        // Under the click, inside the monitor's work area (below the bar).
        let mut cursor = POINT::default();
        GetCursorPos(&mut cursor)?;
        let monitor = MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST);
        let mut info = MONITORINFO { cbSize: size_of::<MONITORINFO>() as u32, ..Default::default() };
        let _ = GetMonitorInfoW(monitor, &mut info);
        let scale = GetDpiForSystem() as f32 / 96.0;
        let font = CreateFontW(
            -(15.0 * scale).round() as i32, 0, 0, 0, 400, 0, 0, 0,
            DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
            0, w!("Segoe UI"),
        );
        STATE.with_borrow_mut(|s| (s.scale, s.font, s.preview) = (scale, font, preview));
        let (width, height) = STATE.with_borrow(|s| (s.px(WIDTH), s.height()));
        let work = info.rcWork;
        let x = (cursor.x - width / 2).clamp(work.left + 8, (work.right - width - 8).max(work.left));
        let y = work.top + (6.0 * scale) as i32;

        let window = CreateWindowExW(
            WS_EX_TOOLWINDOW | WS_EX_TOPMOST, class, w!(""), WS_POPUP,
            x, y, width, height, None, None, Some(instance), None,
        )?;
        let round = DWMWCP_ROUND;
        let _ = DwmSetWindowAttribute(window, DWMWA_WINDOW_CORNER_PREFERENCE, &round as *const _ as _, 4);
        let _ = DwmSetWindowAttribute(window, DWMWA_BORDER_COLOR, &EDGE as *const _ as _, 4);
        let _ = ShowWindow(window, SW_SHOW);
        let _ = SetForegroundWindow(window);
        let _ = UpdateWindow(window);

        // Shown first, filled after: the popup appears at once, and WinRT wants
        // the calling app in the foreground.
        let thumb_size = STATE.with_borrow(|s| s.px(THUMB));
        STATE.with_borrow_mut(|s| s.entries = load(preview, thumb_size).unwrap_or_default());
        refresh(window);

        let mut msg = MSG::default();
        while GetMessageW(&mut msg, None, 0, 0).as_bool() {
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
    Ok(())
}
