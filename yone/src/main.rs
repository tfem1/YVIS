//! Yone — the package manager of YVIS OS.

mod archive;
mod build;
mod config;
mod db;
mod download;
mod error;
mod pkginfo;
mod sha256;
mod sign;
mod sync;
mod tar;
mod transaction;
mod ui;
mod util;
mod version;

use config::Config;
use db::LocalDb;
use error::Result;
use std::path::PathBuf;
use transaction::Opts;
use ui::{human_bytes, Ui};

const HELP: &str = "\
yone — package manager of YVIS OS

usage: yone [options] <command> [arguments]

commands:
  install <pkg|file.yon>...   install packages and their dependencies
  remove <pkg>...             remove packages (--cascade: and their dependents)
  autoremove                  remove dependencies nothing needs anymore
  update                      download and verify repository indexes
  upgrade                     upgrade every installed package
  search <text>               search the repositories
  info <pkg>                  show package details
  list                        list installed packages (--explicit, --deps)
  verify [pkg...]             check installed files against the database
  clean                       remove cached packages not installed (--all: everything)
  recover                     roll back an interrupted transaction
  build <dir>                 build a package from <dir>/YONEBUILD
  repo-index <dir> --name N   generate a repository index
  keygen <prefix>             create an ed25519 signing key pair

options:
  -y, --noconfirm      never ask (also YONE_NONINTERACTIVE=1)
      --root DIR       operate on another root (image building, chroots)
      --config FILE    configuration file (default ROOT/etc/yone/yone.conf)
      --offline        never touch the network; use the cache only
      --overwrite      replace files on disk that no package owns
      --allow-unsigned install local .yon files without a signature
      --reinstall      reinstall targets that are already up to date
      --asdeps         mark installed targets as dependencies
      --color WHEN     auto | always | never
  build:      --out DIR  --sign KEY  --compress zstd|xz
  repo-index: --name NAME  --sign KEY
  -h, --help / -V, --version
";

fn main() {
    let code = match run() {
        Ok(c) => c,
        Err(e) => {
            let ui = Ui::new("auto", true);
            eprintln!("{} {}", ui.red("error:"), e);
            1
        }
    };
    std::process::exit(code);
}

