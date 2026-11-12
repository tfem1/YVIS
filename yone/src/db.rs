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

    pub fn write(&self, inst: &Installed, files: &[FileRec]) -> Result<()> {
        let dir = self.pkgdir(&inst.info.name)?;
        let tmp = self.dir.join(format!(".{}.new", inst.info.name));
        let old = self.dir.join(format!(".{}.old", inst.info.name));
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(&tmp)?;
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
        util::write_atomic(&tmp.join("info"), info.as_bytes())?;
        let mut ft = String::new();
        for f in files {
            ft.push_str(&format!(
                "{}\t{:o}\t{}\t{}\n",
                f.kind, f.mode, f.data, f.path
            ));
        }
        util::write_atomic(&tmp.join("files"), ft.as_bytes())?;
        let _ = fs::remove_dir_all(&old);
        if dir.exists() {
            fs::rename(&dir, &old)?;
        }
        fs::rename(&tmp, &dir)?;
        let _ = fs::remove_dir_all(&old);
        Ok(())
    }

    pub fn set_reason(&self, name: &str, explicit: bool) -> Result<()> {
        let Some(mut inst) = self.get(name)? else {
            bail!("{name} is not installed")
        };
        inst.explicit = explicit;
        let files = self.files(name)?;
        self.write(&inst, &files)
    }

    pub fn remove(&self, name: &str) -> Result<()> {
        let dir = self.pkgdir(name)?;
        util::ignore_missing(fs::remove_dir_all(&dir))?;
        Ok(())
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

    /// Directories referenced by any installed package.
    pub fn owned_dirs(&self) -> Result<std::collections::HashSet<String>> {
        let mut s = std::collections::HashSet::new();
        for i in self.list()? {
            for f in self.files(&i.info.name)? {
                if f.kind == 'd' {
                    s.insert(f.path);
                }
            }
        }
        Ok(s)
    }
}
