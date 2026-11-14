//! Minimal, strict tar (ustar + GNU long names + pax path records).
//! Writer output is reproducible: fixed mtime, sorted input, and owners as
//! the caller sets them (root unless a file belongs to someone else).

use std::io::{self, Read, Write};

const BLOCK: usize = 512;

#[derive(Debug, Clone, PartialEq)]
pub enum Kind {
    File,
    Dir,
    Symlink(String),
    Hardlink(String),
}

/// Who owns an entry. Names come first when the package is installed (ids
/// differ between systems); the numbers are the fallback.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Owner {
    pub uid: u32,
    pub gid: u32,
    pub user: String,
    pub group: String,
}

impl Owner {
    pub fn root() -> Owner {
        Owner {
            uid: 0,
            gid: 0,
            user: "root".into(),
            group: "root".into(),
        }
    }

    pub fn is_root(&self) -> bool {
        self.uid == 0 && self.gid == 0 && self.user == "root" && self.group == "root"
    }

    /// `user:group` as recorded in the local database.
    pub fn spec(&self) -> String {
        format!("{}:{}", self.user, self.group)
    }
}

#[derive(Debug, Clone)]
pub struct Entry {
    pub path: String,
    pub mode: u32,
    pub size: u64,
    pub kind: Kind,
    /// Extended attributes from pax `SCHILY.xattr.<name>` records.
    pub xattrs: Vec<(String, Vec<u8>)>,
    pub owner: Owner,
}

/// One pax extended-header record: "<len> <key>=<value>\n", where <len>
/// counts the whole record, its own digits included.
fn pax_record(key: &str, value: &[u8]) -> Vec<u8> {
    let body = key.len() + value.len() + 3; // ' ', '=', '\n'
    let mut len = body + 1;
    while len != body + len.to_string().len() {
        len = body + len.to_string().len();
    }
    let mut r = format!("{len} {key}=").into_bytes();
    r.extend_from_slice(value);
    r.push(b'\n');
    r
}

// ---------------------------------------------------------------- writer

pub struct TarWriter<W: Write> {
    w: W,
    mtime: u64,
    /// Owner of the next entries; extension records are always root's.
    pub owner: Owner,
}

fn put_octal(buf: &mut [u8], v: u64) {
    // width-1 octal digits followed by NUL
    let width = buf.len() - 1;
    let s = format!("{:0width$o}", v, width = width);
    buf[..width].copy_from_slice(&s.as_bytes()[s.len() - width..]);
    buf[width] = 0;
}

fn put_str(buf: &mut [u8], s: &str) {
    let b = s.as_bytes();
    buf[..b.len()].copy_from_slice(b);
}

impl<W: Write> TarWriter<W> {
    pub fn new(w: W, mtime: u64) -> Self {
        TarWriter {
            w,
            mtime,
            owner: Owner::root(),
        }
    }

