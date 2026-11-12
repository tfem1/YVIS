//! `/etc/yone/yone.conf`
//!
//! ```text
//! [options]
//! arch = x86_64
//! channel = stable          # stable | testing | dev
//! parallel = 4
//! siglevel = required       # required | optional | never
//! compression = zstd        # used by `yone build`
//!
//! [core]
//! server = https://repo.yvis.org/$channel/$repo/$arch
//! ```

use crate::bail;
use crate::error::{Context, Result};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum SigLevel {
    Required,
    Optional,
    Never,
}

#[derive(Debug, Clone)]
pub struct Repo {
    pub name: String,
    pub servers: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct Config {
    pub root: PathBuf,
    pub dbpath: PathBuf,
    pub cachedir: PathBuf,
    pub keydir: PathBuf,
    pub arch: String,
    pub channel: String,
    pub parallel: usize,
    pub siglevel: SigLevel,
    pub compression: String,
    pub repos: Vec<Repo>,
}

impl Config {
    pub fn load(root: &Path, file: Option<&Path>) -> Result<Config> {
        let mut c = Config {
            root: root.to_path_buf(),
            dbpath: root.join("var/lib/yone"),
            cachedir: root.join("var/cache/yone/pkg"),
            keydir: root.join("etc/yone/keys"),
            arch: "x86_64".into(),
            channel: "stable".into(),
            parallel: 4,
            siglevel: SigLevel::Required,
            compression: "zstd".into(),
            repos: vec![],
        };
        let path = file
            .map(Path::to_path_buf)
            .unwrap_or_else(|| root.join("etc/yone/yone.conf"));
        let text = match fs::read_to_string(&path) {
            Ok(t) => t,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound && file.is_none() => return Ok(c),
            Err(e) => bail!("cannot read {}: {}", path.display(), e),
        };
        let mut section = String::new();
        let mut raw_servers: Vec<(String, String)> = vec![];
        for (n, line) in text.lines().enumerate() {
            let l = line.split('#').next().unwrap_or("").trim();
            if l.is_empty() {
                continue;
            }
            if l.starts_with('[') && l.ends_with(']') {
                section = l[1..l.len() - 1].trim().to_string();
                if section != "options" {
                    if !crate::pkginfo::valid_name(&section) {
                        bail!(
                            "{}:{}: invalid repository name '{}'",
                            path.display(),
                            n + 1,
                            section
                        );
                    }
                    c.repos.push(Repo {
                        name: section.clone(),
                        servers: vec![],
                    });
                }
                continue;
            }
            let (k, v) = l
                .split_once('=')
                .ok_or_else(|| crate::err!("{}:{}: expected key = value", path.display(), n + 1))?;
            let (k, v) = (k.trim(), v.trim().to_string());
            match (section.as_str(), k) {
                ("options", "arch") => c.arch = v,
                ("options", "channel") => c.channel = v,
                ("options", "parallel") => {
                    c.parallel = v
                        .parse()
                        .ctx(|| format!("{}:{}: parallel", path.display(), n + 1))?
                }
                ("options", "compression") => c.compression = v,
                ("options", "siglevel") => {
                    c.siglevel = match v.as_str() {
                        "required" => SigLevel::Required,
                        "optional" => SigLevel::Optional,
                        "never" => SigLevel::Never,
                        _ => bail!(
                            "{}:{}: siglevel must be required|optional|never",
                            path.display(),
                            n + 1
                        ),
                    }
                }
                ("options", "cachedir") => c.cachedir = root.join(v.trim_start_matches('/')),
                ("options", _) => bail!("{}:{}: unknown option '{}'", path.display(), n + 1, k),
                ("", _) => bail!("{}:{}: option outside a section", path.display(), n + 1),
                (_, "server") => raw_servers.push((section.clone(), v)),
                (s, k) => bail!(
                    "{}:{}: unknown key '{}' in [{}]",
                    path.display(),
                    n + 1,
                    k,
                    s
                ),
            }
        }
        for (repo, url) in raw_servers {
            let url = url
                .replace("$repo", &repo)
                .replace("$arch", &c.arch)
                .replace("$channel", &c.channel);
            if let Some(r) = c.repos.iter_mut().find(|r| r.name == repo) {
                r.servers.push(url.trim_end_matches('/').to_string());
            }
        }
        c.parallel = c.parallel.clamp(1, 32);
        Ok(c)
    }

    pub fn is_live_root(&self) -> bool {
        self.root == Path::new("/")
    }
}
