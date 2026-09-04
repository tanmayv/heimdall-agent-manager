//! REQ PTYH-1: VT screen model.
//!
//! A minimal-but-faithful terminal screen grid driven by the `vte` parser.
//! We maintain a grid of styled cells + a cursor, and interpret the common
//! subset of control sequences that interactive programs emit: text, cursor
//! movement, erase-in-line / erase-in-display, and SGR (colors / bold).
//!
//! The point of the spike is that `capture()` reflects *rendered* screen state
//! (what a user would see) rather than the raw byte stream.

use vte::{Params, Parser, Perform};

/// A single on-screen color. `Default` means "use the terminal default".
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Color {
    Default,
    /// 0-15 ANSI, 16-255 xterm-256 palette.
    Indexed(u8),
    Rgb(u8, u8, u8),
}

impl Default for Color {
    fn default() -> Self {
        Color::Default
    }
}

/// A single grid cell: the glyph plus its rendition attributes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Cell {
    pub c: char,
    pub fg: Color,
    pub bg: Color,
    pub bold: bool,
}

impl Default for Cell {
    fn default() -> Self {
        Cell {
            c: ' ',
            fg: Color::Default,
            bg: Color::Default,
            bold: false,
        }
    }
}

/// A snapshot of the screen for `capture()` / the wire protocol.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Capture {
    pub rows: usize,
    pub cols: usize,
    /// One rendered string per row (trailing blanks trimmed).
    pub lines: Vec<String>,
    /// Full styled grid (row-major, rows*cols cells) for fidelity checks.
    pub cells: Vec<Cell>,
    pub cursor_row: usize,
    pub cursor_col: usize,
}

impl Capture {
    /// Convenience: the styled cell at (row, col), if in bounds.
    pub fn cell_at(&self, row: usize, col: usize) -> Option<Cell> {
        if row < self.rows && col < self.cols {
            self.cells.get(row * self.cols + col).copied()
        } else {
            None
        }
    }
}

/// The terminal screen model. Implements `vte::Perform` so the `Parser` can
/// drive it directly.
pub struct Screen {
    rows: usize,
    cols: usize,
    grid: Vec<Cell>,
    cursor_row: usize,
    cursor_col: usize,
    // Pending rendition applied to freshly printed cells.
    cur_fg: Color,
    cur_bg: Color,
    cur_bold: bool,
    // DECSC / DECRC saved cursor.
    saved_cursor: Option<(usize, usize)>,
    // Deferred wrap: after writing the last column we stay put until the next
    // printable char, matching real terminal "auto-wrap" behavior.
    wrap_pending: bool,
}

impl Screen {
    pub fn new(rows: usize, cols: usize) -> Self {
        let rows = rows.max(1);
        let cols = cols.max(1);
        Screen {
            rows,
            cols,
            grid: vec![Cell::default(); rows * cols],
            cursor_row: 0,
            cursor_col: 0,
            cur_fg: Color::Default,
            cur_bg: Color::Default,
            cur_bold: false,
            saved_cursor: None,
            wrap_pending: false,
        }
    }

    pub fn size(&self) -> (usize, usize) {
        (self.rows, self.cols)
    }

    /// Resize the grid, preserving overlapping content (top-left anchored).
    pub fn resize(&mut self, rows: usize, cols: usize) {
        let rows = rows.max(1);
        let cols = cols.max(1);
        if rows == self.rows && cols == self.cols {
            return;
        }
        let mut new_grid = vec![Cell::default(); rows * cols];
        for r in 0..rows.min(self.rows) {
            for c in 0..cols.min(self.cols) {
                new_grid[r * cols + c] = self.grid[r * self.cols + c];
            }
        }
        self.grid = new_grid;
        self.rows = rows;
        self.cols = cols;
        self.cursor_row = self.cursor_row.min(rows - 1);
        self.cursor_col = self.cursor_col.min(cols - 1);
        self.wrap_pending = false;
    }

