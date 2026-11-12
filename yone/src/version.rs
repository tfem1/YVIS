//! Version comparison (libalpm/rpm compatible algorithm) and dependency atoms.

use crate::error::Result;
use crate::pkginfo::PkgInfo;
use std::cmp::Ordering;

/// Split `[epoch:]version[-release]`.
fn split_evr(v: &str) -> (u64, &str, Option<&str>) {
    let (epoch, rest) = match v.find(':') {
        Some(i) if i > 0 && v[..i].bytes().all(|b| b.is_ascii_digit()) => {
            (v[..i].parse().unwrap_or(0), &v[i + 1..])
        }
        _ => (0, v),
    };
    match rest.rfind('-') {
        Some(i) => (epoch, &rest[..i], Some(&rest[i + 1..])),
        None => (epoch, rest, None),
    }
}

pub fn rpmvercmp(a: &str, b: &str) -> Ordering {
    if a == b {
        return Ordering::Equal;
    }
    let (a, b) = (a.as_bytes(), b.as_bytes());
    let (mut i, mut j) = (0usize, 0usize);
    while i < a.len() || j < b.len() {
        let (pi, pj) = (i, j);
        while i < a.len() && !a[i].is_ascii_alphanumeric() {
            i += 1;
        }
        while j < b.len() && !b[j].is_ascii_alphanumeric() {
            j += 1;
        }
        if !(i < a.len() && j < b.len()) {
            break;
        }
        if i - pi != j - pj {
            return if i - pi < j - pj {
                Ordering::Less
            } else {
                Ordering::Greater
            };
        }
        let isnum = a[i].is_ascii_digit();
        let (si, sj) = (i, j);
        if isnum {
            while i < a.len() && a[i].is_ascii_digit() {
                i += 1;
            }
            while j < b.len() && b[j].is_ascii_digit() {
                j += 1;
            }
        } else {
            while i < a.len() && a[i].is_ascii_alphabetic() {
                i += 1;
            }
            while j < b.len() && b[j].is_ascii_alphabetic() {
                j += 1;
            }
        }
        let (mut sa, mut sb) = (&a[si..i], &b[sj..j]);
        if sb.is_empty() {
            return if isnum {
                Ordering::Greater
            } else {
                Ordering::Less
            };
        }
        if isnum {
            while sa.len() > 1 && sa[0] == b'0' {
                sa = &sa[1..];
            }
            while sb.len() > 1 && sb[0] == b'0' {
                sb = &sb[1..];
            }
            if sa.len() != sb.len() {
                return sa.len().cmp(&sb.len());
            }
        }
        match sa.cmp(sb) {
            Ordering::Equal => {}
            o => return o,
        }
    }
    let one_end = i >= a.len();
    let two_end = j >= b.len();
    if one_end && two_end {
        return Ordering::Equal;
    }
    if (one_end && !b[j].is_ascii_alphabetic()) || (!one_end && a[i].is_ascii_alphabetic()) {
        Ordering::Less
    } else {
        Ordering::Greater
    }
}

/// Compare full `[epoch:]ver-rel` strings.
pub fn vercmp(a: &str, b: &str) -> Ordering {
    let (ea, va, ra) = split_evr(a);
    let (eb, vb, rb) = split_evr(b);
    ea.cmp(&eb)
        .then_with(|| rpmvercmp(va, vb))
        .then_with(|| match (ra, rb) {
            (Some(x), Some(y)) => rpmvercmp(x, y),
            _ => Ordering::Equal,
        })
}