    fn raw_header(
        &mut self,
        name: &str,
        prefix: &str,
        mode: u32,
        size: u64,
        typ: u8,
        link: &str,
    ) -> io::Result<()> {
        if size >= 0o77777777777 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "file too large for ustar",
            ));
        }
        if name.starts_with("././@") {
            return self.raw_header_as(name, prefix, mode, size, typ, link, &Owner::root());
        }
        let owner = self.owner.clone();
        self.raw_header_as(name, prefix, mode, size, typ, link, &owner)
    }

    #[allow(clippy::too_many_arguments)]
    fn raw_header_as(
        &mut self,
        name: &str,
        prefix: &str,
        mode: u32,
        size: u64,
        typ: u8,
        link: &str,
        owner: &Owner,
    ) -> io::Result<()> {
        if owner.uid > 0o7777777 || owner.gid > 0o7777777 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("{name}: owner id too large for ustar"),
            ));
        }
        if owner.user.len() > 31 || owner.group.len() > 31 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("{name}: owner name longer than 31 bytes"),
            ));
        }
        let mut h = [0u8; BLOCK];
        put_str(&mut h[0..100], name);
        put_octal(&mut h[100..108], (mode & 0o7777) as u64);
        put_octal(&mut h[108..116], owner.uid as u64);
        put_octal(&mut h[116..124], owner.gid as u64);
        put_octal(&mut h[124..136], size);
        put_octal(&mut h[136..148], self.mtime);
        h[148..156].copy_from_slice(b"        ");
        h[156] = typ;
        put_str(&mut h[157..257], link);
        h[257..263].copy_from_slice(b"ustar\0");
        h[263..265].copy_from_slice(b"00");
        put_str(&mut h[265..297], &owner.user);
        put_str(&mut h[297..329], &owner.group);
        put_str(&mut h[345..500], prefix);
        let sum: u32 = h.iter().map(|&b| b as u32).sum();
        let s = format!("{:06o}\0 ", sum);
        h[148..156].copy_from_slice(s.as_bytes());
        self.w.write_all(&h)
    }

    fn long_record(&mut self, typ: u8, value: &str) -> io::Result<()> {
        let data = format!("{}\0", value);
        self.raw_header("././@LongLink", "", 0o644, data.len() as u64, typ, "")?;
        self.w.write_all(data.as_bytes())?;
        self.pad(data.len() as u64)
    }

    fn pad(&mut self, size: u64) -> io::Result<()> {
        let rem = (size % BLOCK as u64) as usize;
        if rem != 0 {
            self.w.write_all(&vec![0u8; BLOCK - rem])?;
        }
        Ok(())
    }

    fn header(&mut self, path: &str, mode: u32, size: u64, typ: u8, link: &str) -> io::Result<()> {
        let link_field = if link.len() > 100 {
            self.long_record(b'K', link)?;
            &link[..0]
        } else {
            link
        };
        if path.len() <= 100 {
            return self.raw_header(path, "", mode, size, typ, link_field);
        }
        // try the ustar prefix/name split
        let bytes = path.as_bytes();
        for (i, &b) in bytes.iter().enumerate() {
            if b == b'/' && i <= 155 && path.len() - i - 1 <= 100 && i > 0 {
                return self.raw_header(&path[i + 1..], &path[..i], mode, size, typ, link_field);
            }
        }
        self.long_record(b'L', path)?;
        let short: String = path.chars().take(99).collect();
        self.raw_header(&short, "", mode, size, typ, link_field)
    }

    pub fn add_dir(&mut self, path: &str, mode: u32) -> io::Result<()> {
        let p = if path.ends_with('/') {
            path.to_string()
        } else {
            format!("{}/", path)
        };
        self.header(&p, mode, 0, b'5', "")
    }

    pub fn add_symlink(&mut self, path: &str, target: &str) -> io::Result<()> {
        self.header(path, 0o777, 0, b'2', target)
    }

    /// A regular file preceded by a pax header carrying its extended
    /// attributes (only when there are some).
    pub fn add_file_xattrs<R: Read>(
        &mut self,
        path: &str,
        mode: u32,
        size: u64,
        data: &mut R,
        xattrs: &[(String, Vec<u8>)],
    ) -> io::Result<()> {
        if !xattrs.is_empty() {
            let mut pax = vec![];
            for (k, v) in xattrs {
                pax.extend(pax_record(&format!("SCHILY.xattr.{k}"), v));
            }
            self.raw_header("././@PaxHeader", "", 0o644, pax.len() as u64, b'x', "")?;
            self.w.write_all(&pax)?;
            self.pad(pax.len() as u64)?;
        }
        self.add_file(path, mode, size, data)
    }

    pub fn add_file<R: Read>(
        &mut self,
        path: &str,
        mode: u32,
        size: u64,
        data: &mut R,
    ) -> io::Result<()> {
        self.header(path, mode, size, b'0', "")?;
        let copied = io::copy(&mut data.take(size), &mut self.w)?;
        if copied != size {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                format!("{path}: file changed while archiving"),
            ));
        }
        self.pad(size)
    }

    pub fn finish(mut self) -> io::Result<W> {
        self.w.write_all(&[0u8; BLOCK * 2])?;
        self.w.flush()?;
        Ok(self.w)
    }
}

