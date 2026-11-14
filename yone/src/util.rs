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

/// `YYYY-MM-DD HH:MM:SS` (UTC) for a Unix time.
pub fn utc(t: u64) -> String {
    let (days, secs) = ((t / 86400) as i64, t % 86400);
    // civil_from_days (Howard Hinnant), valid for every Unix date
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!(
        "{y:04}-{m:02}-{d:02} {:02}:{:02}:{:02}",
        secs / 3600,
        secs / 60 % 60,
        secs % 60
    )
}

/// Append one line to ROOT/var/log/yone.log. Logging never fails a transaction.
pub fn log(cfg: &crate::config::Config, msg: &str) {
    let p = cfg.root.join("var/log/yone.log");
    if let Some(d) = p.parent() {
        let _ = fs::create_dir_all(d);
    }
    if let Ok(mut f) = fs::OpenOptions::new().create(true).append(true).open(&p) {
        let _ = writeln!(f, "[{}] {}", utc(now()), msg);
    }
}

pub fn euid() -> Option<u32> {
    let s = fs::read_to_string("/proc/self/status").ok()?;
    let line = s.lines().find(|l| l.starts_with("Uid:"))?;
    line.split_whitespace().nth(2)?.parse().ok()
}

/// Effective group of this process.
pub fn egid() -> Option<u32> {
    let s = fs::read_to_string("/proc/self/status").ok()?;
    let line = s.lines().find(|l| l.starts_with("Gid:"))?;
    line.split_whitespace().nth(2)?.parse().ok()
}

/// One of the account databases of a root: `etc/passwd` or `etc/group`.
fn account_lines(root: &Path, file: &str) -> Vec<Vec<String>> {
    let Ok(rel) = resolve_in_root(root, file) else {
        return vec![];
    };
    let Ok(text) = fs::read_to_string(root.join(rel)) else {
        return vec![];
    };
    text.lines()
        .filter(|l| !l.starts_with('#'))
        .map(|l| l.split(':').map(str::to_string).collect::<Vec<_>>())
        .filter(|f| f.len() >= 3)
        .collect()
}

/// The id of a user (`etc/passwd`) or group (`etc/group`) of `root`.
pub fn account_id(root: &Path, file: &str, name: &str) -> Option<u32> {
    if name.is_empty() {
        return None;
    }
    account_lines(root, file)
        .into_iter()
        .find(|f| f[0] == name)
        .and_then(|f| f[2].parse().ok())
}

/// The name of a user or group id of `root`.
pub fn account_name(root: &Path, file: &str, id: u32) -> Option<String> {
    account_lines(root, file)
        .into_iter()
        .find(|f| f[2].parse::<u32>().ok() == Some(id))
        .map(|f| f[0].clone())
}

pub fn ignore_missing(r: std::io::Result<()>) -> std::io::Result<()> {
    match r {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        other => other,
    }
}

/// The only extended attribute packages may carry: file capabilities
/// (setcap), e.g. cap_net_raw for ping or cap_sys_nice for kwin_wayland.
pub const CAPABILITY_XATTR: &str = "security.capability";

extern "C" {
    fn lgetxattr(
        path: *const std::ffi::c_char,
        name: *const std::ffi::c_char,
        value: *mut u8,
        size: usize,
    ) -> isize;
    fn lchown(path: *const std::ffi::c_char, owner: u32, group: u32) -> i32;
    fn lsetxattr(
        path: *const std::ffi::c_char,
        name: *const std::ffi::c_char,
        value: *const u8,
        size: usize,
        flags: i32,
    ) -> i32;
}

fn cstr(p: &Path) -> std::io::Result<std::ffi::CString> {
    use std::os::unix::ffi::OsStrExt;
    std::ffi::CString::new(p.as_os_str().as_bytes())
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::InvalidInput, "NUL in path"))
}

/// The file capability of `p`, if it has one.
pub fn get_capability(p: &Path) -> std::io::Result<Option<Vec<u8>>> {
    let path = cstr(p)?;
    let name = std::ffi::CString::new(CAPABILITY_XATTR).unwrap();
    let mut buf = vec![0u8; 256];
    // SAFETY: valid NUL-terminated strings, and buf outlives the call.
    let n = unsafe { lgetxattr(path.as_ptr(), name.as_ptr(), buf.as_mut_ptr(), buf.len()) };
    if n < 0 {
        let e = std::io::Error::last_os_error();
        // ENODATA (61): no capability; EOPNOTSUPP (95): filesystem without xattrs
        return match e.raw_os_error() {
            Some(61) | Some(95) => Ok(None),
            _ => Err(e),
        };
    }
    buf.truncate(n as usize);
    Ok(Some(buf))
}

