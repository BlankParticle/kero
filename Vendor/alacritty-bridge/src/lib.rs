//! C ABI over `alacritty_terminal` for Kero's Alacritty backend.
//!
//! `alacritty_terminal` is emulation only — VT parser, grid, PTY, selection —
//! with no renderer of any kind. This crate owns the terminal state and the
//! PTY read loop, and hands Swift a flat snapshot of the visible grid to draw
//! with a Metal renderer backed by a CoreText glyph atlas. Everything that
//! would need a reply written back to the PTY (DSR, color queries, text-area
//! size) is answered here rather than crossing the boundary twice.
//!
//! Threading: the PTY read loop runs on its own thread and mutates the
//! terminal behind a `FairMutex`. Every `kero_alacritty_*` entry point takes
//! that lock, so Swift may call them from the main thread while the loop runs.
//! The snapshot buffer is owned by the handle and is only valid until the next
//! call on that handle.

use std::collections::VecDeque;
use std::ffi::{c_char, c_void, CStr};
use std::os::fd::{AsRawFd, RawFd};
use std::path::PathBuf;
use std::sync::{Arc, OnceLock};

use alacritty_terminal::event::{Event, EventListener, Notify, OnResize, WindowSize};
use alacritty_terminal::event_loop::{EventLoop, EventLoopSender, Msg, Notifier};
use alacritty_terminal::grid::{Dimensions, Scroll};
use alacritty_terminal::index::Direction;
use alacritty_terminal::index::{Column, Line, Point, Side};
use alacritty_terminal::selection::{Selection, SelectionType};
use alacritty_terminal::sync::FairMutex;
use alacritty_terminal::term::cell::{Cell, Flags};
use alacritty_terminal::term::color::Colors;
use alacritty_terminal::term::search::{RegexIter, RegexSearch};
use alacritty_terminal::term::{Config, Osc52, Term, TermDamage, TermMode};
use alacritty_terminal::tty;
use alacritty_terminal::vte::ansi::{Color, CursorShape, CursorStyle, NamedColor, Rgb};

// MARK: - C types

/// Event kinds pushed to Swift from the PTY thread. Swift bounces these onto
/// the main thread before touching any view state.
pub const KERO_EVENT_WAKEUP: u32 = 0;
pub const KERO_EVENT_TITLE: u32 = 1;
pub const KERO_EVENT_BELL: u32 = 2;
pub const KERO_EVENT_EXIT: u32 = 3;
pub const KERO_EVENT_CLIPBOARD_STORE: u32 = 4;
pub const KERO_EVENT_CLIPBOARD_LOAD: u32 = 5;

/// Per-cell attributes handed to the renderer. A subset of
/// `alacritty_terminal`'s `Flags` plus Kero's own `SELECTED`.
pub const KERO_CELL_INVERSE: u16 = 1 << 0;
pub const KERO_CELL_BOLD: u16 = 1 << 1;
pub const KERO_CELL_ITALIC: u16 = 1 << 2;
pub const KERO_CELL_UNDERLINE: u16 = 1 << 3;
pub const KERO_CELL_STRIKEOUT: u16 = 1 << 4;
pub const KERO_CELL_DIM: u16 = 1 << 5;
pub const KERO_CELL_HIDDEN: u16 = 1 << 6;
pub const KERO_CELL_WIDE: u16 = 1 << 7;
pub const KERO_CELL_WIDE_SPACER: u16 = 1 << 8;
pub const KERO_CELL_SELECTED: u16 = 1 << 9;

/// Nothing changed; the host can drop the frame entirely.
pub const KERO_DAMAGE_NONE: u32 = 0;
/// Only the listed rows changed.
pub const KERO_DAMAGE_PARTIAL: u32 = 1;
/// Everything changed — a resize, a screen swap, a scroll.
pub const KERO_DAMAGE_FULL: u32 = 2;

#[repr(C)]
pub struct KeroDamage {
    pub kind: u32,
    /// Viewport row indices, owned by the handle and valid only until the next
    /// call on it. Empty unless `kind` is `KERO_DAMAGE_PARTIAL`.
    pub rows: *const usize,
    pub rows_len: usize,
}

pub type KeroEventCallback =
    extern "C" fn(context: *mut c_void, kind: u32, data: *const u8, len: usize);

#[repr(C)]
#[derive(Clone, Copy)]
pub struct KeroCell {
    /// Unicode scalar; a space for an empty cell.
    pub ch: u32,
    /// Packed 0x00RRGGBB, already resolved through the palette and any OSC 4
    /// overrides — the renderer never resolves colors itself.
    pub fg: u32,
    pub bg: u32,
    /// UTF-8 text in `KeroSnapshot::text` when this cell has combining marks.
    pub text_offset: u32,
    pub text_len: u16,
    pub flags: u16,
}

/// A theme in the form the bridge resolves colors against. Kero owns the
/// palette so Alacritty panes match Ghostty panes exactly.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct KeroTheme {
    pub palette: [u32; 256],
    pub foreground: u32,
    pub background: u32,
    pub cursor: u32,
}

#[repr(C)]
pub struct KeroSnapshot {
    /// `columns * rows` cells in row-major order, owned by the handle and
    /// valid only until the next call on it.
    pub cells: *const KeroCell,
    pub columns: usize,
    pub rows: usize,
    /// Viewport-relative cursor, or -1 when it should not be drawn.
    pub cursor_line: isize,
    pub cursor_column: isize,
    pub cursor_shape: u32,
    pub cursor_color: u32,
    pub background: u32,
    pub cursor_blinking: bool,
    /// UTF-8 backing for cells whose `text_len` is non-zero.
    pub text: *const u8,
    pub text_len: usize,
    /// Rows scrolled back from the live prompt, and the total including
    /// scrollback — together these drive Kero's overlay scrollbar.
    pub display_offset: usize,
    pub total_lines: usize,
    pub screen_lines: usize,
}

