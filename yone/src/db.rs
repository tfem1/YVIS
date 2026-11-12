//! Local database of installed packages: `/var/lib/yone/local/<name>/{info,files}`.

use crate::error::{Context, Result};
use crate::pkginfo::{parse_kv, PkgInfo};
use crate::{bail, util};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
pub struct FileRec {
    /// 'f' file, 'd' directory, 'l' symlink
    pub kind: char,
    pub mode: u32,
    /// sha256 for files, target for symlinks, '-' for directories
    pub data: String,
    pub path: String,
}

#[derive(Debug, Clone)]
pub struct Installed {
    pub info: PkgInfo,
    pub explicit: bool,
    pub installdate: u64,
}

pub struct LocalDb {
    dir: PathBuf,
}

impl LocalDb {
    pub fn open(dbpath: &Path) -> LocalDb {
        LocalDb {
            dir: dbpath.join("local"),
        }
    }

    fn pkgdir(&self, name: &str) -> Result<PathBuf> {
        if !crate::pkginfo::valid_name(name) {
            bail!("invalid package name '{name}'");
        }
        Ok(self.dir.join(name))
    }

    pub fn list(&self) -> Result<Vec<Installed>> {
        let mut out = vec![];
        let rd = match fs::read_dir(&self.dir) {
            Ok(rd) => rd,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(out),
            Err(e) => return Err(e.into()),
        };
        for e in rd {
            let name = e?.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') {
                continue;
            }
            if let Some(i) = self.get(&name)? {
                out.push(i);
            }
        }
        out.sort_by(|a, b| a.info.name.cmp(&b.info.name));
        Ok(out)
    }

    pub fn get(&self, name: &str) -> Result<Option<Installed>> {
        let p = self.pkgdir(name)?.join("info");
        let text = match fs::read_to_string(&p) {
            Ok(t) => t,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(e.into()),
        };
        let kv = parse_kv(&text).ctx(|| p.display().to_string())?;
        let info = PkgInfo::from_kv(&kv).ctx(|| p.display().to_string())?;
        let get = |k: &str| {
            kv.iter()
                .find(|(x, _)| x == k)
                .map(|(_, v)| v.as_str())
                .unwrap_or("")
        };
        Ok(Some(Installed {
            info,
            explicit: get("reason") != "dependency",
            installdate: get("installdate").parse().unwrap_or(0),
        }))
    }

    pub fn files(&self, name: &str) -> Result<Vec<FileRec>> {
        let p = self.pkgdir(name)?.join("files");
        let text = fs::read_to_string(&p).ctx(|| format!("read {}", p.display()))?;
        let mut out = vec![];
        for (n, line) in text.lines().enumerate() {
            let mut it = line.splitn(4, '\t');
            let (Some(k), Some(m), Some(d), Some(path)) =
                (it.next(), it.next(), it.next(), it.next())
            else {
                bail!("{}:{}: corrupt file record", p.display(), n + 1);
            };
            out.push(FileRec {
                kind: k.chars().next().unwrap_or('?'),
                mode: u32::from_str_radix(m, 8).unwrap_or(0),
                data: d.to_string(),
                path: path.to_string(),
            });
        }
        Ok(out)
    }

    fn staged(&self) -> PathBuf {
        self.dir.join(".staged")
    }

    /// Prepare the new database entry of a package without making it visible.
    /// `apply_staged` publishes every staged change; `discard_staged` drops them.
    pub fn stage(&self, inst: &Installed, files: &[FileRec]) -> Result<()> {
        let dir = self
            .staged()
            .join(self.pkgdir(&inst.info.name)?.file_name().unwrap());
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir)?;
        let mut info = inst.info.to_text();
        info.push_str(&format!(
            "reason = {}\ninstalldate = {}\n",
            if inst.explicit {
                "explicit"
            } else {
                "dependency"
            },
            inst.installdate
        ));
        util::write_atomic(&dir.join("info"), info.as_bytes())?;
        let mut ft = String::new();
        for f in files {
            ft.push_str(&format!(
                "{}\t{:o}\t{}\t{}\n",
                f.kind, f.mode, f.data, f.path
            ));
        }
        util::write_atomic(&dir.join("files"), ft.as_bytes())?;
        Ok(())
    }

    /// Stage the removal of a package from the database.
    pub fn stage_remove(&self, name: &str) -> Result<()> {
        self.pkgdir(name)?;
        util::write_atomic(&self.staged().join(format!("{name}.remove")), b"")
    }

    /// Publish staged changes. Idempotent, so `yone recover` can finish a
    /// transaction that crashed half-way through this function.
    pub fn apply_staged(&self) -> Result<()> {
        let st = self.staged();
        let mut names: Vec<String> = match fs::read_dir(&st) {
            Ok(rd) => rd
                .filter_map(|e| e.ok())
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .collect(),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(e) => return Err(e.into()),
        };
        names.sort();
        for n in names {
            if let Some(pkg) = n.strip_suffix(".remove") {
                util::ignore_missing(fs::remove_dir_all(self.pkgdir(pkg)?))?;
                fs::remove_file(st.join(&n))?;
            } else {
                let dest = self.pkgdir(&n)?;
                util::ignore_missing(fs::remove_dir_all(&dest))?;
                fs::rename(st.join(&n), &dest).ctx(|| format!("publish {}", dest.display()))?;
            }
        }
        fs::remove_dir(&st)?;
        Ok(())
    }

    pub fn discard_staged(&self) -> Result<()> {
        util::ignore_missing(fs::remove_dir_all(self.staged()))?;
        Ok(())
    }

    pub fn write(&self, inst: &Installed, files: &[FileRec]) -> Result<()> {
        self.stage(inst, files)?;
        self.apply_staged()
    }

    pub fn set_reason(&self, name: &str, explicit: bool) -> Result<()> {
        let Some(mut inst) = self.get(name)? else {
            bail!("{name} is not installed")
        };
        inst.explicit = explicit;
        let files = self.files(name)?;
        self.write(&inst, &files)
    }

    /// path -> owning package, for files and symlinks (directories may be shared).
    pub fn owners(&self) -> Result<HashMap<String, String>> {
        let mut m = HashMap::new();
        for i in self.list()? {
            for f in self.files(&i.info.name)? {
                if f.kind != 'd' {
                    m.insert(f.path, i.info.name.clone());
                }
            }
        }
        Ok(m)
    }
}
