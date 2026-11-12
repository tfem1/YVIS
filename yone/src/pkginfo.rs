//! Package metadata (`.YONEINFO`), repository index records and the shared
//! `key = value` text format used for every Yone metadata file.

use crate::error::Result;
use crate::{bail, sha256};

pub fn valid_name(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 128
        && s.as_bytes()[0].is_ascii_alphanumeric()
        && s.bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b"@._+-".contains(&b))
}

pub fn valid_version(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 128
        && s.as_bytes()[0].is_ascii_alphanumeric()
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._+~:-".contains(&b))
}

/// Parse `key = value` lines; `#` starts a comment line. Order is kept and
/// keys may repeat.
pub fn parse_kv(text: &str) -> Result<Vec<(String, String)>> {
    let mut out = vec![];
    for (n, line) in text.lines().enumerate() {
        let l = line.trim();
        if l.is_empty() || l.starts_with('#') {
            continue;
        }
        let Some((k, v)) = l.split_once('=') else {
            bail!("line {}: expected 'key = value', got '{}'", n + 1, l);
        };
        out.push((k.trim().to_string(), v.trim().to_string()));
    }
    Ok(out)
}

fn words(v: &str) -> Vec<String> {
    v.split_whitespace().map(str::to_string).collect()
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct PkgInfo {
    pub name: String,
    pub version: String,
    pub desc: String,
    pub url: String,
    pub license: String,
    pub arch: String,
    pub packager: String,
    pub builddate: u64,
    pub isize: u64,
    pub depends: Vec<String>,
    pub provides: Vec<String>,
    pub conflicts: Vec<String>,
    pub backup: Vec<String>,
}

impl PkgInfo {
    pub fn from_kv(kv: &[(String, String)]) -> Result<PkgInfo> {
        let mut p = PkgInfo::default();
        for (k, v) in kv {
            match k.as_str() {
                "name" => p.name = v.clone(),
                "version" => p.version = v.clone(),
                "desc" => p.desc = v.clone(),
                "url" => p.url = v.clone(),
                "license" => p.license = v.clone(),
                "arch" => p.arch = v.clone(),
                "packager" => p.packager = v.clone(),
                "builddate" => p.builddate = v.parse().unwrap_or(0),
                "isize" => p.isize = v.parse().unwrap_or(0),
                "depends" => p.depends.extend(words(v)),
                "provides" => p.provides.extend(words(v)),
                "conflicts" => p.conflicts.extend(words(v)),
                "backup" => p.backup.extend(words(v)),
                _ => {}
            }
        }
        p.validate()?;
        Ok(p)
    }

    pub fn parse(text: &str) -> Result<PkgInfo> {
        PkgInfo::from_kv(&parse_kv(text)?)
    }

    pub fn validate(&self) -> Result<()> {
        if !valid_name(&self.name) {
            bail!("invalid package name '{}'", self.name);
        }
        if !valid_version(&self.version) || !self.version.contains('-') {
            bail!(
                "invalid version '{}' for {} (expected ver-rel)",
                self.version,
                self.name
            );
        }
        for d in self.depends.iter().chain(&self.conflicts) {
            crate::version::Dep::parse(d)?;
        }
        for b in &self.backup {
            crate::util::safe_rel_path(b)?;
        }
        Ok(())
    }

    pub fn to_text(&self) -> String {
        let mut s = String::new();
        let mut kv = |k: &str, v: &str| {
            if !v.is_empty() {
                s.push_str(&format!("{k} = {v}\n"));
            }
        };
        kv("name", &self.name);
        kv("version", &self.version);
        kv("desc", &self.desc.replace('\n', " "));
        kv("url", &self.url);
        kv("license", &self.license);
        kv("arch", &self.arch);
        kv("packager", &self.packager);
        kv("builddate", &self.builddate.to_string());
        kv("isize", &self.isize.to_string());
        kv("depends", &self.depends.join(" "));
        kv("provides", &self.provides.join(" "));
        kv("conflicts", &self.conflicts.join(" "));
        kv("backup", &self.backup.join(" "));
        s
    }
}

#[derive(Debug, Clone)]
pub struct IndexEntry {
    pub info: PkgInfo,
    pub filename: String,
    pub csize: u64,
    pub sha256: String,
    pub repo: String,
}

fn valid_filename(s: &str) -> bool {
    !s.is_empty()
        && !s.starts_with('.')
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"@._+-:~".contains(&b))
}

