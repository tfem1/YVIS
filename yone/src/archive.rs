//! `.yon` package files: a tar stream (first entry `.YONEINFO`) compressed
//! with zstd or xz. Decompression streams through the system tools.

use crate::error::{Context, Result};
use crate::pkginfo::PkgInfo;
use crate::tar::{Entry, Kind, TarReader};
use crate::{bail, util};
use std::fs::File;
use std::io::{self, Read};
use std::path::Path;
use std::process::{Child, ChildStdout, Command, Stdio};

pub const INFO_NAME: &str = ".YONEINFO";

pub struct Decompressor {
    child: Child,
    out: ChildStdout,
    tool: &'static str,
}

impl Read for Decompressor {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        self.out.read(buf)
    }
}

impl Decompressor {
    pub fn open(path: &Path) -> Result<Decompressor> {
        let mut magic = [0u8; 6];
        let n = File::open(path)
            .ctx(|| format!("open {}", path.display()))?
            .read(&mut magic)?;
        let tool = if n >= 6 && magic == [0xFD, b'7', b'z', b'X', b'Z', 0] {
            "xz"
        } else if n >= 4 && magic[..4] == [0x28, 0xB5, 0x2F, 0xFD] {
            "zstd"
        } else if n >= 2 && magic[..2] == [0x1F, 0x8B] {
            "gzip"
        } else {
            bail!("{}: unknown compression format", path.display());
        };
        let mut child = Command::new(tool)
            .arg("-dc")
            .arg(path)
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| crate::err!("cannot run {tool}: {e}"))?;
        let out = child.stdout.take().unwrap();
        Ok(Decompressor { child, out, tool })
    }

    /// Wait for the decompressor and make sure it exited cleanly.
    pub fn finish(mut self) -> Result<()> {
        let st = self.child.wait()?;
        if !st.success() {
            bail!("{} reported a corrupt stream", self.tool);
        }
        Ok(())
    }
}

impl Drop for Decompressor {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

pub fn compress(src: &Path, dst: &Path, algo: &str) -> Result<()> {
    let (tool, args): (&str, Vec<&str>) = match algo {
        "zstd" => ("zstd", vec!["-q", "-19", "-T0", "-c"]),
        "xz" => ("xz", vec!["-6", "-T0", "-c"]),
        other => bail!("unsupported compression '{other}' (use zstd or xz)"),
    };
    let input = File::open(src)?;
    let output = File::create(dst).ctx(|| format!("create {}", dst.display()))?;
    let st = Command::new(tool)
        .args(&args)
        .stdin(input)
        .stdout(output)
        .status()
        .map_err(|e| crate::err!("cannot run {tool}: {e} (install it or set compression = xz)"))?;
    if !st.success() {
        bail!("{tool} failed");
    }
    Ok(())
}

pub fn open_tar(path: &Path) -> Result<TarReader<Decompressor>> {
    Ok(TarReader::new(Decompressor::open(path)?))
}

fn read_info_entry<R: Read>(tr: &mut TarReader<R>, path: &Path) -> Result<PkgInfo> {
    let e = tr.next_entry().ctx(|| format!("read {}", path.display()))?;
    match e {
        Some(e) if e.path == INFO_NAME && e.kind == Kind::File && e.size < 1 << 20 => {
            let mut v = vec![];
            tr.copy_data(&mut v)?;
            PkgInfo::parse(&String::from_utf8_lossy(&v))
                .ctx(|| format!("{}: {}", path.display(), INFO_NAME))
        }
        _ => bail!(
            "{}: not a Yone package (missing {})",
            path.display(),
            INFO_NAME
        ),
    }
}

pub fn read_info(path: &Path) -> Result<PkgInfo> {
    let mut tr = open_tar(path)?;
    read_info_entry(&mut tr, path)
}

pub struct Listing {
    pub info: PkgInfo,
    pub entries: Vec<Entry>,
}

/// Read metadata and the full, validated file list.
pub fn list(path: &Path) -> Result<Listing> {
    let mut tr = open_tar(path)?;
    let info = read_info_entry(&mut tr, path)?;
    let mut entries = vec![];
    while let Some(mut e) = tr.next_entry().ctx(|| format!("read {}", path.display()))? {
        e.path = util::safe_rel_path(&e.path).ctx(|| path.display().to_string())?;
        if e.path.starts_with(".YONE") {
            bail!("{}: reserved path {}", path.display(), e.path);
        }
        if let Kind::Hardlink(t) = &e.kind {
            e.kind = Kind::Hardlink(util::safe_rel_path(t)?);
        }
        entries.push(e);
    }
    tr.into_inner()
        .finish()
        .ctx(|| path.display().to_string())?;
    Ok(Listing { info, entries })
}
