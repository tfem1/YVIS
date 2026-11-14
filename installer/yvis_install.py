"""The YVIS installation engine: what the machine has, what the person chose,
the plan that follows, and running it.

The plan is a list of steps, each a bash script, built by plan() from the
choices and the facts alone: the same input always gives the same commands,
so tests check the commands themselves, and `--dry-run` shows them. Secrets
(the user's password, the encryption passphrase) never appear in a script or
a log: the scripts read them from environment variables.

Only the Python standard library is used: the engine runs on the live ISO.
"""
import json
import os
import re
import shlex
import subprocess
import time

TARGET = "/mnt/yvis-target"
LIVE_SYSTEM = "/run/yvis/system"   # the live medium's read-only system image
MIN_DISK = 16 * 1024 ** 3          # bytes
EFI_SIZE = "1GiB"
BOOT_SIZE = "1GiB"                 # separate /boot when the root is encrypted
BIOS_BOOT_GUID = "21686148-6B66-6F68-6E6F-6E7449656564"
DESKTOPS = {"kde": "KDE Plasma", "hyprland": "Hyprland"}
PROFILES = {"minimal": "Minimal", "desktop": "Desktop", "gaming": "Gaming"}
USER_GROUPS = ["wheel", "audio", "video", "input"]
NAME_RE = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
HOST_RE = re.compile(r"^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$")
RESERVED_USERS = {"root", "bin", "daemon", "messagebus", "nobody", "systemd-journal",
                  "systemd-network", "systemd-resolve", "systemd-timesync",
                  "systemd-coredump", "systemd-oom", "uuidd", "lp", "mail", "adm"}


# ------------------------------------------------------------------ facts

def _run(argv):
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=30).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def _live_disk():
    """The disk the live system was started from: never offered as a target."""
    try:
        with open("/proc/mounts") as f:
            for line in f:
                dev, mnt = line.split()[:2]
                if mnt in ("/run/yvis/medium", "/run/yvis/host") and dev.startswith("/dev/"):
                    parent = _run(["lsblk", "-no", "PKNAME", dev]).strip()
                    return "/dev/" + parent if parent else dev
    except OSError:
        pass
    return None


def _lines(path, column=None):
    out = []
    try:
        with open(path) as f:
            for line in f:
                if line.startswith("#") or not line.strip():
                    continue
                out.append(line.split()[column] if column is not None else line.strip())
    except OSError:
        pass
    return out


def facts(source=LIVE_SYSTEM):
    """What this machine and the live system offer."""
    tree = json.loads(_run(["lsblk", "-J", "-b", "-o",
                            "NAME,PATH,SIZE,TYPE,MODEL,TRAN,RM,RO,FSTYPE,LABEL,PARTTYPENAME"]) or '{"blockdevices": []}')
    live = _live_disk()
    disks = []
    for d in tree.get("blockdevices", []):
        if d.get("type") != "disk" or d.get("ro") in (True, "1") or d["path"].startswith(("/dev/loop", "/dev/zram", "/dev/sr")):
            continue
        parts = [{"path": p["path"], "size": int(p["size"]), "fstype": p.get("fstype"),
                  "label": p.get("label"), "type": p.get("parttypename")}
                 for p in d.get("children", []) or [] if p.get("type") == "part"]
        disks.append({"path": d["path"], "size": int(d["size"]), "model": (d.get("model") or "").strip(),
                      "transport": d.get("tran"), "removable": d.get("rm") in (True, "1"),
                      "live": d["path"] == live, "partitions": parts})
    gpu = dict(line.split("=", 1) for line in _run(["yvis-gpu-detect"]).splitlines()
               if "=" in line and not line.startswith("gpu="))
    kernels = sorted(f[len("vmlinuz-"):] for f in os.listdir(os.path.join(source, "boot"))
                     if f.startswith("vmlinuz-")) if os.path.isdir(os.path.join(source, "boot")) else []
    zones = sorted(set(_lines(os.path.join(source, "usr/share/zoneinfo/zone1970.tab"), 2)))
    # only the locales compiled into the system (chapter 8 builds a few)
    archive = os.path.join(source, "usr/lib/locale/locale-archive")
    locales = sorted({re.sub(r"\.utf-?8$", ".UTF-8", l, flags=re.I)
                      for l in _run(["localedef", "--list-archive", archive]).split()
                      if re.search(r"\.utf-?8$", l, re.I)})
    keymaps = sorted({f.split(".")[0] for _, _, files in os.walk(os.path.join(source, "usr/share/keymaps/i386"))
                      for f in files if f.endswith(".map.gz")})
    def has(prog):
        return any(os.access(os.path.join(source, d, prog), os.X_OK) for d in ("usr/bin", "usr/sbin"))
    return {
        "firmware": "uefi" if os.path.isdir("/sys/firmware/efi") else "bios",
        "disks": disks,
        "gpu": {"nvidia": gpu.get("nvidia", "none"), "hybrid": gpu.get("hybrid", "no")},
        "source": source,
        "kernel": kernels[-1] if kernels else None,
        "locales": locales or ["en_US.UTF-8"],
        "keymaps": keymaps or ["us"],
        "timezones": zones or ["UTC"],
        # What the live system can do: the installer offers no more.
        "can": {
            # the initramfs must be able to open the disk, not only the installer
            "encrypt": has("cryptsetup") and os.path.exists(os.path.join(source, "usr/share/yvis/initramfs/luks")),
            "efi": has("mkfs.vfat") or has("mkfs.fat"),
            "sudo": has("sudo"),
            "efibootmgr": has("efibootmgr"),
            "desktops": [d for d in DESKTOPS if os.path.exists(os.path.join(source, "usr/share/yvis/installer/desktop-" + d))],
        },
    }