    fn idx(&self, row: usize, col: usize) -> usize {
        row * self.cols + col
    }

    fn blank_cell(&self) -> Cell {
        // Erased cells keep the current background (typical terminal behavior),
        // but for the spike we reset to defaults which is sufficient + simpler.
        Cell::default()
    }

    fn scroll_up(&mut self) {
        // Move every row up one; clear the last row.
        self.grid.copy_within(self.cols.., 0);
        let start = (self.rows - 1) * self.cols;
        let blank = self.blank_cell();
        for c in &mut self.grid[start..] {
            *c = blank;
        }
    }

    fn line_feed(&mut self) {
        if self.cursor_row + 1 >= self.rows {
            self.scroll_up();
        } else {
            self.cursor_row += 1;
        }
    }

    fn put_char(&mut self, c: char) {
        if self.wrap_pending {
            self.cursor_col = 0;
            self.line_feed();
            self.wrap_pending = false;
        }
        let i = self.idx(self.cursor_row, self.cursor_col);
        self.grid[i] = Cell {
            c,
            fg: self.cur_fg,
            bg: self.cur_bg,
            bold: self.cur_bold,
        };
        if self.cursor_col + 1 >= self.cols {
            // Defer the wrap until the next printable character.
            self.wrap_pending = true;
        } else {
            self.cursor_col += 1;
        }
    }

    fn clamp_cursor(&mut self) {
        self.cursor_row = self.cursor_row.min(self.rows - 1);
        self.cursor_col = self.cursor_col.min(self.cols - 1);
    }

    fn erase_cells(&mut self, from: usize, to: usize) {
        let blank = self.blank_cell();
        for i in from..to.min(self.grid.len()) {
            self.grid[i] = blank;
        }
    }

    /// Snapshot the current screen state.
    pub fn capture(&self) -> Capture {
        let mut lines = Vec::with_capacity(self.rows);
        for r in 0..self.rows {
            let mut line = String::with_capacity(self.cols);
            for c in 0..self.cols {
                line.push(self.grid[self.idx(r, c)].c);
            }
            // Trim trailing spaces for readability (styled grid keeps full data).
            let trimmed = line.trim_end_matches(' ').to_string();
            lines.push(trimmed);
        }
        Capture {
            rows: self.rows,
            cols: self.cols,
            lines,
            cells: self.grid.clone(),
            cursor_row: self.cursor_row,
            cursor_col: self.cursor_col,
        }
    }

    // ---- SGR (colors / attributes) -------------------------------------

    fn apply_sgr(&mut self, params: &Params) {
        // Collect into a flat vec so we can look ahead for 38;5;n / 38;2;r;g;b.
        let flat: Vec<u16> = params.iter().map(|p| p.first().copied().unwrap_or(0)).collect();
        if flat.is_empty() {
            self.reset_sgr();
            return;
        }
        let mut i = 0;
        while i < flat.len() {
            match flat[i] {
                0 => self.reset_sgr(),
                1 => self.cur_bold = true,
                22 => self.cur_bold = false,
                30..=37 => self.cur_fg = Color::Indexed((flat[i] - 30) as u8),
                39 => self.cur_fg = Color::Default,
                40..=47 => self.cur_bg = Color::Indexed((flat[i] - 40) as u8),
                49 => self.cur_bg = Color::Default,
                90..=97 => self.cur_fg = Color::Indexed((flat[i] - 90 + 8) as u8),
                100..=107 => self.cur_bg = Color::Indexed((flat[i] - 100 + 8) as u8),
                38 => {
                    if let Some((color, adv)) = parse_extended_color(&flat[i..]) {
                        self.cur_fg = color;
                        i += adv;
                        continue;
                    }
                }
                48 => {
                    if let Some((color, adv)) = parse_extended_color(&flat[i..]) {
                        self.cur_bg = color;
                        i += adv;
                        continue;
                    }
                }
                _ => {}
            }
            i += 1;
        }
    }