// ---------------------------------------------------------------- reader

pub struct TarReader<R: Read> {
    r: R,
    remaining: u64,
    pad: u64,
}

fn parse_octal(field: &[u8]) -> io::Result<u64> {
    // GNU base-256 for large numbers
    if !field.is_empty() && field[0] & 0x80 != 0 {
        let mut v: u64 = (field[0] & 0x7f) as u64;
        for &b in &field[1..] {
            v = v.checked_shl(8).ok_or_else(|| bad("numeric overflow"))? | b as u64;
        }
        return Ok(v);
    }
    let s: String = field
        .iter()
        .take_while(|&&b| b != 0)
        .map(|&b| b as char)
        .collect::<String>();
    let s = s.trim();
    if s.is_empty() {
        return Ok(0);
    }
    u64::from_str_radix(s, 8).map_err(|_| bad("invalid octal field"))
}

fn cstr(field: &[u8]) -> io::Result<String> {
    let end = field.iter().position(|&b| b == 0).unwrap_or(field.len());
    String::from_utf8(field[..end].to_vec()).map_err(|_| bad("non UTF-8 path in archive"))
}

fn bad(msg: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, format!("tar: {msg}"))
}

impl<R: Read> TarReader<R> {
    pub fn new(r: R) -> Self {
        TarReader {
            r,
            remaining: 0,
            pad: 0,
        }
    }

    fn skip_current(&mut self) -> io::Result<()> {
        let n = self.remaining + self.pad;
        if n > 0 {
            let got = io::copy(&mut (&mut self.r).take(n), &mut io::sink())?;
            if got != n {
                return Err(bad("truncated archive"));
            }
        }
        self.remaining = 0;
        self.pad = 0;
        Ok(())
    }

    fn read_block(&mut self, buf: &mut [u8; BLOCK]) -> io::Result<bool> {
        let mut filled = 0;
        while filled < BLOCK {
            let n = self.r.read(&mut buf[filled..])?;
            if n == 0 {
                if filled == 0 {
                    return Ok(false);
                }
                return Err(bad("truncated header"));
            }
            filled += n;
        }
        Ok(true)
    }

    fn read_payload(&mut self, size: u64) -> io::Result<Vec<u8>> {
        if size > 1 << 20 {
            return Err(bad("extended header too large"));
        }
        let mut v = vec![0u8; size as usize];
        self.r.read_exact(&mut v)?;
        let rem = size % BLOCK as u64;
        if rem != 0 {
            io::copy(&mut (&mut self.r).take(BLOCK as u64 - rem), &mut io::sink())?;
        }
        Ok(v)
    }