#[repr(C)]
pub struct KeroConfig {
    /// Shell to exec, and its argv beyond argv[0].
    pub shell: *const c_char,
    pub args: *const *const c_char,
    pub args_len: usize,
    pub working_directory: *const c_char,
    /// `KEY=VALUE` pairs.
    pub env: *const *const c_char,
    pub env_len: usize,
    pub columns: u16,
    pub rows: u16,
    pub cell_width: u16,
    pub cell_height: u16,
    pub scrollback_lines: usize,
}

// MARK: - Event proxy

/// Swift's view pointer, carried to the PTY thread. Kero keeps the surface
/// alive for as long as the handle exists, and every callback is bounced onto
/// the main thread on the Swift side before it touches anything.
#[derive(Clone, Copy)]
struct SwiftContext(*mut c_void);
unsafe impl Send for SwiftContext {}
unsafe impl Sync for SwiftContext {}

/// State the PTY thread needs in order to answer queries without calling into
/// Swift: the palette for color reports, and the geometry for size reports.
/// Per terminal, since Kero runs many panes at different sizes.
struct Shared {
    theme: KeroTheme,
    window_size: WindowSize,
    /// OSC 52 read formatters waiting for Kero's confirmation sheet. Keeping
    /// the formatter here preserves whether the request used BEL or ST.
    pending_clipboard: VecDeque<(u64, Arc<dyn Fn(&str) -> String + Sync + Send + 'static>)>,
    next_clipboard_id: u64,
}

#[derive(Clone)]
struct Proxy {
    callback: KeroEventCallback,
    context: SwiftContext,
    /// Filled once the event loop exists. Replies that the terminal generates
    /// on its own (DSR, color and size queries) are written straight back here
    /// instead of crossing into Swift and back.
    sender: Arc<OnceLock<EventLoopSender>>,
    shared: Arc<FairMutex<Shared>>,
}

impl Proxy {
    fn emit(&self, kind: u32, payload: &[u8]) {
        (self.callback)(self.context.0, kind, payload.as_ptr(), payload.len());
    }

    fn write_pty(&self, text: String) {
        if let Some(sender) = self.sender.get() {
            let _ = sender.send(Msg::Input(text.into_bytes().into()));
        }
    }
}

impl EventListener for Proxy {
    fn send_event(&self, event: Event) {
        match event {
            Event::Wakeup => self.emit(KERO_EVENT_WAKEUP, &[]),
            Event::Bell => self.emit(KERO_EVENT_BELL, &[]),
            Event::Title(title) => self.emit(KERO_EVENT_TITLE, title.as_bytes()),
            // Kero derives the tab title from the shell and directory, so a
            // reset is simply the absence of a title.
            Event::ResetTitle => self.emit(KERO_EVENT_TITLE, &[]),
            Event::Exit | Event::ChildExit(_) => self.emit(KERO_EVENT_EXIT, &[]),
            Event::ClipboardStore(_, text) => {
                self.emit(KERO_EVENT_CLIPBOARD_STORE, text.as_bytes())
            }
            Event::ClipboardLoad(_, format) => {
                let id = {
                    let mut shared = self.shared.lock();
                    let id = shared.next_clipboard_id;
                    shared.next_clipboard_id = shared.next_clipboard_id.wrapping_add(1).max(1);
                    // A malicious stream must not retain unbounded formatters
                    // while confirmation sheets are waiting.
                    if shared.pending_clipboard.len() >= 16 {
                        shared.pending_clipboard.pop_front();
                    }
                    shared.pending_clipboard.push_back((id, format));
                    id
                };
                self.emit(KERO_EVENT_CLIPBOARD_LOAD, &id.to_le_bytes());
            }
            Event::PtyWrite(text) => self.write_pty(text),
            Event::ColorRequest(index, format) => {
                let theme = self.shared.lock().theme;
                self.write_pty(format(unpack(color_for_index(index, &theme))));
            }
            Event::TextAreaSizeRequest(format) => {
                let size = self.shared.lock().window_size;
                self.write_pty(format(size));
            }
            Event::MouseCursorDirty | Event::CursorBlinkingChange => {}
        }
    }
}

// MARK: - Handle

struct TermSize {
    columns: usize,
    screen_lines: usize,
}

impl Dimensions for TermSize {
    fn total_lines(&self) -> usize {
        self.screen_lines
    }

    fn screen_lines(&self) -> usize {
        self.screen_lines
    }