fn strip_rel(v: &str) -> &str {
    match (v.find(':'), v.rfind('-')) {
        (_, Some(i)) => &v[..i],
        _ => v,
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Op {
    Eq,
    Ge,
    Le,
    Gt,
    Lt,
}

#[derive(Debug, Clone)]
pub struct Dep {
    pub name: String,
    pub op: Option<(Op, String)>,
}

impl Dep {
    pub fn parse(s: &str) -> Result<Dep> {
        let s = s.trim();
        let pos = s.find(['<', '>', '=']);
        let Some(p) = pos else {
            if !crate::pkginfo::valid_name(s) {
                crate::bail!("invalid dependency '{s}'");
            }
            return Ok(Dep {
                name: s.to_string(),
                op: None,
            });
        };
        let name = &s[..p];
        let rest = &s[p..];
        let (op, ver) = if let Some(v) = rest.strip_prefix(">=") {
            (Op::Ge, v)
        } else if let Some(v) = rest.strip_prefix("<=") {
            (Op::Le, v)
        } else if let Some(v) = rest.strip_prefix('=') {
            (Op::Eq, v)
        } else if let Some(v) = rest.strip_prefix('>') {
            (Op::Gt, v)
        } else if let Some(v) = rest.strip_prefix('<') {
            (Op::Lt, v)
        } else {
            crate::bail!("invalid dependency '{s}'");
        };
        if !crate::pkginfo::valid_name(name) || ver.is_empty() {
            crate::bail!("invalid dependency '{s}'");
        }
        Ok(Dep {
            name: name.to_string(),
            op: Some((op, ver.to_string())),
        })
    }

    pub fn version_ok(&self, version: &str) -> bool {
        let Some((op, req)) = &self.op else {
            return true;
        };
        let have = if req.contains('-') {
            version
        } else {
            strip_rel(version)
        };
        let c = vercmp(have, req);
        match op {
            Op::Eq => c == Ordering::Equal,
            Op::Ge => c != Ordering::Less,
            Op::Le => c != Ordering::Greater,
            Op::Gt => c == Ordering::Greater,
            Op::Lt => c == Ordering::Less,
        }
    }

    pub fn satisfied_by(&self, p: &PkgInfo) -> bool {
        if p.name == self.name && self.version_ok(&p.version) {
            return true;
        }
        p.provides.iter().any(|prov| match prov.split_once('=') {
            Some((n, v)) => n == self.name && self.version_ok(v),
            None => prov == &self.name && self.op.is_none(),
        })
    }
}

impl std::fmt::Display for Dep {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match &self.op {
            None => write!(f, "{}", self.name),
            Some((op, v)) => {
                let o = match op {
                    Op::Eq => "=",
                    Op::Ge => ">=",
                    Op::Le => "<=",
                    Op::Gt => ">",
                    Op::Lt => "<",
                };
                write!(f, "{}{}{}", self.name, o, v)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use Ordering::*;

    #[test]
    fn ordering() {
        let cases = [
            ("1.0", "1.0", Equal),
            ("1.0", "1.0.1", Less),
            ("1.9", "1.10", Less),
            ("2.0", "1.99", Greater),
            ("1.0a", "1.0", Less),
            ("1.0rc1", "1.0", Less),
            ("1.0alpha", "1.0beta", Less),
            ("1.001", "1.1", Equal),
            ("1:1.0", "2.0", Greater),
            ("1.0-2", "1.0-10", Less),
            ("1.0-1", "1.0", Equal),
        ];
        for (a, b, o) in cases {
            assert_eq!(vercmp(a, b), o, "{a} vs {b}");
            assert_eq!(vercmp(b, a), o.reverse(), "{b} vs {a}");
        }
    }

    #[test]
    fn deps() {
        let p = PkgInfo {
            name: "libfoo".into(),
            version: "1.2-3".into(),
            provides: vec!["foo-api=2".into()],
            ..Default::default()
        };
        assert!(Dep::parse("libfoo").unwrap().satisfied_by(&p));
        assert!(Dep::parse("libfoo>=1.2").unwrap().satisfied_by(&p));
        assert!(Dep::parse("libfoo=1.2").unwrap().satisfied_by(&p));
        assert!(!Dep::parse("libfoo>1.2").unwrap().satisfied_by(&p));
        assert!(!Dep::parse("libfoo=1.2-4").unwrap().satisfied_by(&p));
        assert!(Dep::parse("foo-api>=2").unwrap().satisfied_by(&p));
        assert!(Dep::parse("foo-api").unwrap().satisfied_by(&p));
        assert!(Dep::parse("bad name").is_err());
    }
}
