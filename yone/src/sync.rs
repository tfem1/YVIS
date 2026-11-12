//! Repository indexes (`/var/lib/yone/sync/<repo>.index`) and `yone update`.

use crate::config::{Config, SigLevel};
use crate::db::LocalDb;
use crate::download::{fetch_all, Job};
use crate::error::{Context, Result};
use crate::pkginfo::{index_generated, parse_index, IndexEntry};
use crate::ui::Ui;
use crate::version::vercmp;
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
        // Refuse to go back in time: a mirror replaying an old (validly
        // signed) index could otherwise hide security updates.
        if checked.is_some() {
            let trusted = syncdir.join(format!("{}.index", r.name));
            let have = fs::read_to_string(&trusted)
                .map(|t| index_generated(&t))
                .unwrap_or(0);
            let got = index_generated(&text);
            if got < have {
                let _ = fs::remove_dir_all(&stage);
                bail!(
                    "repository '{}': the server sent an index older than the one already \
                     trusted (generated {} < {}); refusing it (stale mirror or replay attack)",
                    r.name,
                    got,
                    have
                );
            }
        }
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

/// Removes a private scratch directory when dropped.
struct TempDir(std::path::PathBuf);

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn private_dir(tag: &str) -> Result<TempDir> {
    use std::io::Read;
    use std::os::unix::fs::DirBuilderExt;
    let mut rnd = [0u8; 12];
    fs::File::open("/dev/urandom")?.read_exact(&mut rnd)?;
    let hex: String = rnd.iter().map(|b| format!("{b:02x}")).collect();
    let p = std::env::temp_dir().join(format!("yone-{tag}-{hex}"));
    fs::DirBuilder::new()
        .mode(0o700)
        .create(&p)
        .ctx(|| format!("create {}", p.display()))?;
    Ok(TempDir(p))
}

/// `yone check-updates`: list the packages `yone upgrade` would update, as
/// `name old -> new` lines, like Arch's checkupdates. Unless `offline`, the
/// indexes are refreshed into a private copy of the sync database: it needs
/// no root, takes no lock and never changes the system's indexes, so a
/// desktop widget can call it on a timer.
pub fn check_updates(cfg: &Config, ui: &Ui, offline: bool) -> Result<Vec<String>> {
    let _tmp;
    let sync = if offline {
        SyncDb::load(cfg, ui)?
    } else {
        let tmp = private_dir("check")?;
        let mut copy = cfg.clone();
        copy.dbpath = tmp.0.clone();
        let syncdir = copy.dbpath.join("sync");
        fs::create_dir_all(&syncdir)?;
        // start from the trusted indexes so the anti-rollback check still applies
        if let Ok(rd) = fs::read_dir(cfg.dbpath.join("sync")) {
            for e in rd.flatten() {
                if e.path().is_file() {
                    fs::copy(e.path(), syncdir.join(e.file_name()))?;
                }
            }
        }
        update(&copy, ui)?;
        let s = SyncDb::load(&copy, ui)?;
        _tmp = tmp;
        s
    };
    let mut out = vec![];
    for i in LocalDb::open(&cfg.dbpath).list()? {
        if cfg.hold.contains(&i.info.name) {
            continue;
        }
        if let Some(e) = sync.find(&i.info.name) {
            if vercmp(&e.info.version, &i.info.version) == std::cmp::Ordering::Greater {
                out.push(format!(
                    "{} {} -> {}",
                    i.info.name, i.info.version, e.info.version
                ));
            }
        }
    }
    Ok(out)
}
