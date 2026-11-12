//! `yone build`: turn a YONEBUILD recipe into a signed, reproducible `.yon`.
//!
//! ```text
//! name = zlib
//! version = 1.3.1
//! release = 1
//! desc = Compression library
//! url = https://zlib.net
//! license = Zlib
//! depends = glibc
//! source = https://zlib.net/zlib-1.3.1.tar.xz
//! sha256 = 38ef96b8dfe510d42707d9c781877914792541133e1870841463bfa73f883e32
//!
//! @build
//! cd zlib-$PKGVER
//! ./configure --prefix=/usr
//! make
//!
//! @package
//! cd zlib-$PKGVER
//! make DESTDIR="$PKGDIR" install
//! ```

use crate::archive::{self, INFO_NAME};
use crate::download::{fetch_all, Job};
use crate::error::{Context, Result};
use crate::pkginfo::{parse_kv, IndexEntry, PkgInfo};
use crate::tar::TarWriter;
use crate::ui::{human_bytes, Ui};
use crate::version::vercmp;
use crate::{bail, sha256, sign, util};
use std::fs::{self, File};
use std::io::BufWriter;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

pub struct Recipe {
    pub info: PkgInfo,
    pub pkgver: String,
    pub sources: Vec<String>,
    pub sha256: Vec<String>,
    pub makedepends: Vec<String>,
    pub build: String,
    pub package: String,
}

pub fn parse_recipe(text: &str) -> Result<Recipe> {
    let mut header = String::new();
    let mut build = String::new();
    let mut package = String::new();
    let mut section = 0;
    for line in text.lines() {
        match line.trim() {
            "@build" => section = 1,
            "@package" => section = 2,
            _ => {
                let target = match section {
                    0 => &mut header,
                    1 => &mut build,
                    _ => &mut package,
                };
                target.push_str(line);
                target.push('\n');
            }
        }
    }
    let kv = parse_kv(&header)?;
    let get = |k: &str| {
        kv.iter()
            .filter(|(x, _)| x == k)
            .map(|(_, v)| v.as_str())
            .collect::<Vec<_>>()
            .join(" ")
    };
    let pkgver = get("version");
    let release = match get("release") {
        r if r.is_empty() => "1".to_string(),
        r => r,
    };
    let mut kv2: Vec<(String, String)> =
        kv.iter().filter(|(k, _)| k != "version").cloned().collect();
    kv2.push(("version".into(), format!("{pkgver}-{release}")));
    let mut info = PkgInfo::from_kv(&kv2)?;
    if info.arch.is_empty() {
        info.arch = "x86_64".into();
    }
    let sources: Vec<String> = get("source")
        .split_whitespace()
        .map(str::to_string)
        .collect();
    let sums: Vec<String> = get("sha256")
        .split_whitespace()
        .map(str::to_string)
        .collect();
    if sources.len() != sums.len() {
        bail!("{} sources but {} sha256 sums", sources.len(), sums.len());
    }
    if package.trim().is_empty() {
        bail!("recipe has no @package section");
    }
    Ok(Recipe {
        info,
        pkgver,
        sources,
        sha256: sums,
        makedepends: get("makedepends")
            .split_whitespace()
            .map(str::to_string)
            .collect(),
        build,
        package,
    })
}

fn is_archive(name: &str) -> bool {
    [
        ".tar", ".tar.gz", ".tgz", ".tar.xz", ".txz", ".tar.zst", ".tar.bz2", ".tbz2",
    ]
    .iter()
    .any(|s| name.ends_with(s))
}

fn run_script(
    script: &str,
    cwd: &Path,
    r: &Recipe,
    srcdir: &Path,
    pkgdir: &Path,
    epoch: u64,
    stage: &str,
) -> Result<()> {
    if script.trim().is_empty() {
        return Ok(());
    }
    let jobs = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(2);
    let st = Command::new("bash")
        .arg("-c")
        .arg(format!("set -eo pipefail\n{script}"))
        .current_dir(cwd)
        .env("SRCDIR", srcdir)
        .env("PKGDIR", pkgdir)
        .env("PKGNAME", &r.info.name)
        .env("PKGVER", &r.pkgver)
        .env("SOURCE_DATE_EPOCH", epoch.to_string())
        .env("LC_ALL", "C")
        .env(
            "MAKEFLAGS",
            std::env::var("MAKEFLAGS").unwrap_or_else(|_| format!("-j{jobs}")),
        )
        .status()
        .map_err(|e| crate::err!("cannot run bash: {e}"))?;
    if !st.success() {
        bail!("{stage} step of {} failed ({})", r.info.name, st);
    }
    Ok(())
}

