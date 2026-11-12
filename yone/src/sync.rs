//! Repository indexes (`/var/lib/yone/sync/<repo>.index`) and `yone update`.

use crate::config::{Config, SigLevel};
use crate::download::{fetch_all, Job};
use crate::error::{Context, Result};
use crate::pkginfo::{parse_index, IndexEntry};
use crate::ui::Ui;
use crate::version::Dep;
use crate::{bail, sign, util};
use std::fs;

pub struct SyncDb {
    pub entries: Vec<IndexEntry>,
}

impl SyncDb {
    pub fn load(cfg: &Config, ui: &Ui) -> Result<SyncDb> {
        let mut entries = vec![];
        for r in &cfg.repos {
            let p = cfg.dbpath.join("sync").join(format!("{}.index", r.name));
            match fs::read_to_string(&p) {
                Ok(t) => entries.extend(parse_index(&t, &r.name).ctx(|| p.display().to_string())?),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => ui.warn(&format!(
                    "repository '{}' has no local index; run 'yone update'",
                    r.name
                )),
                Err(e) => return Err(e.into()),
            }
        }
        Ok(SyncDb { entries })
    }

    /// First repository (in configuration order) that has the package wins.
    pub fn find(&self, name: &str) -> Option<&IndexEntry> {
        self.entries.iter().find(|e| e.info.name == name)
    }

    pub fn find_satisfier(&self, dep: &Dep) -> Option<&IndexEntry> {
        self.entries
            .iter()
            .find(|e| e.info.name == dep.name && dep.satisfied_by(&e.info))
            .or_else(|| self.entries.iter().find(|e| dep.satisfied_by(&e.info)))
    }

    pub fn urls(&self, cfg: &Config, e: &IndexEntry) -> Vec<String> {
        cfg.repos
            .iter()
            .filter(|r| r.name == e.repo)
            .flat_map(|r| r.servers.iter().map(|s| format!("{}/{}", s, e.filename)))
            .collect()
    }
}

/// `yone update`: fetch every repository index and its signature, verify,
/// then atomically replace the local copy. A bad repository never leaves a
/// half-written index behind.
pub fn update(cfg: &Config, ui: &Ui) -> Result<()> {
    if cfg.repos.is_empty() {
        bail!("no repositories configured in /etc/yone/yone.conf");
    }
    let syncdir = cfg.dbpath.join("sync");
    let stage = syncdir.join(".incoming");
    let _ = fs::remove_dir_all(&stage);
    fs::create_dir_all(&stage)?;
    ui.header("Synchronising repository indexes");
    let mut jobs = vec![];
    for r in &cfg.repos {
        if r.servers.is_empty() {
            bail!("repository '{}' has no server", r.name);
        }
        let file = format!("{}.index", r.name);
        jobs.push(Job {
            label: file.clone(),
            urls: r.servers.iter().map(|s| format!("{s}/{file}")).collect(),
            dest: stage.join(&file),
            size: None,
        });
    }
    fetch_all(jobs, cfg.parallel, ui)?;
    if cfg.siglevel != SigLevel::Never {
        let mut sigjobs = vec![];
        for r in &cfg.repos {
            let file = format!("{}.index.sig", r.name);
            sigjobs.push(Job {
                label: file.clone(),
                urls: r.servers.iter().map(|s| format!("{s}/{file}")).collect(),
                dest: stage.join(&file),
                size: None,
            });
        }
        if let Err(e) = fetch_all(sigjobs, cfg.parallel, ui) {
            if cfg.siglevel == SigLevel::Required {
                let _ = fs::remove_dir_all(&stage);
                return Err(e);
            }
        }
    }
    for r in &cfg.repos {
        let idx = stage.join(format!("{}.index", r.name));
        let sig = stage.join(format!("{}.index.sig", r.name));
        let checked = match cfg.siglevel {
            SigLevel::Never => None,
            SigLevel::Optional if !sig.exists() => None,
            _ => Some(sign::verify(&idx, &sig, &cfg.keydir).map_err(|e| {
                let _ = fs::remove_dir_all(&stage);
                crate::err!("repository '{}': {}", r.name, e)
            })?),
        };
        let text = fs::read_to_string(&idx)?;
        let n = parse_index(&text, &r.name)
            .ctx(|| format!("repository '{}'", r.name))?
            .len();
        match checked {
            Some(k) => ui.info(&format!(
                "{:<12} {} packages, signature ok ({})",
                r.name, n, k
            )),
            None => ui.warn(&format!(
                "{} ({} packages) is NOT signature-checked",
                r.name, n
            )),
        }
    }
    for r in &cfg.repos {
        for ext in ["index", "index.sig"] {
            let f = format!("{}.{}", r.name, ext);
            let src = stage.join(&f);
            if src.exists() {
                fs::rename(&src, syncdir.join(&f))?;
            } else {
                util::ignore_missing(fs::remove_file(syncdir.join(&f)))?;
            }
        }
    }
    let _ = fs::remove_dir_all(&stage);
    ui.success("indexes up to date");
    Ok(())
}