# ------------------------------------------------------------------ choices

DEFAULTS = {
    "locale": "en_US.UTF-8", "keymap": "us", "timezone": "UTC", "hostname": "yvis",
    "disk": {"mode": "auto", "device": None},
    "desktops": ["kde"], "profile": "desktop", "nvidia": None,
    "user": {"name": "", "fullname": ""},
    "encrypt": False,
}


def _disk(f, path):
    return next((d for d in f["disks"] if d["path"] == path), None)


def _partition(f, path):
    for d in f["disks"]:
        for p in d["partitions"]:
            if p["path"] == path:
                return d, p
    return None, None


def validate(c, f, secrets):
    """Everything wrong with the choices, as {field: message}; empty if none."""
    e = {}
    if c.get("locale") not in f["locales"]:
        e["locale"] = "unknown locale"
    if c.get("keymap") not in f["keymaps"]:
        e["keymap"] = "unknown keyboard layout"
    if c.get("timezone") not in f["timezones"] and c.get("timezone") != "UTC":
        e["timezone"] = "unknown time zone"
    if not HOST_RE.match(c.get("hostname") or ""):
        e["hostname"] = "letters, digits and dashes, up to 63"
    u = c.get("user") or {}
    if not NAME_RE.match(u.get("name") or ""):
        e["user.name"] = "lowercase letters, digits, - and _, starting with a letter"
    elif u["name"] in RESERVED_USERS:
        e["user.name"] = "this name is used by the system"
    if ":" in (u.get("fullname") or "") or "\n" in (u.get("fullname") or ""):
        e["user.fullname"] = "no ':' or line break"
    if len(secrets.get("password") or "") < 1:
        e["user.password"] = "a password is needed"
    if c.get("encrypt"):
        if not f["can"]["encrypt"]:
            e["encrypt"] = "disk encryption is not available on this live system yet"
        elif len(secrets.get("passphrase") or "") < 8:
            e["encrypt.passphrase"] = "at least 8 characters"
    for d in c.get("desktops") or []:
        if d not in DESKTOPS:
            e["desktops"] = f"unknown desktop {d}"
    if c.get("profile") not in PROFILES:
        e["profile"] = "unknown profile"
    if not f.get("kernel"):
        e["system"] = "the live system image has no kernel"
    disk = c.get("disk") or {}
    if f["firmware"] == "uefi" and not f["can"]["efi"]:
        e["disk"] = "this live system cannot create an EFI partition (mkfs.vfat is missing)"
    if disk.get("mode") == "auto":
        d = _disk(f, disk.get("device"))
        if not d:
            e["disk.device"] = "choose a disk"
        elif d["live"]:
            e["disk.device"] = "this is the disk YVIS is running from"
        elif d["size"] < MIN_DISK:
            e["disk.device"] = "the disk is smaller than 16 GiB"
    elif disk.get("mode") == "manual":
        rd, rp = _partition(f, disk.get("root"))
        if not rp:
            e["disk.root"] = "choose the partition for the system"
        elif rd["live"]:
            e["disk.root"] = "this partition is on the disk YVIS is running from"
        elif rp["size"] < MIN_DISK:
            e["disk.root"] = "the partition is smaller than 16 GiB"
        if c.get("encrypt"):
            e["encrypt"] = "encryption needs the whole disk (automatic mode)"
        if f["firmware"] == "uefi":
            ed, ep = _partition(f, disk.get("efi"))
            if not ep:
                e["disk.efi"] = "UEFI needs an EFI system partition"
            elif ep["path"] == disk.get("root"):
                e["disk.efi"] = "the EFI partition and the system partition must differ"
            elif not disk.get("format_efi") and ep.get("fstype") != "vfat":
                e["disk.efi"] = "this partition is not FAT: format it, or choose the existing EFI partition"
        elif not disk.get("bios_disk"):
            # BIOS: GRUB goes to the start of the disk that holds the root
            pass
    else:
        e["disk.mode"] = "choose automatic or manual"
    return e