    fn columns(&self) -> usize {
        self.columns
    }
}

pub struct KeroTerminal {
    term: Arc<FairMutex<Term<Proxy>>>,
    notifier: Notifier,
    shared: Arc<FairMutex<Shared>>,
    cells: Vec<KeroCell>,
    /// Variable-length UTF-8 cell contents for combining character clusters.
    cell_text: Vec<u8>,
    child_pid: i32,
    /// Kept so the host can ask which process group is in the foreground —
    /// that is how Kero tells a shell at its prompt from a running TUI.
    master_fd: RawFd,
    /// Every match of the active find, in buffer order, and which one is
    /// selected. Collected up front so the host can show a total.
    matches: Vec<(Point, Point)>,
    match_index: usize,
    /// Reused per frame so damage reporting does not allocate.
    dirty_rows: Vec<usize>,
    /// Set once the shell has exited, so teardown does not wait on a loop that
    /// has already stopped.
    exited: bool,
}

fn pack(rgb: Rgb) -> u32 {
    ((rgb.r as u32) << 16) | ((rgb.g as u32) << 8) | rgb.b as u32
}

fn unpack(value: u32) -> Rgb {
    Rgb {
        r: (value >> 16) as u8,
        g: (value >> 8) as u8,
        b: value as u8,
    }
}

/// Two thirds brightness, matching how terminals conventionally render SGR 2.
fn dim(value: u32) -> u32 {
    let scale = |channel: u32| (channel * 2 / 3) & 0xff;
    (scale((value >> 16) & 0xff) << 16) | (scale((value >> 8) & 0xff) << 8) | scale(value & 0xff)
}

/// Resolves a `Colors` index — which is `NamedColor as usize` — to the theme.
fn color_for_index(index: usize, theme: &KeroTheme) -> u32 {
    match index {
        0..=255 => theme.palette[index],
        i if i == NamedColor::Foreground as usize => theme.foreground,
        i if i == NamedColor::Background as usize => theme.background,
        i if i == NamedColor::Cursor as usize => theme.cursor,
        i if i == NamedColor::BrightForeground as usize => theme.foreground,
        i if i == NamedColor::DimForeground as usize => dim(theme.foreground),
        i if i >= NamedColor::DimBlack as usize && i <= NamedColor::DimWhite as usize => {
            dim(theme.palette[i - NamedColor::DimBlack as usize])
        }
        _ => theme.foreground,
    }
}

/// OSC 4 / OSC 10-11 overrides win over the theme, exactly as they do in
/// Kero's Ghostty panes.
fn resolve(color: Color, colors: &Colors, theme: &KeroTheme) -> u32 {
    match color {
        Color::Spec(rgb) => pack(rgb),
        Color::Indexed(index) => colors[index as usize]
            .map(pack)
            .unwrap_or_else(|| theme.palette[index as usize]),
        Color::Named(named) => {
            let index = named as usize;
            colors[index]
                .map(pack)
                .unwrap_or_else(|| color_for_index(index, theme))
        }
    }
}

unsafe fn cstr(pointer: *const c_char) -> Option<String> {
    if pointer.is_null() {
        return None;
    }
    CStr::from_ptr(pointer).to_str().ok().map(str::to_owned)
}

unsafe fn cstr_array(pointer: *const *const c_char, len: usize) -> Vec<String> {
    if pointer.is_null() {
        return Vec::new();
    }
    (0..len).filter_map(|i| cstr(*pointer.add(i))).collect()
}

// MARK: - Lifecycle

/// Spawns a shell on a new PTY and starts reading it.
///
/// # Safety
/// Every pointer in `config` must be valid for the duration of the call, and
/// `context` must outlive the returned handle.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_new(
    config: *const KeroConfig,
    theme: *const KeroTheme,
    callback: KeroEventCallback,
    context: *mut c_void,
) -> *mut KeroTerminal {
    if config.is_null() || theme.is_null() {
        return std::ptr::null_mut();
    }
    let config = &*config;
    let columns = config.columns.max(1) as usize;
    let screen_lines = config.rows.max(1) as usize;

    let window_size = WindowSize {
        num_lines: config.rows.max(1),
        num_cols: config.columns.max(1),
        cell_width: config.cell_width.max(1),
        cell_height: config.cell_height.max(1),
    };

    let shell = cstr(config.shell);
    let args = cstr_array(config.args, config.args_len);
    let mut options = tty::Options {
        shell: shell.map(|program| tty::Shell::new(program, args)),
        working_directory: cstr(config.working_directory).map(PathBuf::from),
        drain_on_exit: false,
        ..Default::default()
    };
    for entry in cstr_array(config.env, config.env_len) {
        if let Some((key, value)) = entry.split_once('=') {
            options.env.insert(key.to_owned(), value.to_owned());
        }
    }

    let shared = Arc::new(FairMutex::new(Shared {
        theme: *theme,
        window_size,
        pending_clipboard: VecDeque::new(),
        next_clipboard_id: 1,
    }));
    let proxy = Proxy {
        callback,
        context: SwiftContext(context),
        sender: Arc::new(OnceLock::new()),
        shared: shared.clone(),
    };

    let term_config = Config {
        scrolling_history: config.scrollback_lines.max(1),
        default_cursor_style: CursorStyle {
            shape: CursorShape::Block,
            blinking: true,
        },
        // Kero owns clipboard policy at the app level. Reads are enabled in
        // the emulator only so the host can present its confirmation sheet;
        // the bridge writes nothing back until that request is approved.
        osc52: Osc52::CopyPaste,
        ..Default::default()
    };
    let size = TermSize {
        columns,
        screen_lines,
    };
    let term = Arc::new(FairMutex::new(Term::new(term_config, &size, proxy.clone())));

    let pty = match tty::new(&options, window_size, 0) {
        Ok(pty) => pty,
        Err(_) => return std::ptr::null_mut(),
    };
    let child_pid = pty.child().id() as i32;
    let master_fd = pty.file().as_raw_fd();

    let event_loop = match EventLoop::new(term.clone(), proxy.clone(), pty, false, false) {
        Ok(event_loop) => event_loop,
        Err(_) => return std::ptr::null_mut(),
    };
    let sender = event_loop.channel();
    // Now that the loop exists, terminal-generated replies have somewhere to go.
    let _ = proxy.sender.set(sender.clone());
    event_loop.spawn();

    Box::into_raw(Box::new(KeroTerminal {
        term,
        notifier: Notifier(sender),
        shared,
        cells: Vec::new(),
        cell_text: Vec::new(),
        child_pid,
        master_fd,
        matches: Vec::new(),
        match_index: 0,
        dirty_rows: Vec::new(),
        exited: false,
    }))
}

/// Stops the read loop and releases the handle.
///
/// # Safety
/// `handle` must come from `kero_alacritty_new` and must not be used after.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_free(handle: *mut KeroTerminal) {
    if handle.is_null() {
        return;
    }
    let terminal = Box::from_raw(handle);
    let _ = terminal.notifier.0.send(Msg::Shutdown);
}

/// PID of the shell, for Kero's process panel and its teardown signals.
///
/// # Safety
/// `handle` must be a live handle from `kero_alacritty_new`.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_child_pid(handle: *mut KeroTerminal) -> i32 {
    if handle.is_null() {
        return 0;
    }
    (*handle).child_pid
}