    /// Advance to the next entry, skipping unread data of the current one.
    pub fn next_entry(&mut self) -> io::Result<Option<Entry>> {
        self.skip_current()?;
        let mut long_name: Option<String> = None;
        let mut long_link: Option<String> = None;
        let mut xattrs: Vec<(String, Vec<u8>)> = vec![];
        loop {
            let mut h = [0u8; BLOCK];
            if !self.read_block(&mut h)? {
                return Ok(None);
            }
            if h.iter().all(|&b| b == 0) {
                return Ok(None);
            }
            let stored = parse_octal(&h[148..156])?;
            let mut sum: u64 = 0;
            for (i, &b) in h.iter().enumerate() {
                sum += if (148..156).contains(&i) {
                    b' ' as u64
                } else {
                    b as u64
                };
            }
            if sum != stored {
                return Err(bad("header checksum mismatch"));
            }
            let size = parse_octal(&h[124..136])?;
            let typ = h[156];
            match typ {
                b'L' => {
                    let v = self.read_payload(size)?;
                    long_name = Some(cstr(&v)?);
                    continue;
                }
                b'K' => {
                    let v = self.read_payload(size)?;
                    long_link = Some(cstr(&v)?);
                    continue;
                }
                b'x' => {
                    let v = self.read_payload(size)?;
                    for (k, val) in parse_pax(&v)? {
                        let text = || {
                            String::from_utf8(val.clone()).map_err(|_| bad("non UTF-8 pax path"))
                        };
                        match k.as_str() {
                            "path" => long_name = Some(text()?),
                            "linkpath" => long_link = Some(text()?),
                            _ => {
                                if let Some(name) = k.strip_prefix("SCHILY.xattr.") {
                                    xattrs.push((name.to_string(), val));
                                }
                            }
                        }
                    }
                    continue;
                }
                b'g' => {
                    self.read_payload(size)?;
                    continue;
                }
                _ => {}
            }
            let name = cstr(&h[0..100])?;
            let prefix = if &h[257..262] == b"ustar" {
                cstr(&h[345..500])?
            } else {
                String::new()
            };
            let path = match long_name.take() {
                Some(p) => p,
                None if prefix.is_empty() => name,
                None => format!("{}/{}", prefix, name),
            };
            let link = match long_link.take() {
                Some(l) => l,
                None => cstr(&h[157..257])?,
            };
            let mode = parse_octal(&h[100..108])? as u32;
            let owner = Owner {
                uid: parse_octal(&h[108..116])? as u32,
                gid: parse_octal(&h[116..124])? as u32,
                user: cstr(&h[265..297])?,
                group: cstr(&h[297..329])?,
            };
            let kind = match typ {
                b'0' | 0 | b'7' => Kind::File,
                b'5' => Kind::Dir,
                b'2' => Kind::Symlink(link),
                b'1' => Kind::Hardlink(link),
                other => {
                    return Err(bad(&format!(
                        "unsupported entry type '{}' for {}",
                        other as char, path
                    )))
                }
            };
            let size = if matches!(kind, Kind::File) { size } else { 0 };
            self.remaining = size;
            self.pad = (BLOCK as u64 - size % BLOCK as u64) % BLOCK as u64;
            return Ok(Some(Entry {
                path,
                mode,
                size,
                kind,
                xattrs,
                owner,
            }));
        }
    }

    /// Copy the data of the current entry into `out`.
    pub fn copy_data<W: Write>(&mut self, out: &mut W) -> io::Result<u64> {
        let n = self.remaining;
        let got = io::copy(&mut (&mut self.r).take(n), out)?;
        if got != n {
            return Err(bad("truncated file data"));
        }
        self.remaining = 0;
        Ok(got)
    }

    pub fn into_inner(self) -> R {
        self.r
    }
}