# ------------------------------------------------------------------ plan

def part_path(disk, n):
    """/dev/sda + 2 -> /dev/sda2; /dev/nvme0n1 + 2 -> /dev/nvme0n1p2."""
    return f"{disk}{'p' if disk[-1].isdigit() else ''}{n}"


def q(s):
    return shlex.quote(str(s))


def heredoc(path, text):
    return f"cat > {q(path)} << 'YVIS_EOF'\n{text.rstrip(chr(10))}\nYVIS_EOF"


def plan(c, f):
    """The installation as [(title, bash script)]. Assumes validate() passed."""
    fw, enc, disk = f["firmware"], bool(c.get("encrypt")), c["disk"]
    kernel, T = f["kernel"], TARGET
    steps = []

    # 1. partitions and file systems
    if disk["mode"] == "auto":
        dev = disk["device"]
        layout = ["label: gpt"]
        n = 0
        if fw == "uefi":
            layout.append(f"size={EFI_SIZE}, type=U, name=YVIS-EFI"); n += 1; efi = part_path(dev, n)
        else:
            layout.append(f"size=1MiB, type={BIOS_BOOT_GUID}, name=YVIS-BIOS"); n += 1; efi = None
        boot = None
        if enc:
            layout.append(f"size={BOOT_SIZE}, type=L, name=YVIS-BOOT"); n += 1; boot = part_path(dev, n)
        layout.append("type=L, name=YVIS-ROOT"); n += 1; root = part_path(dev, n)
        bios_disk = dev
        steps.append(("Partition " + dev, "\n".join([
            f"wipefs --all --force {q(dev)}",
            f"sfdisk --wipe always --wipe-partitions always {q(dev)} << 'YVIS_EOF'",
            *layout, "YVIS_EOF",
            "udevadm settle",
        ])))
        format_efi = efi is not None
    else:
        root, efi, boot = disk["root"], disk.get("efi") if fw == "uefi" else None, None
        format_efi = bool(disk.get("format_efi"))
        bios_disk = disk.get("bios_disk") or _partition(f, root)[0]["path"]
        steps.append(("Check the chosen partitions", "\n".join(
            f"[ -b {q(p)} ] || {{ echo {q(p + ' is not a block device')} >&2; exit 1; }}" for p in [root, efi] if p)))

    fs = []
    root_dev = root
    if enc:
        fs += [f'printf %s "$YVIS_PASSPHRASE" | cryptsetup luksFormat --type luks2 --batch-mode --key-file=- {q(root)}',
               f'printf %s "$YVIS_PASSPHRASE" | cryptsetup open --key-file=- {q(root)} yvis-root']
        root_dev = "/dev/mapper/yvis-root"
    fs.append(f"mkfs.ext4 -F -q -L yvis {q(root_dev)}")
    if boot:
        fs.append(f"mkfs.ext4 -F -q -L yvis-boot {q(boot)}")
    if efi and format_efi:
        fs.append(f"mkfs.vfat -F 32 -n YVIS-EFI {q(efi)}")
    steps.append(("Create the file systems", "\n".join(fs)))

    mounts = [f"mkdir -p {T}", f"mount {q(root_dev)} {T}"]
    if boot:
        mounts += [f"mkdir -p {T}/boot", f"mount {q(boot)} {T}/boot"]
    if efi:
        mounts += [f"mkdir -p {T}/boot/efi", f"mount {q(efi)} {T}/boot/efi"]
    steps.append(("Mount the new system", "\n".join(mounts)))

    # 2. the system itself: a copy of the live system's own image
    steps.append(("Copy the system", "\n".join([
        f"cp -a {q(f['source'])}/. {T}/",
        f"[ -s {T}/boot/vmlinuz-{kernel} ] || {{ echo 'no kernel in the copy' >&2; exit 1; }}",
    ])))

    # 3. configuration
    tz = c["timezone"]
    cfg = [
        'uuid() { blkid -s UUID -o value "$1"; }',
        f'ROOT_UUID=$(uuid {q(root_dev)})',
        "{",
        '  echo "# <file system> <mount point> <type> <options> <dump> <pass>"',
        '  echo "UUID=$ROOT_UUID / ext4 defaults 1 1"',
    ]
    if boot:
        cfg.append(f'  echo "UUID=$(uuid {q(boot)}) /boot ext4 defaults 1 2"')
    if efi:
        cfg.append(f'  echo "UUID=$(uuid {q(efi)}) /boot/efi vfat umask=0077 0 2"')
    cfg += [f"}} > {T}/etc/fstab"]
    if enc:
        cfg.append(f'echo "yvis-root UUID=$(uuid {q(root)}) none luks" > {T}/etc/crypttab')
    cfg += [
        f"echo {q(c['hostname'])} > {T}/etc/hostname",
        heredoc(f"{T}/etc/hosts", f"127.0.0.1 localhost\n127.0.1.1 {c['hostname']}\n::1 localhost"),
        f"echo LANG={q(c['locale'])} > {T}/etc/locale.conf",
        f"sed -i '/^KEYMAP=/d' {T}/etc/vconsole.conf && echo KEYMAP={q(c['keymap'])} >> {T}/etc/vconsole.conf",
        f"ln -sfn ../usr/share/zoneinfo/{tz} {T}/etc/localtime" if tz != "UTC" else f"ln -sfn ../usr/share/zoneinfo/UTC {T}/etc/localtime",
        # a new identity: systemd creates it at the first start
        f": > {T}/etc/machine-id",
    ]
    steps.append(("Configure the system", "\n".join(cfg)))

    # 4. the user
    u = c["user"]
    user = [
        # rslave: unmounting them at the end must not unmount the live system's own
        f"for d in dev proc sys run; do mount --rbind /$d {T}/$d && mount --make-rslave {T}/$d; done",
        f"chroot {T} useradd -m -s /bin/bash -G {','.join(USER_GROUPS)} -c {q(u.get('fullname') or u['name'])} {q(u['name'])}",
        f'printf "%s:%s\\n" {q(u["name"])} "$YVIS_PASSWORD" | chroot {T} chpasswd',
    ]
    if f["can"]["sudo"]:
        user += [f"install -d -m 750 {T}/etc/sudoers.d",
                 heredoc(f"{T}/etc/sudoers.d/10-yvis-wheel", "%wheel ALL=(ALL:ALL) ALL"),
                 f"chmod 440 {T}/etc/sudoers.d/10-yvis-wheel",
                 f"chroot {T} passwd -l root"]
    else:
        # no sudo on this system yet: root is administered with the same password
        user.append(f'printf "root:%s\\n" "$YVIS_PASSWORD" | chroot {T} chpasswd')
    steps.append((f"Create the user {u['name']}", "\n".join(user)))

    # 5. software chosen (desktops, profile, NVIDIA), recorded for Yone
    choice = {"desktops": c.get("desktops") or [], "profile": c["profile"],
              "nvidia": bool(c.get("nvidia")), "installed-from": "live ISO"}
    steps.append(("Record the choices", "\n".join([
        f"install -d {T}/etc/yvis",
        heredoc(f"{T}/etc/yvis/install.json", json.dumps(choice, indent=2, sort_keys=True)),
    ])))

    # 6. boot loader
    kpath = "" if boot else "/boot"
    cmdline = f"root=UUID=$ROOT_UUID rw quiet" if not enc else "root=/dev/mapper/yvis-root rw quiet"
    grub_cfg = "\n".join([
        "set timeout=3",
        "set default=0",
        "search --no-floppy --fs-uuid --set=root $BOOT_UUID",
        'menuentry "YVIS" {',
        f"  linux {kpath}/vmlinuz-{kernel} {cmdline}",
        f"  initrd {kpath}/initramfs-{kernel}.img",
        "}",
        'menuentry "YVIS (safe graphics)" {',
        f"  linux {kpath}/vmlinuz-{kernel} {cmdline} nomodeset",
        f"  initrd {kpath}/initramfs-{kernel}.img",
        "}",
    ])
    bl = [
        'uuid() { blkid -s UUID -o value "$1"; }',
        f"ROOT_UUID=$(uuid {q(root_dev)})",
        f"BOOT_UUID=$(uuid {q(boot or root_dev)})",
        f"install -d {T}/boot/grub",
        # unquoted delimiter: the UUIDs are filled in now
        f"cat > {T}/boot/grub/grub.cfg << YVIS_EOF\n{grub_cfg}\nYVIS_EOF",
    ]
    if fw == "uefi":
        # The removable path (EFI/BOOT/BOOTX64.EFI) starts on every firmware
        # without a boot entry; a named entry is added when efibootmgr exists.
        bl.append(f"chroot {T} grub-install --target=x86_64-efi --efi-directory=/boot/efi --boot-directory=/boot --removable --no-nvram")
        if f["can"]["efibootmgr"]:
            bl.append(f"chroot {T} grub-install --target=x86_64-efi --efi-directory=/boot/efi --boot-directory=/boot --bootloader-id=YVIS")
    else:
        bl.append(f"chroot {T} grub-install --target=i386-pc --boot-directory=/boot {q(bios_disk)}")
    steps.append(("Install the boot loader", "\n".join(bl)))

    steps.append(("Finish", "\n".join([
        "sync",
        f"umount -R {T}",
        "[ ! -e /dev/mapper/yvis-root ] || cryptsetup close yvis-root" if enc else "true",
    ])))
    return steps