    fn reset_sgr(&mut self) {
        self.cur_fg = Color::Default;
        self.cur_bg = Color::Default;
        self.cur_bold = false;
    }
}

/// Parse a `38;5;n` (indexed) or `38;2;r;g;b` (truecolor) run.
/// Returns (color, number-of-params-consumed).
fn parse_extended_color(seq: &[u16]) -> Option<(Color, usize)> {
    match seq.get(1) {
        Some(5) => {
            let n = *seq.get(2)? as u8;
            Some((Color::Indexed(n), 3))
        }
        Some(2) => {
            let r = *seq.get(2)? as u8;
            let g = *seq.get(3)? as u8;
            let b = *seq.get(4)? as u8;
            Some((Color::Rgb(r, g, b), 5))
        }
        _ => None,
    }
}

fn first(params: &Params, default: u16) -> u16 {
    let v = params.iter().next().and_then(|p| p.first().copied()).unwrap_or(0);
    if v == 0 { default } else { v }
}

fn nth(params: &Params, n: usize, default: u16) -> u16 {
    let v = params.iter().nth(n).and_then(|p| p.first().copied()).unwrap_or(0);
    if v == 0 { default } else { v }
}

impl Perform for Screen {
    fn print(&mut self, c: char) {
        self.put_char(c);
    }

    fn execute(&mut self, byte: u8) {
        match byte {
            b'\n' => {
                self.wrap_pending = false;
                self.line_feed();
            }
            b'\r' => {
                self.wrap_pending = false;
                self.cursor_col = 0;
            }
            b'\t' => {
                self.wrap_pending = false;
                let next = ((self.cursor_col / 8) + 1) * 8;
                self.cursor_col = next.min(self.cols - 1);
            }
            0x08 => {
                // backspace
                self.wrap_pending = false;
                if self.cursor_col > 0 {
                    self.cursor_col -= 1;
                }
            }
            _ => {}
        }
    }

    fn csi_dispatch(&mut self, params: &Params, _intermediates: &[u8], _ignore: bool, action: char) {
        match action {
            'A' => {
                let n = first(params, 1) as usize;
                self.cursor_row = self.cursor_row.saturating_sub(n);
                self.wrap_pending = false;
            }
            'B' => {
                let n = first(params, 1) as usize;
                self.cursor_row = (self.cursor_row + n).min(self.rows - 1);
                self.wrap_pending = false;
            }
            'C' => {
                let n = first(params, 1) as usize;
                self.cursor_col = (self.cursor_col + n).min(self.cols - 1);
                self.wrap_pending = false;
            }
            'D' => {
                let n = first(params, 1) as usize;
                self.cursor_col = self.cursor_col.saturating_sub(n);
                self.wrap_pending = false;
            }
            'G' => {
                let col = first(params, 1) as usize;
                self.cursor_col = col.saturating_sub(1).min(self.cols - 1);
                self.wrap_pending = false;
            }
            'd' => {
                let row = first(params, 1) as usize;
                self.cursor_row = row.saturating_sub(1).min(self.rows - 1);
                self.wrap_pending = false;
            }
            'H' | 'f' => {
                let row = first(params, 1) as usize;
                let col = nth(params, 1, 1) as usize;
                self.cursor_row = row.saturating_sub(1).min(self.rows - 1);
                self.cursor_col = col.saturating_sub(1).min(self.cols - 1);
                self.wrap_pending = false;
            }
            'J' => {
                // Erase in Display.
                let mode = params.iter().next().and_then(|p| p.first().copied()).unwrap_or(0);
                let cur = self.idx(self.cursor_row, self.cursor_col);
                match mode {
                    0 => self.erase_cells(cur, self.grid.len()),
                    1 => self.erase_cells(0, cur + 1),
                    2 | 3 => {
                        let len = self.grid.len();
                        self.erase_cells(0, len);
                    }
                    _ => {}
                }
                self.wrap_pending = false;
            }
            'K' => {
                // Erase in Line.
                let mode = params.iter().next().and_then(|p| p.first().copied()).unwrap_or(0);
                let row_start = self.idx(self.cursor_row, 0);
                let cur = self.idx(self.cursor_row, self.cursor_col);
                let row_end = row_start + self.cols;
                match mode {
                    0 => self.erase_cells(cur, row_end),
                    1 => self.erase_cells(row_start, cur + 1),
                    2 => self.erase_cells(row_start, row_end),
                    _ => {}
                }
                self.wrap_pending = false;
            }
            'm' => self.apply_sgr(params),
            's' => self.saved_cursor = Some((self.cursor_row, self.cursor_col)),
            'u' => {
                if let Some((r, c)) = self.saved_cursor {
                    self.cursor_row = r;
                    self.cursor_col = c;
                    self.clamp_cursor();
                }
            }
            _ => {}
        }
    }