/// PID of the foreground process group on the PTY — the running job rather
/// than the shell that launched it. Falls back to the shell's own PID.
///
/// # Safety
/// `handle` must be a live handle from `kero_alacritty_new`.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_foreground_pid(handle: *mut KeroTerminal) -> i32 {
    if handle.is_null() {
        return 0;
    }
    let terminal = &*handle;
    let pgid = libc_tcgetpgrp(terminal.master_fd);
    if pgid > 0 {
        pgid
    } else {
        terminal.child_pid
    }
}

extern "C" {
    #[link_name = "tcgetpgrp"]
    fn libc_tcgetpgrp(fd: RawFd) -> i32;
}

// MARK: - Input

/// # Safety
/// `handle` must be live and `bytes` valid for `len`.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_write(
    handle: *mut KeroTerminal,
    bytes: *const u8,
    len: usize,
) {
    if handle.is_null() || bytes.is_null() || len == 0 {
        return;
    }
    let terminal = &mut *handle;
    let payload = std::slice::from_raw_parts(bytes, len).to_vec();
    // Any keystroke means the user is done reading scrollback.
    terminal.term.lock().scroll_display(Scroll::Bottom);
    terminal.notifier.notify(payload);
}

/// Writes focus/mouse protocol input without snapping a viewport the user is
/// reading back to the live prompt.
///
/// # Safety
/// `handle` must be live and `bytes` valid for `len`.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_write_control(
    handle: *mut KeroTerminal,
    bytes: *const u8,
    len: usize,
) {
    if handle.is_null() || bytes.is_null() || len == 0 {
        return;
    }
    let terminal = &mut *handle;
    let payload = std::slice::from_raw_parts(bytes, len).to_vec();
    terminal.notifier.notify(payload);
}

/// Completes a pending OSC 52 clipboard read after Kero's confirmation sheet
/// has resolved it. Denied requests are removed without ever writing clipboard
/// contents to the PTY.
///
/// # Safety
/// `handle` must be live and `bytes` valid for `len` when non-null.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_resolve_clipboard(
    handle: *mut KeroTerminal,
    request_id: u64,
    bytes: *const u8,
    len: usize,
    approved: bool,
) {
    if handle.is_null() {
        return;
    }
    let terminal = &mut *handle;
    let format = {
        let mut shared = terminal.shared.lock();
        let Some(index) = shared
            .pending_clipboard
            .iter()
            .position(|(id, _)| *id == request_id)
        else {
            return;
        };
        shared
            .pending_clipboard
            .remove(index)
            .map(|(_, format)| format)
    };
    let Some(format) = format else { return };
    if !approved {
        return;
    }
    let text = if bytes.is_null() || len == 0 {
        ""
    } else {
        std::str::from_utf8(std::slice::from_raw_parts(bytes, len)).unwrap_or("")
    };
    terminal.notifier.notify(format(text).into_bytes());
}

/// # Safety
/// `handle` must be live.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_resize(
    handle: *mut KeroTerminal,
    columns: u16,
    rows: u16,
    cell_width: u16,
    cell_height: u16,
) {
    if handle.is_null() {
        return;
    }
    let terminal = &mut *handle;
    let window_size = WindowSize {
        num_lines: rows.max(1),
        num_cols: columns.max(1),
        cell_width: cell_width.max(1),
        cell_height: cell_height.max(1),
    };
    terminal.shared.lock().window_size = window_size;

    let size = TermSize {
        columns: columns.max(1) as usize,
        screen_lines: rows.max(1) as usize,
    };
    terminal.term.lock().resize(size);
    terminal.notifier.on_resize(window_size);
}

/// Scrolls by `delta` lines, positive toward older output.
///
/// # Safety
/// `handle` must be live.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_scroll(handle: *mut KeroTerminal, delta: i32) {
    if handle.is_null() {
        return;
    }
    (*handle).term.lock().scroll_display(Scroll::Delta(delta));
}

/// Puts the viewport `offset` lines above the live prompt.
///
/// # Safety
/// `handle` must be live.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_scroll_to_offset(handle: *mut KeroTerminal, offset: usize) {
    if handle.is_null() {
        return;
    }
    let terminal = &mut *handle;
    let mut term = terminal.term.lock();
    let current = term.grid().display_offset() as i32;
    term.scroll_display(Scroll::Delta(offset as i32 - current));
}

/// # Safety
/// `handle` must be live and `theme` valid for the call.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_set_theme(
    handle: *mut KeroTerminal,
    theme: *const KeroTheme,
) {
    if handle.is_null() || theme.is_null() {
        return;
    }
    (*handle).shared.lock().theme = *theme;
}

// MARK: - Selection

/// Starts a selection at a viewport cell. `kind` is 0 simple, 1 semantic
/// (word), 2 line — matching single, double, and triple click.
///
/// # Safety
/// `handle` must be live.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_selection_start(
    handle: *mut KeroTerminal,
    line: i32,
    column: usize,
    kind: u32,
    right_half: bool,
) {
    if handle.is_null() {
        return;
    }
    let terminal = &mut *handle;
    let mut term = terminal.term.lock();
    let offset = term.grid().display_offset();
    let point = Point::new(Line(line - offset as i32), Column(column));
    let side = if right_half { Side::Right } else { Side::Left };
    let selection_type = match kind {
        1 => SelectionType::Semantic,
        2 => SelectionType::Lines,
        _ => SelectionType::Simple,
    };
    term.selection = Some(Selection::new(selection_type, point, side));
}

/// # Safety
/// `handle` must be live.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_selection_update(
    handle: *mut KeroTerminal,
    line: i32,
    column: usize,
    right_half: bool,
) {
    if handle.is_null() {
        return;
    }
    let terminal = &mut *handle;
    let mut term = terminal.term.lock();
    let offset = term.grid().display_offset();
    let point = Point::new(Line(line - offset as i32), Column(column));
    let side = if right_half { Side::Right } else { Side::Left };
    if let Some(selection) = term.selection.as_mut() {
        selection.update(point, side);
    }
}

