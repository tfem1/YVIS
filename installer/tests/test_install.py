"""Tests of the installation engine: choices -> checks -> commands.

    python3 -m unittest discover -s installer/tests
"""
import copy
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import graveyard_install as yi  # noqa: E402

FACTS = {
    "firmware": "uefi",
    "disks": [
        {"path": "/dev/nvme0n1", "size": 512 * 10**9, "model": "SSD", "transport": "nvme", "removable": False,
         "live": False, "partitions": [
             {"path": "/dev/nvme0n1p1", "size": 10**8, "fstype": "vfat", "label": None, "type": "EFI System"},
             {"path": "/dev/nvme0n1p2", "size": 200 * 10**9, "fstype": "ntfs", "label": "Windows", "type": None},
             {"path": "/dev/nvme0n1p3", "size": 300 * 10**9, "fstype": None, "label": None, "type": None}]},
        {"path": "/dev/sda", "size": 32 * 10**9, "model": "stick", "transport": "usb", "removable": True,
         "live": True, "partitions": [{"path": "/dev/sda1", "size": 32 * 10**9, "fstype": "exfat", "label": "Ventoy", "type": None}]},
        {"path": "/dev/sdb", "size": 8 * 10**9, "model": "small", "transport": "sata", "removable": False,
         "live": False, "partitions": []},
    ],
    "gpu": {"nvidia": "open", "hybrid": "no"},
    "source": "/run/graveyard/system", "kernel": "7.1.8-graveyard",
    "locales": ["en_US.UTF-8", "fr_FR.UTF-8"], "keymaps": ["us", "fr"], "timezones": ["Europe/Paris", "UTC"],
    "can": {"encrypt": True, "efi": True, "sudo": True, "efibootmgr": False, "desktops": []},
}
CHOICES = dict(copy.deepcopy(yi.DEFAULTS), disk={"mode": "auto", "device": "/dev/nvme0n1"},
               user={"name": "elodie", "fullname": "Élodie Martin"}, timezone="Europe/Paris", keymap="fr")
SECRETS = {"password": "pw"}


def script(steps):
    return "\n".join(s for _, s in steps)


class Validate(unittest.TestCase):
    def errors(self, facts=FACTS, secrets=SECRETS, **changes):
        c = copy.deepcopy(CHOICES)
        c.update(changes)
        return yi.validate(c, facts, secrets)

    def test_good_choices_pass(self):
        self.assertEqual(self.errors(), {})

    def test_never_the_live_disk(self):
        self.assertIn("disk.device", self.errors(disk={"mode": "auto", "device": "/dev/sda"}))

    def test_disk_too_small(self):
        self.assertIn("disk.device", self.errors(disk={"mode": "auto", "device": "/dev/sdb"}))

    def test_bad_user_names(self):
        for name in ["", "Root", "root", "9lives", "a b", "x" * 33]:
            self.assertIn("user.name", self.errors(user={"name": name, "fullname": ""}), name)

    def test_password_needed(self):
        self.assertIn("user.password", self.errors(secrets={}))

    def test_encryption_needs_support_and_passphrase(self):
        self.assertIn("encrypt.passphrase", self.errors(encrypt=True))
        no = dict(FACTS, can=dict(FACTS["can"], encrypt=False))
        self.assertIn("encrypt", self.errors(facts=no, encrypt=True, secrets={"password": "pw", "passphrase": "x" * 10}))

    def test_manual_needs_efi_on_uefi(self):
        e = self.errors(disk={"mode": "manual", "root": "/dev/nvme0n1p3"})
        self.assertIn("disk.efi", e)
        e = self.errors(disk={"mode": "manual", "root": "/dev/nvme0n1p3", "efi": "/dev/nvme0n1p1"})
        self.assertEqual(e, {})

    def test_manual_refuses_a_non_fat_efi_partition_unless_formatted(self):
        d = {"mode": "manual", "root": "/dev/nvme0n1p3", "efi": "/dev/nvme0n1p2"}
        self.assertIn("disk.efi", self.errors(disk=d))
        self.assertEqual(self.errors(disk=dict(d, format_efi=True)), {})