    fn esc_dispatch(&mut self, _intermediates: &[u8], _ignore: bool, byte: u8) {
        match byte {
            b'7' => self.saved_cursor = Some((self.cursor_row, self.cursor_col)),
            b'8' => {
                if let Some((r, c)) = self.saved_cursor {
                    self.cursor_row = r;
                    self.cursor_col = c;
                    self.clamp_cursor();
                }
            }
            b'c' => {
                // RIS - full reset.
                let blank = self.blank_cell();
                for cell in &mut self.grid {
                    *cell = blank;
                }
                self.cursor_row = 0;
                self.cursor_col = 0;
                self.reset_sgr();
                self.wrap_pending = false;
            }
            b'D' => self.line_feed(),
            b'M' => {
                // Reverse index.
                if self.cursor_row == 0 {
                    // scroll down
                    let cols = self.cols;
                    let end = self.grid.len() - cols;
                    self.grid.copy_within(0..end, cols);
                    let blank = self.blank_cell();
                    for c in &mut self.grid[0..cols] {
                        *c = blank;
                    }
                } else {
                    self.cursor_row -= 1;
                }
            }
            _ => {}
        }
    }

    // DCS / OSC are ignored for the spike (title-setting etc. don't affect grid).
    fn hook(&mut self, _params: &Params, _intermediates: &[u8], _ignore: bool, _action: char) {}
    fn put(&mut self, _byte: u8) {}
    fn unhook(&mut self) {}
    fn osc_dispatch(&mut self, _params: &[&[u8]], _bell_terminated: bool) {}
}

/// A VT engine: owns the `vte::Parser` + a `Screen`, feeding bytes in.
pub struct VtEngine {
    parser: Parser,
    pub screen: Screen,
}

impl VtEngine {
    pub fn new(rows: usize, cols: usize) -> Self {
        VtEngine {
            parser: Parser::new(),
            screen: Screen::new(rows, cols),
        }
    }

    /// Feed raw PTY bytes through the parser into the screen model.
    pub fn feed(&mut self, bytes: &[u8]) {
        self.parser.advance(&mut self.screen, bytes);
    }

    pub fn capture(&self) -> Capture {
        self.screen.capture()
    }

