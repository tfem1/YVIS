//! Post-transaction hooks: declarative, shipped by the packages that need them.
//!
//! A hook is a `key = value` file in `ROOT/usr/share/yone/hooks/` (from a
//! package) or `ROOT/etc/yone/hooks/` (from the administrator; a file with
//! the same name replaces the packaged one, an empty file disables it):
//!
//! ```text
//! desc  = Compiling GSettings schemas
//! paths = usr/share/glib-2.0/schemas/
//! on    = install upgrade remove        # default: all three
//! run   = /usr/bin/glib-compile-schemas /usr/share/glib-2.0/schemas
//! ```
//!
//! After a committed transaction, each hook whose `paths` prefixes match a
//! changed file runs once, in file-name order, inside the root (directly for
//! `/`, through chroot otherwise). A hook whose program is missing from the
//! root is skipped (bootstrap). A failing hook is reported but never undoes
//! the transaction, which is already complete.

use crate::config::Config;
use crate::pkginfo::parse_kv;
use crate::ui::Ui;
use crate::util;
use std::collections::BTreeMap;
use std::fs;
use std::process::Command;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Op {
    Install,
    Upgrade,
    Remove,
}

#[derive(Debug)]
pub struct Hook {
    pub name: String,
    pub desc: String,
    pub paths: Vec<String>,
    pub on: Vec<Op>,
    pub run: String,
}

/// Built in, so the base system works before any package ships hooks.
const BUILTIN: &[(&str, &str)] = &[(
    "10-ldconfig.hook",
    "desc = Updating the shared library cache\n\
     paths = usr/lib/ usr/lib64/\n\
     run = /usr/sbin/ldconfig\n",
)];

fn parse(name: &str, text: &str) -> Result<Option<Hook>, String> {
    let kv = parse_kv(text).map_err(|e| e.to_string())?;
    if kv.is_empty() {
        return Ok(None); // empty file: disabled
    }
    let get = |k: &str| {
        kv.iter()
            .filter(|(x, _)| x == k)
            .map(|(_, v)| v.as_str())
            .collect::<Vec<_>>()
            .join(" ")
    };
    let run = get("run");
    let paths: Vec<String> = get("paths")
        .split_whitespace()
        .map(|p| p.trim_start_matches('/').to_string())
        .collect();
    if run.is_empty() || paths.is_empty() {
        return Err("needs `paths` and `run`".into());
    }
    let mut on = vec![];
    for w in get("on").split_whitespace() {
        on.push(match w {
            "install" => Op::Install,
            "upgrade" => Op::Upgrade,
            "remove" => Op::Remove,
            other => return Err(format!("unknown `on` value '{other}'")),
        });
    }
    if on.is_empty() {
        on = vec![Op::Install, Op::Upgrade, Op::Remove];
    }
    let desc = match get("desc") {
        d if d.is_empty() => name.trim_end_matches(".hook").to_string(),
        d => d,
    };
    Ok(Some(Hook {
        name: name.to_string(),
        desc,
        paths,
        on,
        run,
    }))
}

/// Every active hook, the administrator's overriding the packaged ones.
pub fn load(cfg: &Config, ui: &Ui) -> Vec<Hook> {
    let mut texts: BTreeMap<String, String> = BTreeMap::new();
    for (n, t) in BUILTIN {
        texts.insert(n.to_string(), t.to_string());
    }
    for dir in ["usr/share/yone/hooks", "etc/yone/hooks"] {
        let Ok(rd) = fs::read_dir(cfg.root.join(dir)) else {
            continue;
        };
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            if name.ends_with(".hook") {
                if let Ok(t) = fs::read_to_string(e.path()) {
                    texts.insert(name, t);
                }
            }
        }
    }
    let mut hooks = vec![];
    for (name, text) in texts {
        match parse(&name, &text) {
            Ok(Some(h)) => hooks.push(h),
            Ok(None) => {}
            Err(e) => ui.warn(&format!("hook {name} ignored: {e}")),
        }
    }
    hooks
}

/// Run the hooks matching `changed` (root-relative paths) for `ops`.
pub fn run(cfg: &Config, ui: &Ui, ops: &[Op], changed: &[String]) {
    for h in load(cfg, ui) {
        if !h.on.iter().any(|o| ops.contains(o)) {
            continue;
        }
        if !changed
            .iter()
            .any(|c| h.paths.iter().any(|p| c.starts_with(p.as_str())))
        {
            continue;
        }
        let prog = h.run.split_whitespace().next().unwrap_or("");
        if prog.starts_with('/') && fs::metadata(cfg.root.join(&prog[1..])).is_err() {
            continue; // the program is not installed in this root yet
        }
        let mut cmd = if cfg.is_live_root() {
            let mut c = Command::new("/bin/sh");
            c.arg("-c").arg(&h.run);
            c
        } else {
            if util::euid() != Some(0) {
                ui.warn(&format!(
                    "hook '{}' skipped: running it in {} needs root",
                    h.desc,
                    cfg.root.display()
                ));
                continue;
            }
            let mut c = Command::new("chroot");
            c.arg(&cfg.root).arg("/bin/sh").arg("-c").arg(&h.run);
            c
        };
        match cmd.status() {
            Ok(s) if s.success() => ui.info(&format!("hook: {}", h.desc)),
            Ok(s) => ui.warn(&format!("hook '{}' failed ({s})", h.desc)),
            Err(e) => ui.warn(&format!("hook '{}' could not run: {e}", h.desc)),
        }
        util::log(cfg, &format!("hook {} ({})", h.name, h.desc));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_hooks() {
        let h = parse(
            "20-schemas.hook",
            "desc = Schemas\npaths = /usr/share/glib-2.0/schemas/\non = install upgrade\nrun = /usr/bin/x a b\n",
        )
        .unwrap()
        .unwrap();
        assert_eq!(h.paths, vec!["usr/share/glib-2.0/schemas/"]);
        assert_eq!(h.on, vec![Op::Install, Op::Upgrade]);
        assert_eq!(h.run, "/usr/bin/x a b");
        assert!(
            parse("x.hook", "").unwrap().is_none(),
            "an empty file disables a hook"
        );
        assert!(
            parse("x.hook", "run = true\n").is_err(),
            "paths are required"
        );
        assert!(parse("x.hook", "paths = a/\nrun = true\non = reboot\n").is_err());
        let d = parse("30-x.hook", "paths = a/\nrun = true\n")
            .unwrap()
            .unwrap();
        assert_eq!((d.desc.as_str(), d.on.len()), ("30-x", 3));
    }
}
