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