/// # Safety
/// `handle` must be live.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_selection_clear(handle: *mut KeroTerminal) {
    if handle.is_null() {
        return;
    }
    (*handle).term.lock().selection = None;
}

/// Selects every row, scrollback included.
///
/// # Safety
/// `handle` must be live.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_select_all(handle: *mut KeroTerminal) {
    if handle.is_null() {
        return;
    }
    let terminal = &mut *handle;
    let mut term = terminal.term.lock();
    let start = Point::new(term.topmost_line(), Column(0));
    let end = Point::new(term.bottommost_line(), term.last_column());
    let mut selection = Selection::new(SelectionType::Simple, start, Side::Left);
    selection.update(end, Side::Right);
    term.selection = Some(selection);
}

/// Whether anything is selected.
///
/// # Safety
/// `handle` must be live.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_has_selection(handle: *mut KeroTerminal) -> bool {
    if handle.is_null() {
        return false;
    }
    (*handle)
        .term
        .lock()
        .selection_to_string()
        .is_some_and(|text| !text.is_empty())
}

/// Copies the selection into `buffer`, returning the byte length written, or
/// the length required when `buffer` is null or `capacity` is too small.
///
/// # Safety
/// `handle` must be live and `buffer` valid for `capacity` bytes.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_selection_text(
    handle: *mut KeroTerminal,
    buffer: *mut u8,
    capacity: usize,
) -> usize {
    if handle.is_null() {
        return 0;
    }
    let text = (*handle)
        .term
        .lock()
        .selection_to_string()
        .unwrap_or_default();
    let bytes = text.as_bytes();
    if buffer.is_null() || capacity < bytes.len() {
        return bytes.len();
    }
    std::ptr::copy_nonoverlapping(bytes.as_ptr(), buffer, bytes.len());
    bytes.len()
}

// MARK: - Find

/// Counts every match of `needle` in the screen and scrollback, and selects
/// the one nearest the viewport.
///
/// The needle is matched literally: Kero's find bar is a plain text field, so
/// regex metacharacters in it are escaped rather than interpreted.
///
/// # Safety
/// `handle` must be live and `needle` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_find(
    handle: *mut KeroTerminal,
    needle: *const c_char,
) -> usize {
    if handle.is_null() {
        return 0;
    }
    let terminal = &mut *handle;
    terminal.matches.clear();
    terminal.match_index = 0;

    let Some(needle) = cstr(needle).filter(|value| !value.is_empty()) else {
        terminal.term.lock().selection = None;
        return 0;
    };
    let Ok(mut regex) = RegexSearch::new(&regex_escape(&needle)) else {
        return 0;
    };

    let term = terminal.term.lock();
    let start = Point::new(term.topmost_line(), Column(0));
    let end = Point::new(term.bottommost_line(), term.last_column());
    for found in RegexIter::new(start, end, Direction::Right, &term, &mut regex) {
        terminal.matches.push((*found.start(), *found.end()));
        // A pathological pattern on a full scrollback would otherwise scan for
        // long enough to stall the caller, which is on the main thread.
        if terminal.matches.len() >= 10_000 {
            break;
        }
    }
    terminal.matches.len()
}

/// Selects and reveals the next or previous match, returning its zero-based
/// index, or -1 when there are none.
///
/// # Safety
/// `handle` must be live.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_find_step(
    handle: *mut KeroTerminal,
    forward: bool,
) -> isize {
    if handle.is_null() {
        return -1;
    }
    let terminal = &mut *handle;
    let count = terminal.matches.len();
    if count == 0 {
        return -1;
    }

    terminal.match_index = if forward {
        (terminal.match_index + 1) % count
    } else {
        (terminal.match_index + count - 1) % count
    };
    let (start, end) = terminal.matches[terminal.match_index];

    let mut term = terminal.term.lock();
    let mut selection = Selection::new(SelectionType::Simple, start, Side::Left);
    selection.update(end, Side::Right);
    term.selection = Some(selection);
    term.scroll_to_point(start);
    terminal.match_index as isize
}

/// Clears the find and its selection.
///
/// # Safety
/// `handle` must be live.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_find_end(handle: *mut KeroTerminal) {
    if handle.is_null() {
        return;
    }
    let terminal = &mut *handle;
    terminal.matches.clear();
    terminal.match_index = 0;
    terminal.term.lock().selection = None;
}

/// Escapes a literal needle for the regex engine, so a search for `a.b` does
/// not also match `axb`.
fn regex_escape(needle: &str) -> String {
    let mut escaped = String::with_capacity(needle.len() * 2);
    for character in needle.chars() {
        if "\\.+*?()|[]{}^$".contains(character) {
            escaped.push('\\');
        }
        escaped.push(character);
    }
    escaped
}

// MARK: - Screen contents

#[derive(Clone, Debug, PartialEq, Eq)]
struct VtStyle {
    foreground: u32,
    background: u32,
    flags: u16,
    hyperlink: Option<String>,
}

fn style_for(cell: &Cell, colors: &Colors, theme: &KeroTheme) -> VtStyle {
    let mut flags = 0;
    for (source, target) in [
        (Flags::BOLD, KERO_CELL_BOLD),
        (Flags::ITALIC, KERO_CELL_ITALIC),
        (Flags::STRIKEOUT, KERO_CELL_STRIKEOUT),
        (Flags::DIM, KERO_CELL_DIM),
        (Flags::HIDDEN, KERO_CELL_HIDDEN),
        (Flags::INVERSE, KERO_CELL_INVERSE),
    ] {
        if cell.flags.contains(source) {
            flags |= target;
        }
    }
    if cell.flags.intersects(Flags::ALL_UNDERLINES) {
        flags |= KERO_CELL_UNDERLINE;
    }
    VtStyle {
        foreground: resolve(cell.fg, colors, theme),
        background: resolve(cell.bg, colors, theme),
        flags,
        hyperlink: cell.hyperlink().map(|link| link.uri().to_owned()),
    }
}

