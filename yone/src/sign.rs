//! Ed25519 signatures through OpenSSL (part of the LFS base system).
//!
//! A signature covers a short statement binding the file name to its
//! SHA-256: `yone-signature-v1\n<sha256>  <filename>\n`. This keeps
//! signing/verification constant-memory for multi-GB packages and prevents
//! a valid signature from being reused for a differently named file.

use crate::error::{Context, Result};
use crate::{bail, sha256};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

fn statement(file: &Path) -> Result<Vec<u8>> {
    let sha = sha256::file_hex(file).ctx(|| format!("hash {}", file.display()))?;
    let name = file
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or_else(|| crate::err!("bad file name"))?;
    Ok(format!("yone-signature-v1\n{sha}  {name}\n").into_bytes())
}

fn scratch(tag: &str) -> PathBuf {
    std::env::temp_dir().join(format!(
        "yone-{}-{}-{}",
        tag,
        std::process::id(),
        crate::util::now()
    ))
}

fn openssl(args: &[&std::ffi::OsStr]) -> Result<std::process::Output> {
    Command::new("openssl")
        .args(args)
        .stdin(Stdio::null())
        .output()
        .map_err(|e| crate::err!("cannot run openssl: {e}"))
}

pub fn keygen(prefix: &Path) -> Result<(PathBuf, PathBuf)> {
    let secret = crate::util::suffixed(prefix, ".key");
    let public = crate::util::suffixed(prefix, ".pub.pem");
    if secret.exists() {
        bail!("{} already exists", secret.display());
    }
    let o = openssl(&[
        "genpkey".as_ref(),
        "-algorithm".as_ref(),
        "ed25519".as_ref(),
        "-out".as_ref(),
        secret.as_os_str(),
    ])?;
    if !o.status.success() {
        bail!(
            "openssl genpkey failed: {}",
            String::from_utf8_lossy(&o.stderr)
        );
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&secret, fs::Permissions::from_mode(0o600))?;
    }
    let o = openssl(&[
        "pkey".as_ref(),
        "-in".as_ref(),
        secret.as_os_str(),
        "-pubout".as_ref(),
        "-out".as_ref(),
        public.as_os_str(),
    ])?;
    if !o.status.success() {
        bail!(
            "openssl pkey failed: {}",
            String::from_utf8_lossy(&o.stderr)
        );
    }
    Ok((secret, public))
}

/// Sign `file`, writing `<file>.sig`.
pub fn sign(file: &Path, key: &Path) -> Result<PathBuf> {
    let stmt = scratch("stmt");
    fs::write(&stmt, statement(file)?)?;
    let sig = crate::util::suffixed(file, ".sig");
    let o = openssl(&[
        "pkeyutl".as_ref(),
        "-sign".as_ref(),
        "-rawin".as_ref(),
        "-inkey".as_ref(),
        key.as_os_str(),
        "-in".as_ref(),
        stmt.as_os_str(),
        "-out".as_ref(),
        sig.as_os_str(),
    ]);
    let _ = fs::remove_file(&stmt);
    let o = o?;
    if !o.status.success() {
        bail!(
            "signing {} failed: {}",
            file.display(),
            String::from_utf8_lossy(&o.stderr).trim()
        );
    }
    Ok(sig)
}

/// Verify `sig` for `file` against every trusted key in `keydir`.
/// Returns the name of the key that matched.
pub fn verify(file: &Path, sig: &Path, keydir: &Path) -> Result<String> {
    if !sig.exists() {
        bail!("missing signature {}", sig.display());
    }
    let mut keys: Vec<PathBuf> = match fs::read_dir(keydir) {
        Ok(rd) => rd
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .filter(|p| p.extension().map(|x| x == "pem").unwrap_or(false))
            .collect(),
        Err(_) => vec![],
    };
    keys.sort();
    if keys.is_empty() {
        bail!("no trusted keys in {}", keydir.display());
    }
    let stmt = scratch("verify");
    fs::write(&stmt, statement(file)?)?;
    let mut matched = None;
    for k in &keys {
        let o = openssl(&[
            "pkeyutl".as_ref(),
            "-verify".as_ref(),
            "-pubin".as_ref(),
            "-rawin".as_ref(),
            "-inkey".as_ref(),
            k.as_os_str(),
            "-in".as_ref(),
            stmt.as_os_str(),
            "-sigfile".as_ref(),
            sig.as_os_str(),
        ]);
        if let Ok(o) = o {
            if o.status.success() {
                matched = Some(k.file_name().unwrap().to_string_lossy().into_owned());
                break;
            }
        }
    }
    let _ = fs::remove_file(&stmt);
    matched.ok_or_else(|| {
        crate::err!(
            "invalid signature for {} (no trusted key matches)",
            file.display()
        )
    })
}