def summary(c, f):
    """What will happen, for the last screen before writing: rows of
    {label, value, step, danger}; danger rows are what gets erased."""
    disk = c["disk"]
    rows = []
    if disk["mode"] == "auto":
        d = _disk(f, disk["device"])
        rows.append({"label": "Erased", "danger": True, "step": "disk",
                     "value": f"The whole disk {d['path']} ({d['model'] or 'disk'}, {d['size'] / 1e9:.0f} GB): everything on it is lost"})
        layout = "EFI partition 1 GB, " if f["firmware"] == "uefi" else ""
        layout += "/boot 1 GB, encrypted system on the rest" if c.get("encrypt") else "system on the rest"
        rows.append({"label": "Layout", "value": layout, "step": "disk"})
    else:
        rows.append({"label": "Formatted", "danger": True, "step": "disk",
                     "value": f"{disk['root']}, for the system: everything on it is lost"})
        if disk.get("efi"):
            rows.append({"label": "EFI partition", "step": "disk", "danger": bool(disk.get("format_efi")),
                         "value": disk["efi"] + (": formatted" if disk.get("format_efi") else ", kept as it is (shared with the other system)")})
    rows += [
        {"label": "Start-up", "step": "disk",
         "value": f"{f['firmware'].upper()}, GRUB" + (", disk encrypted (passphrase at every start)" if c.get("encrypt") else "")},
        {"label": "Region", "step": "region", "value": f"{c['locale']} · keyboard {c['keymap']} · {c['timezone']}"},
        {"label": "Account", "step": "account",
         "value": f"{c['user']['name']} on {c['hostname']}" + (", administrator with sudo" if f["can"]["sudo"] else ", root has the same password")},
    ]
    desk = [DESKTOPS[d] for d in c.get("desktops") or []]
    missing = [DESKTOPS[d] for d in c.get("desktops") or [] if d not in f["can"]["desktops"]]
    soft = f"{' and '.join(desk) or 'No desktop (console)'} · {PROFILES[c['profile']]}" + (" · NVIDIA driver" if c.get("nvidia") else "")
    if missing:
        soft += f" ({' and '.join(missing)}: installed later with Yone, not on this live system yet)"
    rows.append({"label": "Software", "step": "software", "value": soft})
    for r in rows:
        r.setdefault("danger", False)
    return rows


# ------------------------------------------------------------------ run

def run(steps, secrets, log, dry_run=False, pace=0.0):
    """Run the steps in order; log(event) receives progress. Stops at the
    first failure and returns False."""
    env = dict(os.environ, YVIS_PASSWORD=secrets.get("password", ""),
               YVIS_PASSPHRASE=secrets.get("passphrase", ""), LC_ALL="C")
    for i, (title, script) in enumerate(steps):
        log({"step": i, "title": title, "state": "running"})
        if dry_run:
            for line in script.splitlines():
                log({"step": i, "line": line})
            time.sleep(pace)  # --demo: slow enough to be watched
            log({"step": i, "state": "done"})
            continue
        p = subprocess.Popen(["bash", "-euo", "pipefail", "-c", script], env=env,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for line in p.stdout:
            log({"step": i, "line": line.rstrip("\n")})
        if p.wait() != 0:
            log({"step": i, "state": "failed", "status": p.returncode})
            return False
        log({"step": i, "state": "done"})
    return True
