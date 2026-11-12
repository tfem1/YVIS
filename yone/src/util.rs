use crate::bail;
use crate::error::{Context, Result};
use std::ffi::OsString;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

/// Normalise a path stored inside a package and refuse anything that could
/// escape the installation root.
pub fn safe_rel_path(p: &str) -> Result<String> {
    let mut s = p;
    while let Some(r) = s.strip_prefix("./") {
        s = r;
    }
    let s = s.trim_end_matches('/');
    if s.is_empty() || s == "." {
        bail!("empty path in package");
    }
    if s.starts_with('/') {
        bail!("absolute path '{p}' in package");
    }
    if s.bytes()
        .any(|b| b == b'\n' || b == b'\t' || b == 0 || b == b'\r')
    {
        bail!("control character in path '{}'", p.escape_debug());
    }
    for c in s.split('/') {
        if c.is_empty() || c == "." || c == ".." {
            bail!("unsafe path component in '{p}'");
        }
    }
    Ok(s.to_string())
}

pub fn suffixed(p: &Path, suffix: &str) -> PathBuf {
    let mut s: OsString = p.as_os_str().to_owned();
    s.push(suffix);
    PathBuf::from(s)
}

/// Write a file atomically (temp file + fsync + rename).
pub fn write_atomic(path: &Path, data: &[u8]) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).ctx(|| format!("create {}", parent.display()))?;
    }
    let tmp = suffixed(path, ".tmp");
    {
        let mut f = fs::File::create(&tmp).ctx(|| format!("create {}", tmp.display()))?;
        f.write_all(data)?;
        f.sync_all()?;
    }
    fs::rename(&tmp, path).ctx(|| format!("rename {}", path.display()))?;
    Ok(())
}

pub fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

pub fn euid() -> Option<u32> {
    let s = fs::read_to_string("/proc/self/status").ok()?;
    let line = s.lines().find(|l| l.starts_with("Uid:"))?;
    line.split_whitespace().nth(2)?.parse().ok()
}

pub fn ignore_missing(r: std::io::Result<()>) -> std::io::Result<()> {
    match r {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        other => other,
    }
}