class Plan(unittest.TestCase):
    def test_auto_uefi(self):
        s = script(yi.plan(CHOICES, FACTS))
        self.assertIn("size=1GiB, type=U, name=GRAVE-EFI", s)
        self.assertIn("mkfs.vfat -F 32 -n GRAVE-EFI /dev/nvme0n1p1", s)
        self.assertIn("mkfs.ext4 -F -q -L graveyard /dev/nvme0n1p2", s)
        self.assertIn("grub-install --target=x86_64-efi --efi-directory=/boot/efi --boot-directory=/boot --removable --no-nvram", s)
        self.assertIn("ln -sfn ../usr/share/zoneinfo/Europe/Paris", s)
        self.assertIn("KEYMAP=fr", s)
        self.assertIn("-c 'Élodie Martin' elodie", s)
        self.assertNotIn("cryptsetup", s)

    def test_auto_bios(self):
        s = script(yi.plan(CHOICES, dict(FACTS, firmware="bios")))
        self.assertIn(f"type={yi.BIOS_BOOT_GUID}", s)
        # the BIOS boot partition GUID ("Hah!IdontNeedEFI"): GRUB embeds
        # itself there and refuses to install without it
        self.assertEqual(yi.BIOS_BOOT_GUID, "21686148-6449-6E6F-744E-656564454649")
        self.assertNotIn("mkfs.vfat", s)
        self.assertIn("grub-install --target=i386-pc --boot-directory=/boot /dev/nvme0n1", s)

    def test_manual_keeps_the_efi_partition(self):
        c = dict(CHOICES, disk={"mode": "manual", "root": "/dev/nvme0n1p3", "efi": "/dev/nvme0n1p1"})
        s = script(yi.plan(c, FACTS))
        self.assertNotIn("sfdisk", s)
        self.assertNotIn("wipefs", s)
        self.assertNotIn("mkfs.vfat", s)  # Windows boots from it
        self.assertIn("mkfs.ext4 -F -q -L graveyard /dev/nvme0n1p3", s)

    def test_encrypted_root_has_a_plain_boot(self):
        s = script(yi.plan(dict(CHOICES, encrypt=True), FACTS))
        self.assertIn("cryptsetup luksFormat --type luks2 --batch-mode --key-file=- /dev/nvme0n1p3", s)
        self.assertIn("mount /dev/nvme0n1p2 /mnt/graveyard-target/boot", s)
        self.assertIn("root=/dev/mapper/graveyard-root", s)

    def test_secrets_never_in_the_commands(self):
        secret = "hunter2-very-secret"
        c = dict(CHOICES, encrypt=True)
        s = script(yi.plan(c, FACTS))
        self.assertNotIn(secret, s)
        self.assertIn('"$GRAVEYARD_PASSWORD"', s)
        self.assertIn('"$GRAVEYARD_PASSPHRASE"', s)

    def test_nvme_partition_names(self):
        self.assertEqual(yi.part_path("/dev/nvme0n1", 2), "/dev/nvme0n1p2")
        self.assertEqual(yi.part_path("/dev/sda", 2), "/dev/sda2")
        self.assertEqual(yi.part_path("/dev/mmcblk0", 1), "/dev/mmcblk0p1")

    def test_shell_metacharacters_are_quoted(self):
        c = dict(CHOICES, user={"name": "elodie", "fullname": "Bob'; rm -rf / #"})
        s = script(yi.plan(c, FACTS))
        self.assertIn("""-c 'Bob'"'"'; rm -rf / #' elodie""", s)

    def test_scripts_are_valid_bash(self):
        import subprocess
        for f in [FACTS, dict(FACTS, firmware="bios")]:
            for enc in [False, True]:
                for title, body in yi.plan(dict(CHOICES, encrypt=enc), f):
                    r = subprocess.run(["bash", "-n"], input=body, text=True, capture_output=True)
                    self.assertEqual(r.returncode, 0, f"{title}: {r.stderr}")

    def test_dry_run_runs_nothing(self):
        events = []
        self.assertTrue(yi.run(yi.plan(CHOICES, FACTS), SECRETS, events.append, dry_run=True))
        self.assertTrue(any(e.get("line", "").startswith("wipefs") for e in events))


class Summary(unittest.TestCase):
    def test_says_what_is_erased(self):
        s = yi.summary(CHOICES, FACTS)
        self.assertTrue(s[0]["danger"])
        self.assertIn("The whole disk /dev/nvme0n1", s[0]["value"])
        self.assertFalse(any(r["danger"] for r in s[1:]))

    def test_manual_keeps_windows_efi_not_danger(self):
        c = dict(CHOICES, disk={"mode": "manual", "root": "/dev/nvme0n1p3", "efi": "/dev/nvme0n1p1"})
        rows = yi.summary(c, FACTS)
        self.assertEqual([r["label"] for r in rows if r["danger"]], ["Formatted"])


if __name__ == "__main__":
    unittest.main()