struct Node {
    rel: String,
    abs: PathBuf,
    meta: fs::Metadata,
}

fn walk(base: &Path, rel: &str, out: &mut Vec<Node>) -> Result<()> {
    let dir = if rel.is_empty() {
        base.to_path_buf()
    } else {
        base.join(rel)
    };
    let mut names: Vec<String> = fs::read_dir(&dir)?
        .map(|e| e.map(|e| e.file_name().to_string_lossy().into_owned()))
        .collect::<std::io::Result<_>>()?;
    names.sort();
    for n in names {
        let r = if rel.is_empty() {
            n
        } else {
            format!("{rel}/{n}")
        };
        util::safe_rel_path(&r)?;
        let abs = base.join(&r);
        let meta = fs::symlink_metadata(&abs)?;
        let is_dir = meta.is_dir();
        out.push(Node {
            rel: r.clone(),
            abs,
            meta,
        });
        if is_dir {
            walk(base, &r, out)?;
        }
    }
    Ok(())
}

/// Archive a staged tree into a `.yon` file.
pub fn write_package(
    info: &mut PkgInfo,
    pkgdir: &Path,
    out: &Path,
    compression: &str,
    mtime: u64,
) -> Result<()> {
    let mut nodes = vec![];
    walk(pkgdir, "", &mut nodes)?;
    if nodes.is_empty() {
        bail!("package directory is empty — did the @package step install anything into $PKGDIR?");
    }
    info.isize = nodes
        .iter()
        .filter(|n| n.meta.is_file())
        .map(|n| n.meta.len())
        .sum();
    let tarpath = util::suffixed(out, ".tar.tmp");
    {
        let mut tw = TarWriter::new(BufWriter::new(File::create(&tarpath)?), mtime);
        let meta = info.to_text();
        tw.add_file(INFO_NAME, 0o644, meta.len() as u64, &mut meta.as_bytes())?;
        for n in &nodes {
            let mode = n.meta.permissions().mode();
            let ft = n.meta.file_type();
            if ft.is_dir() {
                tw.add_dir(&n.rel, mode)?;
            } else if ft.is_symlink() {
                let t = fs::read_link(&n.abs)?;
                tw.add_symlink(&n.rel, &t.to_string_lossy())?;
            } else if ft.is_file() {
                let xattrs: Vec<(String, Vec<u8>)> = util::get_capability(&n.abs)
                    .ctx(|| format!("read capabilities of {}", n.rel))?
                    .map(|v| vec![(util::CAPABILITY_XATTR.to_string(), v)])
                    .unwrap_or_default();
                tw.add_file_xattrs(
                    &n.rel,
                    mode,
                    n.meta.len(),
                    &mut File::open(&n.abs)?,
                    &xattrs,
                )?;
            } else {
                bail!("{}: unsupported file type (device, fifo or socket)", n.rel);
            }
        }
        tw.finish()?;
    }
    let r = archive::compress(&tarpath, out, compression);
    let _ = fs::remove_file(&tarpath);
    r
}

pub struct BuildOpts<'a> {
    pub outdir: &'a Path,
    pub compression: &'a str,
    pub key: Option<&'a Path>,
    pub packager: String,
}

