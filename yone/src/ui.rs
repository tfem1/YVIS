//! Terminal output. Progress rendering is throttled so it never costs
//! measurable time; without a TTY Yone prints plain, log-friendly lines.

use crate::error::Result;
use std::io::{self, BufRead, IsTerminal, Write};
use std::time::{Duration, Instant};

pub struct Ui {
    pub color: bool,
    pub tty: bool,
    pub noconfirm: bool,
}

impl Ui {
    pub fn new(color_mode: &str, noconfirm: bool) -> Ui {
        let tty = io::stderr().is_terminal();
        let color = match color_mode {
            "always" => true,
            "never" => false,
            _ => {
                tty && std::env::var_os("NO_COLOR").is_none()
                    && std::env::var("TERM").map(|t| t != "dumb").unwrap_or(true)
            }
        };
        Ui {
            color,
            tty,
            noconfirm,
        }
    }

    fn paint(&self, code: &str, s: &str) -> String {
        if self.color {
            format!("\x1b[{code}m{s}\x1b[0m")
        } else {
            s.to_string()
        }
    }
    pub fn accent(&self, s: &str) -> String {
        self.paint("1;38;5;141", s)
    }
    pub fn bold(&self, s: &str) -> String {
        self.paint("1", s)
    }
    pub fn dim(&self, s: &str) -> String {
        self.paint("2", s)
    }
    pub fn green(&self, s: &str) -> String {
        self.paint("32", s)
    }
    pub fn red(&self, s: &str) -> String {
        self.paint("1;31", s)
    }
    pub fn yellow(&self, s: &str) -> String {
        self.paint("1;33", s)
    }

    pub fn header(&self, msg: &str) {
        eprintln!("{} {}", self.accent("::"), self.bold(msg));
    }
    pub fn stage(&self, n: usize, total: usize, msg: &str) {
        eprintln!("{} {}", self.dim(&format!("({n}/{total})")), msg);
    }
    pub fn info(&self, msg: &str) {
        eprintln!("   {msg}");
    }
    pub fn warn(&self, msg: &str) {
        eprintln!("{} {}", self.yellow("warning:"), msg);
    }
    pub fn success(&self, msg: &str) {
        eprintln!("{} {}", self.green("✓"), msg);
    }

    pub fn confirm(&self, q: &str) -> Result<bool> {
        if self.noconfirm {
            return Ok(true);
        }
        if !io::stdin().is_terminal() {
            crate::bail!("cannot ask for confirmation without a terminal; re-run with --noconfirm");
        }
        eprint!("{} {} [Y/n] ", self.accent("::"), self.bold(q));
        io::stderr().flush().ok();
        let mut line = String::new();
        io::stdin().lock().read_line(&mut line)?;
        let a = line.trim().to_lowercase();
        Ok(a.is_empty() || a == "y" || a == "yes" || a == "o" || a == "oui")
    }

    pub fn bar(&self, frac: f64, width: usize) -> String {
        let f = frac.clamp(0.0, 1.0);
        let filled = (f * width as f64).round() as usize;
        format!(
            "{}{}",
            self.accent(&"━".repeat(filled)),
            self.dim(&"─".repeat(width - filled))
        )
    }

    pub fn progress(&self, line: &str) {
        if self.tty {
            eprint!("\r\x1b[2K{line}");
            io::stderr().flush().ok();
        }
    }
    pub fn progress_end(&self) {
        if self.tty {
            eprint!("\r\x1b[2K");
            io::stderr().flush().ok();
        }
    }
}

/// Rate limiter for progress redraws.
pub struct Throttle(Option<Instant>);
impl Throttle {
    pub fn new() -> Self {
        Throttle(None)
    }
    pub fn ready(&mut self) -> bool {
        let now = Instant::now();
        match self.0 {
            Some(t) if now.duration_since(t) < Duration::from_millis(80) => false,
            _ => {
                self.0 = Some(now);
                true
            }
        }
    }
}

pub fn human_bytes(n: u64) -> String {
    let units = ["B", "KiB", "MiB", "GiB", "TiB"];
    let mut v = n as f64;
    let mut u = 0;
    while v >= 1024.0 && u < units.len() - 1 {
        v /= 1024.0;
        u += 1;
    }
    if u == 0 {
        format!("{n} B")
    } else {
        format!("{v:.1} {}", units[u])
    }
}

pub fn human_eta(secs: f64) -> String {
    if !secs.is_finite() || secs < 0.0 {
        return "--:--".into();
    }
    let s = secs.round() as u64;
    if s >= 3600 {
        format!("{}:{:02}:{:02}", s / 3600, s / 60 % 60, s % 60)
    } else {
        format!("{}:{:02}", s / 60, s % 60)
    }
}