fn parse_pax(data: &[u8]) -> io::Result<Vec<(String, Vec<u8>)>> {
    let mut out = vec![];
    let mut i = 0;
    while i < data.len() {
        let sp = data[i..]
            .iter()
            .position(|&b| b == b' ')
            .ok_or_else(|| bad("bad pax record"))?
            + i;
        let len: usize = std::str::from_utf8(&data[i..sp])
            .ok()
            .and_then(|s| s.parse().ok())
            .ok_or_else(|| bad("bad pax length"))?;
        if len == 0 || i + len > data.len() {
            return Err(bad("bad pax length"));
        }
        let rec = &data[sp + 1..i + len - 1];
        let eq = rec
            .iter()
            .position(|&b| b == b'=')
            .ok_or_else(|| bad("bad pax record"))?;
        out.push((
            String::from_utf8_lossy(&rec[..eq]).into_owned(),
            rec[eq + 1..].to_vec(),
        ));
        i += len;
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip() {
        let long = format!("usr/share/{}/file.txt", "d".repeat(150));
        let very_long = format!("{}/x", "e".repeat(300));
        let mut tw = TarWriter::new(Vec::new(), 0);
        tw.add_dir("usr", 0o755).unwrap();
        tw.add_file("usr/hello", 0o755, 5, &mut &b"hello"[..])
            .unwrap();
        tw.add_file(&long, 0o644, 3, &mut &b"abc"[..]).unwrap();
        tw.add_file(&very_long, 0o600, 0, &mut &b""[..]).unwrap();
        tw.add_symlink("usr/link", &"t".repeat(120)).unwrap();
        let data = tw.finish().unwrap();
        assert_eq!(data.len() % 512, 0);

        let mut tr = TarReader::new(&data[..]);
        let e = tr.next_entry().unwrap().unwrap();
        assert_eq!((e.path.as_str(), e.kind.clone()), ("usr/", Kind::Dir));
        let e = tr.next_entry().unwrap().unwrap();
        assert_eq!(e.path, "usr/hello");
        assert_eq!(e.mode, 0o755);
        let mut v = vec![];
        tr.copy_data(&mut v).unwrap();
        assert_eq!(v, b"hello");
        let e = tr.next_entry().unwrap().unwrap(); // data skipped automatically
        assert_eq!(e.path, long);
        let e = tr.next_entry().unwrap().unwrap();
        assert_eq!(e.path, very_long);
        let e = tr.next_entry().unwrap().unwrap();
        assert_eq!(e.kind, Kind::Symlink("t".repeat(120)));
        assert!(tr.next_entry().unwrap().is_none());
    }

    #[test]
    fn xattrs_roundtrip() {
        let cap = vec![
            1u8, 0, 0, 2, 0, 0x20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        ];
        for len in [0usize, 5, 88, 500] {
            let r = pax_record("k", &vec![b'a'; len]);
            let digits: usize =
                std::str::from_utf8(&r[..r.iter().position(|&b| b == b' ').unwrap()])
                    .unwrap()
                    .parse()
                    .unwrap();
            assert_eq!(digits, r.len(), "record length for {len}");
        }
        let mut tw = TarWriter::new(Vec::new(), 0);
        let xa = vec![("security.capability".to_string(), cap.clone())];
        tw.add_file_xattrs("usr/bin/ping", 0o755, 2, &mut &b"hi"[..], &xa)
            .unwrap();
        tw.add_file("usr/bin/plain", 0o755, 0, &mut &b""[..])
            .unwrap();
        let data = tw.finish().unwrap();
        let mut tr = TarReader::new(&data[..]);
        let e = tr.next_entry().unwrap().unwrap();
        assert_eq!(e.path, "usr/bin/ping");
        assert_eq!(e.xattrs, xa);
        let mut v = vec![];
        tr.copy_data(&mut v).unwrap();
        assert_eq!(v, b"hi");
        let e = tr.next_entry().unwrap().unwrap();
        assert!(
            e.xattrs.is_empty(),
            "attributes must not leak to the next entry"
        );
    }

    #[test]
    fn owners_roundtrip() {
        let mut tw = TarWriter::new(Vec::new(), 0);
        tw.add_file("usr/bin/plain", 0o755, 0, &mut &b""[..])
            .unwrap();
        tw.owner = Owner {
            uid: 0,
            gid: 5,
            user: "root".into(),
            group: "tty".into(),
        };
        let long = format!("usr/share/{}/wall", "d".repeat(150));
        tw.add_file(&long, 0o2755, 1, &mut &b"w"[..]).unwrap();
        tw.owner = Owner::root();
        tw.add_dir("var", 0o755).unwrap();
        let data = tw.finish().unwrap();
        let mut tr = TarReader::new(&data[..]);
        let e = tr.next_entry().unwrap().unwrap();
        assert!(e.owner.is_root());
        let e = tr.next_entry().unwrap().unwrap();
        assert_eq!((e.path.as_str(), e.mode), (long.as_str(), 0o2755));
        assert_eq!(e.owner.spec(), "root:tty");
        assert_eq!(e.owner.gid, 5);
        let e = tr.next_entry().unwrap().unwrap();
        assert!(
            e.owner.is_root(),
            "the owner must not leak to the next entry"
        );

        let mut tw = TarWriter::new(Vec::new(), 0);
        tw.owner.group = "a-group-name-longer-than-31-bytes".into();
        assert!(tw.add_dir("x", 0o755).is_err());
    }

    #[test]
    fn corrupt_checksum_rejected() {
        let mut tw = TarWriter::new(Vec::new(), 0);
        tw.add_file("a", 0o644, 1, &mut &b"x"[..]).unwrap();
        let mut data = tw.finish().unwrap();
        data[0] = b'b';
        assert!(TarReader::new(&data[..]).next_entry().is_err());
    }
}