pub fn build(dir: &Path, o: &BuildOpts, ui: &Ui) -> Result<PathBuf> {
    // build scripts run inside $SRCDIR, so every path handed to them must be absolute
    let dir = &fs::canonicalize(dir).ctx(|| format!("recipe directory {}", dir.display()))?;
    fs::create_dir_all(o.outdir)?;
    let outdir = fs::canonicalize(o.outdir)?;
    let o = &BuildOpts {
        outdir: &outdir,
        compression: o.compression,
        key: o.key,
        packager: o.packager.clone(),
    };
    let recipe_path = dir.join("YONEBUILD");
    let text =
        fs::read_to_string(&recipe_path).ctx(|| format!("read {}", recipe_path.display()))?;
    let r = parse_recipe(&text).ctx(|| recipe_path.display().to_string())?;
    ui.header(&format!("Building {} {}", r.info.name, r.info.version));
    if !r.makedepends.is_empty() {
        ui.info(&ui.dim(&format!("makedepends: {}", r.makedepends.join(" "))));
    }
    let work = dir.join(".yone-work");
    let srcdir = work.join("src");
    let pkgdir = work.join("pkg");
    let _ = fs::remove_dir_all(&work);
    fs::create_dir_all(&srcdir)?;
    fs::create_dir_all(&pkgdir)?;
    let cache = dir.join(".yone-sources");

    // sources
    let mut local = vec![];
    let mut jobs = vec![];
    for s in &r.sources {
        let (fname, url) = match s.split_once("::") {
            Some((n, u)) => (n.to_string(), u.to_string()),
            None => (s.rsplit('/').next().unwrap_or(s).to_string(), s.clone()),
        };
        util::safe_rel_path(&fname)?;
        if url.contains("://") {
            let p = cache.join(&fname);
            if !p.exists() {
                jobs.push(Job {
                    label: fname.clone(),
                    urls: vec![url.clone()],
                    dest: p.clone(),
                    size: None,
                });
            }
            local.push((fname, p, true));
        } else {
            local.push((fname, dir.join(&url), false));
        }
    }
    if !jobs.is_empty() {
        fs::create_dir_all(&cache)?;
        fetch_all(jobs, 4, ui)?;
    }
    for ((fname, path, remote), want) in local.iter().zip(&r.sha256) {
        if want == "SKIP" {
            if *remote {
                bail!("{fname}: SKIP is not allowed for downloaded sources");
            }
        } else {
            let got = sha256::file_hex(path).ctx(|| format!("source {}", path.display()))?;
            if &got != want {
                bail!("{fname}: sha256 mismatch\n  expected {want}\n  got      {got}");
            }
        }
        if is_archive(fname) {
            let st = Command::new("tar")
                .arg("-xf")
                .arg(path)
                .arg("-C")
                .arg(&srcdir)
                .arg("--no-same-owner")
                .status()?;
            if !st.success() {
                bail!("cannot extract {fname}");
            }
        } else {
            fs::copy(path, srcdir.join(fname))?;
        }
    }
    ui.info(&format!("{} source(s) verified", local.len()));

    let epoch = std::env::var("SOURCE_DATE_EPOCH")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    run_script(&r.build, &srcdir, &r, &srcdir, &pkgdir, epoch, "build")?;
    run_script(&r.package, &srcdir, &r, &srcdir, &pkgdir, epoch, "package")?;

    let mut info = r.info.clone();
    info.builddate = epoch;
    info.packager = o.packager.clone();
    fs::create_dir_all(o.outdir)?;
    let out = o
        .outdir
        .join(format!("{}-{}-{}.yon", info.name, info.version, info.arch));
    write_package(&mut info, &pkgdir, &out, o.compression, epoch)?;
    let size = fs::metadata(&out)?.len();
    if let Some(k) = o.key {
        sign::sign(&out, k)?;
    }
    let _ = fs::remove_dir_all(&work);
    ui.success(&format!(
        "{} ({}, installed {}){}",
        out.display(),
        human_bytes(size),
        human_bytes(info.isize),
        if o.key.is_some() { ", signed" } else { "" }
    ));
    Ok(out)
}

/// `yone repo-index`: (re)generate and sign `<name>.index` for a directory of packages.
pub fn repo_index(dir: &Path, name: &str, key: Option<&Path>, ui: &Ui) -> Result<()> {
    if !crate::pkginfo::valid_name(name) {
        bail!("invalid repository name '{name}'");
    }
    let mut files: Vec<PathBuf> = fs::read_dir(dir)?
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.extension().map(|x| x == "yon").unwrap_or(false))
        .collect();
    files.sort();
    let mut entries: Vec<IndexEntry> = vec![];
    for f in &files {
        let info = archive::read_info(f)?;
        let filename = f.file_name().unwrap().to_string_lossy().into_owned();
        let e = IndexEntry {
            csize: fs::metadata(f)?.len(),
            sha256: sha256::file_hex(f)?,
            filename,
            info,
            repo: name.to_string(),
        };
        if let Some(pos) = entries.iter().position(|x| x.info.name == e.info.name) {
            if vercmp(&e.info.version, &entries[pos].info.version) == std::cmp::Ordering::Greater {
                entries[pos] = e;
            }
        } else {
            entries.push(e);
        }
    }
    entries.sort_by(|a, b| a.info.name.cmp(&b.info.name));
    let idx = dir.join(format!("{name}.index"));
    let generated = std::env::var("SOURCE_DATE_EPOCH")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or_else(util::now);
    util::write_atomic(
        &idx,
        crate::pkginfo::index_text(&entries, generated).as_bytes(),
    )?;
    if let Some(k) = key {
        sign::sign(&idx, k)?;
    }
    ui.success(&format!(
        "{} ({} packages{})",
        idx.display(),
        entries.len(),
        if key.is_some() {
            ", signed"
        } else {
            ", UNSIGNED"
        }
    ));
    Ok(())
}