fn push_sgr(output: &mut Vec<u8>, style: &VtStyle) {
    let foreground = unpack(style.foreground);
    let background = unpack(style.background);
    let mut codes = vec![
        "0".to_owned(),
        format!("38;2;{};{};{}", foreground.r, foreground.g, foreground.b),
        format!("48;2;{};{};{}", background.r, background.g, background.b),
    ];
    for (flag, code) in [
        (KERO_CELL_BOLD, "1"),
        (KERO_CELL_DIM, "2"),
        (KERO_CELL_ITALIC, "3"),
        (KERO_CELL_UNDERLINE, "4"),
        (KERO_CELL_INVERSE, "7"),
        (KERO_CELL_HIDDEN, "8"),
        (KERO_CELL_STRIKEOUT, "9"),
    ] {
        if style.flags & flag != 0 {
            codes.push(code.to_owned());
        }
    }
    output.extend_from_slice(b"\x1b[");
    output.extend_from_slice(codes.join(";").as_bytes());
    output.push(b'm');
}

fn push_hyperlink(output: &mut Vec<u8>, uri: Option<&str>) {
    output.extend_from_slice(b"\x1b]8;;");
    if let Some(uri) = uri {
        output.extend_from_slice(uri.as_bytes());
    }
    output.extend_from_slice(b"\x1b\\");
}

fn cell_has_visible_content(cell: &Cell) -> bool {
    cell.c != ' '
        || cell.zerowidth().is_some_and(|marks| !marks.is_empty())
        || cell.fg != Color::Named(NamedColor::Foreground)
        || cell.bg != Color::Named(NamedColor::Background)
        || cell.flags.intersects(
            Flags::BOLD
                | Flags::ITALIC
                | Flags::ALL_UNDERLINES
                | Flags::STRIKEOUT
                | Flags::DIM
                | Flags::HIDDEN
                | Flags::INVERSE,
        )
        || cell.hyperlink().is_some()
}

/// Serializes screen contents with enough VT state to replay their appearance
/// into either backend. Soft-wrapped rows stay joined so the new terminal can
/// reflow them at its current width.
fn serialize_vt<T: EventListener>(
    term: &Term<T>,
    theme: &KeroTheme,
    scrollback_only: bool,
) -> Vec<u8> {
    let first_line = term.topmost_line();
    let last_line = if scrollback_only {
        Line(-1)
    } else {
        term.bottommost_line()
    };
    if last_line < first_line {
        return Vec::new();
    }

    let colors = term.colors();
    let columns = term.columns();
    let mut output = Vec::new();
    let mut active_style: Option<VtStyle> = None;
    let mut active_link: Option<String> = None;

    for line in (first_line.0..=last_line.0).map(Line::from) {
        let row = &term.grid()[line];
        let wrapped = row[Column(columns - 1)].flags.contains(Flags::WRAPLINE);
        let length = if wrapped {
            columns
        } else {
            row[..]
                .iter()
                .rposition(cell_has_visible_content)
                .map_or(0, |column| column + 1)
        };

        for column in 0..length {
            let cell = &row[Column(column)];
            if cell
                .flags
                .intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER)
            {
                continue;
            }

            let style = style_for(cell, colors, theme);
            if active_style.as_ref() != Some(&style) {
                if active_link.as_deref() != style.hyperlink.as_deref() {
                    if active_link.is_some() {
                        push_hyperlink(&mut output, None);
                    }
                    if let Some(uri) = style.hyperlink.as_deref() {
                        push_hyperlink(&mut output, Some(uri));
                    }
                    active_link = style.hyperlink.clone();
                }
                push_sgr(&mut output, &style);
                active_style = Some(style);
            }

            let mut encoded = [0; 4];
            output.extend_from_slice(cell.c.encode_utf8(&mut encoded).as_bytes());
            for mark in cell.zerowidth().into_iter().flatten() {
                output.extend_from_slice(mark.encode_utf8(&mut encoded).as_bytes());
            }
        }

        if !wrapped {
            if active_link.take().is_some() {
                push_hyperlink(&mut output, None);
            }
            if active_style.take().is_some() {
                output.extend_from_slice(b"\x1b[0m");
            }
            output.extend_from_slice(b"\r\n");
        }
    }
    if active_link.is_some() {
        push_hyperlink(&mut output, None);
    }
    if active_style.is_some() {
        output.extend_from_slice(b"\x1b[0m");
    }
    output
}

/// Writes the whole buffer — scrollback and screen — as a styled VT stream
/// into `buffer`, using the same length protocol as selection text. This backs
/// Kero's history capture and its tab-switcher previews.
///
/// # Safety
/// `handle` must be live and `buffer` valid for `capacity` bytes.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_buffer_text(
    handle: *mut KeroTerminal,
    scrollback_only: bool,
    buffer: *mut u8,
    capacity: usize,
) -> usize {
    if handle.is_null() {
        return 0;
    }
    let terminal = &mut *handle;
    let theme = terminal.shared.lock().theme;
    let term = terminal.term.lock();
    let bytes = serialize_vt(&term, &theme, scrollback_only);
    if buffer.is_null() || capacity < bytes.len() {
        return bytes.len();
    }
    std::ptr::copy_nonoverlapping(bytes.as_ptr(), buffer, bytes.len());
    bytes.len()
}