/// Index: an optional header record (`generated = <unix time>`), then
/// package records, all separated by blank lines.
pub fn parse_index(text: &str, repo: &str) -> Result<Vec<IndexEntry>> {
    let mut out = vec![];
    for block in text.split("\n\n") {
        let kv = parse_kv(block)?;
        if kv.is_empty() || is_header(&kv) {
            continue;
        }
        let info = PkgInfo::from_kv(&kv)?;
        let get = |key: &str| {
            kv.iter()
                .find(|(k, _)| k == key)
                .map(|(_, v)| v.clone())
                .unwrap_or_default()
        };
        let filename = get("filename");
        let sha = get("sha256");
        if !valid_filename(&filename) {
            bail!("index {repo}: invalid filename for {}", info.name);
        }
        if !sha256::is_hex64(&sha) {
            bail!("index {repo}: invalid sha256 for {}", info.name);
        }
        out.push(IndexEntry {
            csize: get("csize").parse().unwrap_or(0),
            filename,
            sha256: sha,
            info,
            repo: repo.to_string(),
        });
    }
    Ok(out)
}

fn is_header(kv: &[(String, String)]) -> bool {
    kv.iter().all(|(k, _)| k == "generated")
}

/// When the repository index was generated (0 for indexes without a header).
/// The value is covered by the index signature, so a mirror cannot fake it.
pub fn index_generated(text: &str) -> u64 {
    text.split("\n\n")
        .filter_map(|b| parse_kv(b).ok())
        .find(|kv| !kv.is_empty() && is_header(kv))
        .and_then(|kv| kv[0].1.parse().ok())
        .unwrap_or(0)
}

pub fn index_text(entries: &[IndexEntry], generated: u64) -> String {
    let mut s = format!("# Yone repository index v1\ngenerated = {generated}\n\n");
    for e in entries {
        s.push_str(&e.info.to_text());
        s.push_str(&format!(
            "filename = {}\ncsize = {}\nsha256 = {}\n\n",
            e.filename, e.csize, e.sha256
        ));
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_index() {
        let info = PkgInfo {
            name: "zlib".into(),
            version: "1.3.1-1".into(),
            desc: "compression".into(),
            arch: "x86_64".into(),
            depends: vec!["glibc>=2.40".into()],
            backup: vec!["etc/zlib.conf".into()],
            ..Default::default()
        };
        let e = IndexEntry {
            info: info.clone(),
            filename: "zlib-1.3.1-1-x86_64.yon".into(),
            csize: 42,
            sha256: "a".repeat(64),
            repo: "core".into(),
        };
        let txt = index_text(&[e.clone(), e], 1_700_000_000);
        assert_eq!(index_generated(&txt), 1_700_000_000);
        assert_eq!(index_generated("name = a\nversion = 1-1\n"), 0);
        let back = parse_index(&txt, "core").unwrap();
        assert_eq!(back.len(), 2);
        assert_eq!(back[0].info, info);
        assert_eq!(back[0].csize, 42);
    }

    #[test]
    fn rejects_bad_metadata() {
        assert!(PkgInfo::parse("name = ../evil\nversion = 1-1").is_err());
        assert!(PkgInfo::parse("name = ok\nversion = 1").is_err());
        assert!(PkgInfo::parse("name = ok\nversion = 1-1\nbackup = /etc/abs").is_err());
        let bad = "name = ok\nversion = 1-1\nfilename = ../../x\nsha256 = 00\n";
        assert!(parse_index(bad, "core").is_err());
    }
}