    pub fn resize(&mut self, rows: usize, cols: usize) {
        self.screen.resize(rows, cols);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn feed(engine: &mut VtEngine, s: &str) {
        engine.feed(s.as_bytes());
    }

    #[test]
    fn plain_text_renders_not_raw_bytes() {
        let mut e = VtEngine::new(4, 20);
        feed(&mut e, "hello world");
        let cap = e.capture();
        assert_eq!(cap.lines[0], "hello world");
        assert_eq!(cap.cursor_row, 0);
        assert_eq!(cap.cursor_col, 11);
    }

    #[test]
    fn newline_and_carriage_return() {
        let mut e = VtEngine::new(4, 20);
        feed(&mut e, "line1\r\nline2");
        let cap = e.capture();
        assert_eq!(cap.lines[0], "line1");
        assert_eq!(cap.lines[1], "line2");
    }

    #[test]
    fn cursor_move_and_overwrite() {
        let mut e = VtEngine::new(4, 20);
        feed(&mut e, "XXXXX");
        // Move cursor to column 1 (1-based) and overwrite.
        feed(&mut e, "\x1b[1G");
        feed(&mut e, "ab");
        let cap = e.capture();
        assert_eq!(cap.lines[0], "abXXX");
    }

    #[test]
    fn absolute_cursor_position() {
        let mut e = VtEngine::new(5, 20);
        feed(&mut e, "\x1b[3;5Hhi");
        let cap = e.capture();
        // row 3 (index 2), col 5 (index 4)
        assert_eq!(cap.lines[2], "    hi");
        assert_eq!(cap.cursor_row, 2);
        assert_eq!(cap.cursor_col, 6);
    }

    #[test]
    fn erase_line_and_display() {
        let mut e = VtEngine::new(3, 10);
        feed(&mut e, "abcdefghij");
        feed(&mut e, "\r\nsecond");
        // Move to home, erase entire display.
        feed(&mut e, "\x1b[H\x1b[2J");
        let cap = e.capture();
        assert_eq!(cap.lines[0], "");
        assert_eq!(cap.lines[1], "");
    }

    #[test]
    fn erase_to_end_of_line() {
        let mut e = VtEngine::new(2, 10);
        feed(&mut e, "abcdefgh");
        feed(&mut e, "\x1b[1;4H"); // col 4 (index 3)
        feed(&mut e, "\x1b[0K");
        let cap = e.capture();
        assert_eq!(cap.lines[0], "abc");
    }

    #[test]
    fn ansi_color_is_captured_as_rendition_not_text() {
        let mut e = VtEngine::new(2, 20);
        // Red foreground, bold, then a char, then reset.
        feed(&mut e, "\x1b[1;31mR\x1b[0mx");
        let cap = e.capture();
        // The text must be the rendered chars, NOT the escape bytes.
        assert_eq!(cap.lines[0], "Rx");
        let red = cap.cell_at(0, 0).unwrap();
        assert_eq!(red.c, 'R');
        assert_eq!(red.fg, Color::Indexed(1));
        assert!(red.bold);
        let plain = cap.cell_at(0, 1).unwrap();
        assert_eq!(plain.c, 'x');
        assert_eq!(plain.fg, Color::Default);
        assert!(!plain.bold);
    }

    #[test]
    fn truecolor_and_256_color() {
        let mut e = VtEngine::new(1, 10);
        feed(&mut e, "\x1b[38;2;10;20;30mA");
        feed(&mut e, "\x1b[38;5;123mB");
        let cap = e.capture();
        assert_eq!(cap.cell_at(0, 0).unwrap().fg, Color::Rgb(10, 20, 30));
        assert_eq!(cap.cell_at(0, 1).unwrap().fg, Color::Indexed(123));
    }

    #[test]
    fn scrolling_when_output_exceeds_rows() {
        let mut e = VtEngine::new(2, 10);
        feed(&mut e, "a\r\nb\r\nc");
        let cap = e.capture();
        // First line scrolled off; b then c remain.
        assert_eq!(cap.lines[0], "b");
        assert_eq!(cap.lines[1], "c");
    }

    #[test]
    fn autowrap_at_last_column() {
        let mut e = VtEngine::new(3, 3);
        feed(&mut e, "abcd");
        let cap = e.capture();
        assert_eq!(cap.lines[0], "abc");
        assert_eq!(cap.lines[1], "d");
    }

    #[test]
    fn resize_preserves_content() {
        let mut e = VtEngine::new(3, 10);
        feed(&mut e, "hello");
        e.resize(5, 20);
        let cap = e.capture();
        assert_eq!(cap.lines[0], "hello");
        assert_eq!(cap.rows, 5);
        assert_eq!(cap.cols, 20);
    }
}