/// Returns the OSC 8 hyperlink under a viewport cell.
///
/// # Safety
/// `handle` must be live and `buffer` valid for `capacity` bytes.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_hyperlink_at(
    handle: *mut KeroTerminal,
    line: i32,
    column: usize,
    buffer: *mut u8,
    capacity: usize,
) -> usize {
    if handle.is_null() {
        return 0;
    }
    let term = (*handle).term.lock();
    if line < 0 || line as usize >= term.screen_lines() || column >= term.columns() {
        return 0;
    }
    let offset = term.grid().display_offset();
    let point = Point::new(Line(line - offset as i32), Column(column));
    let Some(link) = term.grid()[point].hyperlink() else {
        return 0;
    };
    let bytes = link.uri().as_bytes();
    if buffer.is_null() || capacity < bytes.len() {
        return bytes.len();
    }
    std::ptr::copy_nonoverlapping(bytes.as_ptr(), buffer, bytes.len());
    bytes.len()
}

/// Whether the primary screen has rows above the viewport — Kero uses this to
/// tell a scrolled shell from a full-screen TUI.
///
/// # Safety
/// `handle` must be live.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_has_scrollback(handle: *mut KeroTerminal) -> bool {
    if handle.is_null() {
        return false;
    }
    let term = (*handle).term.lock();
    !term.mode().contains(TermMode::ALT_SCREEN) && term.grid().history_size() > 0
}

/// Clears the screen and the scrollback.
///
/// # Safety
/// `handle` must be live.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_clear(handle: *mut KeroTerminal) {
    if handle.is_null() {
        return;
    }
    let mut term = (*handle).term.lock();
    term.grid_mut().clear_viewport();
    term.grid_mut().clear_history();
}

#[cfg(test)]
mod tests {
    use super::*;
    use alacritty_terminal::event::VoidListener;
    use alacritty_terminal::vte::ansi::Processor;

    fn theme() -> KeroTheme {
        let mut palette = [0; 256];
        for (index, color) in palette.iter_mut().enumerate() {
            *color = index as u32 * 0x010101;
        }
        KeroTheme {
            palette,
            foreground: 0xeeeeee,
            background: 0x111111,
            cursor: 0xffffff,
        }
    }

    fn parse(input: &[u8]) -> Term<VoidListener> {
        let size = TermSize {
            columns: 40,
            screen_lines: 3,
        };
        let mut term = Term::new(Config::default(), &size, VoidListener);
        let mut processor: Processor = Processor::new();
        processor.advance(&mut term, input);
        term
    }

    #[test]
    fn history_export_preserves_style_and_combining_marks() {
        let term = parse(b"\x1b[1;3;38;2;12;34;56mCafe\xcc\x81\x1b[0m");
        let output = serialize_vt(&term, &theme(), false);
        let text = String::from_utf8(output).unwrap();

        assert!(text.contains("\x1b[0;38;2;12;34;56;48;2;17;17;17;1;3m"));
        assert!(text.contains("Cafe\u{301}"));
        assert!(text.contains("\x1b[0m\r\n"));
    }

    #[test]
    fn history_export_preserves_osc8_links() {
        let term = parse(b"\x1b]8;;https://kero.sh\x1b\\Kero\x1b]8;;\x1b\\");
        let output = serialize_vt(&term, &theme(), false);
        let text = String::from_utf8(output).unwrap();

        assert!(text.contains("\x1b]8;;https://kero.sh\x1b\\"));
        assert!(text.contains("Kero"));
        assert!(text.contains("\x1b]8;;\x1b\\"));
    }
}

/// Which viewport rows changed since the last call, resetting the emulator's
/// damage as it goes.
///
/// A wakeup only means bytes arrived, not that the grid moved: a heartbeat, a
/// cursor-position query, or output that overwrites a cell with identical
/// contents all wake the host for nothing. And when something *has* changed it
/// is usually one row — a prompt redraw, a cursor blink — so rebuilding every
/// cell's draw instance is almost all waste.
///
/// Rows rather than the full spans: the renderer caches per row and columns
/// would not let it skip any more work, so carrying them would only widen the
/// FFI. The row list belongs to the handle and is valid until the next call.
///
/// # Safety
/// `handle` must be live and `out` a valid `KeroDamage`.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_take_damage(
    handle: *mut KeroTerminal,
    out: *mut KeroDamage,
) {
    if handle.is_null() || out.is_null() {
        return;
    }
    let terminal = &mut *handle;
    terminal.dirty_rows.clear();

    let mut term = terminal.term.lock();
    let kind = match term.damage() {
        TermDamage::Full => KERO_DAMAGE_FULL,
        TermDamage::Partial(iter) => {
            for bounds in iter {
                terminal.dirty_rows.push(bounds.line);
            }
            if terminal.dirty_rows.is_empty() {
                KERO_DAMAGE_NONE
            } else {
                KERO_DAMAGE_PARTIAL
            }
        }
    };
    term.reset_damage();
    drop(term);

    *out = KeroDamage {
        kind,
        rows: terminal.dirty_rows.as_ptr(),
        rows_len: terminal.dirty_rows.len(),
    };
}