fn run() -> Result<i32> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut pos: Vec<String> = vec![];
    let mut opts = Opts::default();
    let mut root = PathBuf::from("/");
    let mut config: Option<PathBuf> = None;
    let mut color = "auto".to_string();
    let mut noconfirm = std::env::var("YONE_NONINTERACTIVE")
        .map(|v| v == "1")
        .unwrap_or(false);
    let (mut out, mut key, mut name, mut compress) = (
        None::<PathBuf>,
        None::<PathBuf>,
        None::<String>,
        None::<String>,
    );
    let (mut all, mut explicit_only, mut deps_only) = (false, false, false);
    let mut it = args.into_iter();
    while let Some(a) = it.next() {
        let mut val = |flag: &str| it.next().ok_or_else(|| err!("{flag} needs a value"));
        match a.as_str() {
            "-h" | "--help" => {
                print!("{HELP}");
                return Ok(0);
            }
            "-V" | "--version" => {
                println!("yone {}", env!("CARGO_PKG_VERSION"));
                return Ok(0);
            }
            "-y" | "--noconfirm" => noconfirm = true,
            "--root" => root = PathBuf::from(val("--root")?),
            "--config" => config = Some(PathBuf::from(val("--config")?)),
            "--color" => color = val("--color")?,
            "--offline" => opts.offline = true,
            "--overwrite" => opts.overwrite = true,
            "--allow-unsigned" => opts.allow_unsigned = true,
            "--reinstall" => opts.reinstall = true,
            "--asdeps" => opts.asdeps = true,
            "--cascade" => opts.cascade = true,
            "--all" => all = true,
            "--explicit" => explicit_only = true,
            "--deps" => deps_only = true,
            "--out" => out = Some(PathBuf::from(val("--out")?)),
            "--sign" => key = Some(PathBuf::from(val("--sign")?)),
            "--name" => name = Some(val("--name")?),
            "--compress" => compress = Some(val("--compress")?),
            s if s.starts_with('-') && s.len() > 1 => bail!("unknown option {s} (see yone --help)"),
            _ => pos.push(a),
        }
    }
    let ui = Ui::new(&color, noconfirm);
    let Some(cmd) = pos.first().cloned() else {
        print!("{HELP}");
        return Ok(2);
    };
    let args = &pos[1..];
    let root = if root.is_absolute() {
        root
    } else {
        std::env::current_dir()?.join(root)
    };
    let cfg = || Config::load(&root, config.as_deref());
    let need = |n: usize| -> Result<()> {
        if args.len() < n {
            bail!("'{cmd}' needs an argument (see yone --help)");
        }
        Ok(())
    };

    match cmd.as_str() {
        "install" | "i" => {
            need(1)?;
            transaction::install(&cfg()?, &ui, args, &opts)?;
        }
        "remove" | "rm" => {
            need(1)?;
            transaction::remove(&cfg()?, &ui, args, &opts)?;
        }
        "autoremove" => transaction::autoremove(&cfg()?, &ui)?,
        "update" => {
            let c = cfg()?;
            if opts.offline {
                bail!(
                    "'update' needs the network (or file:// mirrors) and cannot run with --offline"
                );
            }
            let _lock = transaction::Lock::acquire(&c)?;
            sync::update(&c, &ui)?;
        }
        "upgrade" => transaction::upgrade(&cfg()?, &ui, &opts)?,
        "search" | "s" => {
            need(1)?;
            let c = cfg()?;
            let s = sync::SyncDb::load(&c, &ui)?;
            let installed = LocalDb::open(&c.dbpath).list()?;
            let term = args.join(" ").to_lowercase();
            let mut found = 0;
            for e in s.entries.iter().filter(|e| {
                e.info.name.contains(&term) || e.info.desc.to_lowercase().contains(&term)
            }) {
                found += 1;
                let mark = match installed.iter().find(|i| i.info.name == e.info.name) {
                    Some(i) if i.info.version == e.info.version => ui.green(" [installed]"),
                    Some(i) => ui.yellow(&format!(" [installed: {}]", i.info.version)),
                    None => String::new(),
                };
                println!(
                    "{}/{} {}{}",
                    ui.dim(&e.repo),
                    ui.bold(&e.info.name),
                    ui.accent(&e.info.version),
                    mark
                );
                if !e.info.desc.is_empty() {
                    println!("    {}", e.info.desc);
                }
            }
            if found == 0 {
                return Ok(1);
            }
        }
        "info" => {
            need(1)?;
            let c = cfg()?;
            let db = LocalDb::open(&c.dbpath);
            for n in args {
                let local = db.get(n)?;
                let s = sync::SyncDb::load(&c, &ui)?;
                let remote = s.find(n);
                let (p, origin) = match (&local, remote) {
                    (Some(l), _) => (l.info.clone(), "installed".to_string()),
                    (None, Some(r)) => (r.info.clone(), format!("repository {}", r.repo)),
                    (None, None) => bail!("package not found: {n}"),
                };
                let row = |k: &str, v: &str| {
                    println!("{:<16}: {}", ui.bold(k), if v.is_empty() { "—" } else { v })
                };
                row("Name", &p.name);
                row("Version", &p.version);
                row("Description", &p.desc);
                row("URL", &p.url);
                row("License", &p.license);
                row("Architecture", &p.arch);
                row("Depends on", &p.depends.join("  "));
                row("Provides", &p.provides.join("  "));
                row("Conflicts with", &p.conflicts.join("  "));
                row("Installed size", &human_bytes(p.isize));
                row("Packager", &p.packager);
                row("Source", &origin);
                if let Some(l) = &local {
                    row(
                        "Install reason",
                        if l.explicit {
                            "explicitly installed"
                        } else {
                            "installed as a dependency"
                        },
                    );
                    if let Some(r) = remote {
                        if r.info.version != l.info.version {
                            row("Available", &format!("{} ({})", r.info.version, r.repo));
                        }
                    }
                }
                println!();
            }
        }
        "list" | "ls" => {
            let c = cfg()?;
            for i in LocalDb::open(&c.dbpath).list()? {
                if (explicit_only && !i.explicit) || (deps_only && i.explicit) {
                    continue;
                }
                println!("{} {}", i.info.name, ui.accent(&i.info.version));
            }
        }
        "verify" => {
            if !transaction::verify(&cfg()?, &ui, args)? {
                return Ok(1);
            }
        }
        "clean" => transaction::clean(&cfg()?, &ui, all)?,
        "recover" => {
            let c = cfg()?;
            let _lock = transaction::Lock::acquire(&c)?;
            match transaction::recover(&c)? {
                transaction::Recovery::Clean => ui.success("no interrupted transaction"),
                transaction::Recovery::RolledBack(n) => ui.success(&format!(
                    "interrupted before its commit point: rolled back {n} change(s)"
                )),
                transaction::Recovery::Completed(n) => ui.success(&format!(
                    "interrupted after its commit point: completed ({n} change(s))"
                )),
            }
        }
        "build" => {
            need(1)?;
            let dir = PathBuf::from(&args[0]);
            let c = cfg()?;
            let outdir = out.clone().unwrap_or_else(|| dir.clone());
            let packager =
                std::env::var("YONE_PACKAGER").unwrap_or_else(|_| "YVIS build system".into());
            let bo = build::BuildOpts {
                outdir: &outdir,
                compression: compress.as_deref().unwrap_or(&c.compression),
                key: key.as_deref(),
                packager,
            };
            build::build(&dir, &bo, &ui)?;
        }
        "repo-index" => {
            need(1)?;
            let n = name
                .clone()
                .ok_or_else(|| err!("repo-index needs --name"))?;
            build::repo_index(&PathBuf::from(&args[0]), &n, key.as_deref(), &ui)?;
        }
        "keygen" => {
            need(1)?;
            let (s, p) = sign::keygen(&PathBuf::from(&args[0]))?;
            ui.success(&format!("secret key {} (keep it private)", s.display()));
            ui.success(&format!(
                "public key {} (install it in /etc/yone/keys/)",
                p.display()
            ));
        }
        other => bail!("unknown command '{other}' (see yone --help)"),
    }
    Ok(0)
}