pub fn set_capability(p: &Path, value: &[u8]) -> std::io::Result<()> {
    let path = cstr(p)?;
    let name = std::ffi::CString::new(CAPABILITY_XATTR).unwrap();
    // SAFETY: valid NUL-terminated strings; value is read for value.len() bytes.
    let r = unsafe { lsetxattr(path.as_ptr(), name.as_ptr(), value.as_ptr(), value.len(), 0) };
    if r != 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(())
}

/// Give `p` (not what it points to) to `uid`:`gid`. Clears the setuid and
/// setgid bits and file capabilities: set those afterwards.
pub fn set_owner(p: &Path, uid: u32, gid: u32) -> std::io::Result<()> {
    let path = cstr(p)?;
    // SAFETY: valid NUL-terminated string.
    if unsafe { lchown(path.as_ptr(), uid, gid) } != 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(())
}

/// Resolve the directories of a package path inside `root` the way a
/// chroot would: absolute symlinks are relative to `root`, `..` never climbs
/// above it. The last component is not followed (it is what gets replaced).
/// `lib/libfoo.so` with `lib -> usr/lib` gives `usr/lib/libfoo.so`, so two
/// spellings of one file always map to the same database entry.
pub fn resolve_in_root(root: &Path, rel: &str) -> Result<String> {
    let rel = safe_rel_path(rel)?;
    let (parent, name) = match rel.rsplit_once('/') {
        Some((p, n)) => (p, n),
        None => return Ok(rel),
    };
    let mut queue: std::collections::VecDeque<String> =
        parent.split('/').map(str::to_string).collect();
    let mut stack: Vec<String> = vec![];
    let mut hops = 0;
    while let Some(c) = queue.pop_front() {
        match c.as_str() {
            "" | "." => continue,
            ".." => {
                stack.pop();
                continue;
            }
            _ => {}
        }
        let mut here = root.to_path_buf();
        here.extend(&stack);
        here.push(&c);
        match fs::symlink_metadata(&here) {
            Ok(m) if m.file_type().is_symlink() => {
                hops += 1;
                if hops > 40 {
                    bail!("too many levels of symbolic links in /{rel}");
                }
                let target = fs::read_link(&here)?;
                let t = target.to_string_lossy();
                if t.starts_with('/') {
                    stack.clear();
                }
                for (i, part) in t.split('/').filter(|x| !x.is_empty()).enumerate() {
                    queue.insert(i, part.to_string());
                }
            }
            _ => stack.push(c),
        }
    }
    stack.push(name.to_string());
    Ok(stack.join("/"))
}

/// Like `resolve_in_root`, for a directory: its last component is followed
/// too, so a package's `lib/` is `usr/lib` when lib -> usr/lib.
pub fn resolve_dir_in_root(root: &Path, rel: &str) -> Result<String> {
    let r = resolve_in_root(root, &format!("{}/x", safe_rel_path(rel)?))?;
    Ok(r.strip_suffix("/x").unwrap_or("").to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    #[test]
    fn utc_dates() {
        assert_eq!(utc(0), "1970-01-01 00:00:00");
        assert_eq!(utc(951_782_400), "2000-02-29 00:00:00"); // leap day
        assert_eq!(utc(1_794_472_215), "2026-11-12 08:30:15");
    }

    #[test]
    fn resolves_like_a_chroot() {
        let t = std::env::temp_dir().join(format!("yone-resolve-{}", std::process::id()));
        let _ = fs::remove_dir_all(&t);
        fs::create_dir_all(t.join("usr/lib/sub")).unwrap();
        symlink("usr/lib", t.join("lib")).unwrap(); // relative, LFS style
        symlink("/usr/lib", t.join("lib64")).unwrap(); // absolute: inside the root
        symlink("../../..", t.join("usr/lib/up")).unwrap(); // tries to climb out
        symlink("loop", t.join("loop")).unwrap();
        let r = |p: &str| resolve_in_root(&t, p).unwrap();
        assert_eq!(r("lib/libfoo.so"), "usr/lib/libfoo.so");
        assert_eq!(r("lib64/sub/x"), "usr/lib/sub/x");
        assert_eq!(r("usr/lib/up/etc/passwd"), "etc/passwd"); // clamped at the root
        assert_eq!(r("lib"), "lib"); // the last component is never followed
        assert_eq!(r("new/dir/file"), "new/dir/file");
        assert!(resolve_in_root(&t, "loop/x").is_err());
        assert!(resolve_in_root(&t, "../x").is_err());
        assert_eq!(resolve_dir_in_root(&t, "lib").unwrap(), "usr/lib");
        assert_eq!(resolve_dir_in_root(&t, "usr/share").unwrap(), "usr/share");
        let _ = fs::remove_dir_all(&t);
    }
}