/// Fills `out` with the visible grid.
///
/// The cell array belongs to the handle and stays valid only until the next
/// call on it, which keeps a redraw from allocating.
///
/// # Safety
/// `handle` must be live and `out` must be a valid `KeroSnapshot`.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_snapshot(
    handle: *mut KeroTerminal,
    out: *mut KeroSnapshot,
) {
    if handle.is_null() || out.is_null() {
        return;
    }
    let terminal = &mut *handle;
    let theme = terminal.shared.lock().theme;
    let term = terminal.term.lock();

    let columns = term.columns();
    let screen_lines = term.screen_lines();
    let background = term.colors()[NamedColor::Background as usize]
        .map(pack)
        .unwrap_or(theme.background);

    terminal.cells.clear();
    terminal.cell_text.clear();
    terminal.cells.resize(
        columns * screen_lines,
        KeroCell {
            ch: u32::from(' '),
            fg: theme.foreground,
            bg: background,
            text_offset: 0,
            text_len: 0,
            flags: 0,
        },
    );

    let content = term.renderable_content();
    let selection = content.selection;
    let colors = content.colors;

    for item in content.display_iter {
        // `display_iter` numbers lines relative to the *display*, not the
        // viewport: scrolled back by N, it yields -N..screen_lines-N. Adding
        // the offset maps that onto viewport rows 0..screen_lines. Dropping
        // the negative half instead would blank exactly the N rows the user
        // just scrolled to.
        let line = item.point.line.0 + content.display_offset as i32;
        let column = item.point.column.0;
        if line < 0 || line as usize >= screen_lines || column >= columns {
            continue;
        }
        let cell = item.cell;
        let mut flags = 0u16;
        let source = cell.flags;
        if source.contains(Flags::INVERSE) {
            flags |= KERO_CELL_INVERSE;
        }
        if source.contains(Flags::BOLD) {
            flags |= KERO_CELL_BOLD;
        }
        if source.contains(Flags::ITALIC) {
            flags |= KERO_CELL_ITALIC;
        }
        if source.intersects(Flags::ALL_UNDERLINES) {
            flags |= KERO_CELL_UNDERLINE;
        }
        if source.contains(Flags::STRIKEOUT) {
            flags |= KERO_CELL_STRIKEOUT;
        }
        if source.contains(Flags::DIM) {
            flags |= KERO_CELL_DIM;
        }
        if source.contains(Flags::HIDDEN) {
            flags |= KERO_CELL_HIDDEN;
        }
        if source.contains(Flags::WIDE_CHAR) {
            flags |= KERO_CELL_WIDE;
        }
        if source.intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER) {
            flags |= KERO_CELL_WIDE_SPACER;
        }
        if selection.is_some_and(|range| range.contains(item.point)) {
            flags |= KERO_CELL_SELECTED;
        }

        let (text_offset, text_len) =
            if let Some(marks) = cell.zerowidth().filter(|marks| !marks.is_empty()) {
                let offset = terminal.cell_text.len();
                let mut encoded = [0; 4];
                terminal
                    .cell_text
                    .extend_from_slice(cell.c.encode_utf8(&mut encoded).as_bytes());
                for mark in marks {
                    terminal
                        .cell_text
                        .extend_from_slice(mark.encode_utf8(&mut encoded).as_bytes());
                }
                let len = terminal.cell_text.len() - offset;
                if offset <= u32::MAX as usize && len <= u16::MAX as usize {
                    (offset as u32, len as u16)
                } else {
                    terminal.cell_text.truncate(offset);
                    (0, 0)
                }
            } else {
                (0, 0)
            };

        terminal.cells[line as usize * columns + column] = KeroCell {
            ch: u32::from(cell.c),
            fg: resolve(cell.fg, colors, &theme),
            bg: resolve(cell.bg, colors, &theme),
            text_offset,
            text_len,
            flags,
        };
    }

    let cursor = content.cursor;
    let hidden = !term.mode().contains(TermMode::SHOW_CURSOR)
        || matches!(cursor.shape, CursorShape::Hidden)
        || content.display_offset != 0;
    let (cursor_line, cursor_column) = if hidden {
        (-1, -1)
    } else {
        (cursor.point.line.0 as isize, cursor.point.column.0 as isize)
    };

    *out = KeroSnapshot {
        cells: terminal.cells.as_ptr(),
        columns,
        rows: screen_lines,
        cursor_line,
        cursor_column,
        cursor_shape: match cursor.shape {
            CursorShape::Block => 0,
            CursorShape::Underline => 1,
            CursorShape::Beam => 2,
            CursorShape::HollowBlock => 3,
            _ => 0,
        },
        cursor_color: colors[NamedColor::Cursor as usize]
            .map(pack)
            .unwrap_or(theme.cursor),
        background,
        cursor_blinking: term.cursor_style().blinking,
        text: terminal.cell_text.as_ptr(),
        text_len: terminal.cell_text.len(),
        display_offset: content.display_offset,
        total_lines: term.total_lines(),
        screen_lines,
    };
}

/// Whether the terminal is in an application/alt-screen mode where arrow keys
/// and the keypad take their application forms.
///
/// # Safety
/// `handle` must be live.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_mode(handle: *mut KeroTerminal) -> u32 {
    if handle.is_null() {
        return 0;
    }
    let term = (*handle).term.lock();
    let mode = term.mode();
    let mut result = 0u32;
    if mode.contains(TermMode::APP_CURSOR) {
        result |= 1 << 0;
    }
    if mode.contains(TermMode::APP_KEYPAD) {
        result |= 1 << 1;
    }
    if mode.contains(TermMode::ALT_SCREEN) {
        result |= 1 << 2;
    }
    if mode.contains(TermMode::BRACKETED_PASTE) {
        result |= 1 << 3;
    }
    if mode.intersects(TermMode::MOUSE_MODE) {
        result |= 1 << 4;
    }
    if mode.contains(TermMode::FOCUS_IN_OUT) {
        result |= 1 << 5;
    }
    if mode.contains(TermMode::MOUSE_REPORT_CLICK) {
        result |= 1 << 6;
    }
    if mode.contains(TermMode::MOUSE_DRAG) {
        result |= 1 << 7;
    }
    if mode.contains(TermMode::MOUSE_MOTION) {
        result |= 1 << 8;
    }
    if mode.contains(TermMode::SGR_MOUSE) {
        result |= 1 << 9;
    }
    if mode.contains(TermMode::ALTERNATE_SCROLL) {
        result |= 1 << 10;
    }
    result
}

/// Marks the shell as gone so teardown does not wait on a stopped loop.
///
/// # Safety
/// `handle` must be live.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_mark_exited(handle: *mut KeroTerminal) {
    if handle.is_null() {
        return;
    }
    (*handle).exited = true;
}
