#!/usr/bin/env python3
"""Check the packaged authentication test build before publishing an artifact."""

import argparse
import io
from pathlib import Path
import plistlib
import subprocess
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parents[2]


def check_archive(archive):
    names = archive.namelist()
    if not names or len(names) != len(set(names)):
        raise ValueError("Archive is empty or contains duplicate entries")
    corrupt_member = archive.testzip()
    if corrupt_member is not None:
        raise ValueError(f"Corrupt ZIP member: {corrupt_member}")


def check_bundle(archive, bundle, expected_id, expected_version, entitlements_file):
    info = plistlib.loads(archive.read(f"{bundle}/Info.plist"))
    for key, expected in (
        ("CFBundleIdentifier", expected_id),
        ("CFBundleShortVersionString", expected_version),
    ):
        if info.get(key) != expected:
            raise ValueError(f"{bundle}: {key} is {info.get(key)!r}, expected {expected!r}")
    if not info.get("CFBundleVersion"):
        raise ValueError(f"{bundle}: missing build number")
    executable = info.get("CFBundleExecutable")
    if not isinstance(executable, str) or not executable or "/" in executable:
        raise ValueError(f"{bundle}: invalid executable name")
    binary = archive.read(f"{bundle}/{executable}")
    if not binary:
        raise ValueError(f"{bundle}: empty executable")

    with tempfile.TemporaryDirectory(prefix="sidestore-ipa-check-") as temporary:
        binary_path = Path(temporary) / "executable"
        binary_path.write_bytes(binary)
        architectures = subprocess.check_output(
            ["xcrun", "lipo", "-archs", str(binary_path)], text=True
        ).split()
        if "arm64" not in architectures:
            raise ValueError(f"{bundle}: executable does not contain arm64: {architectures}")
        actual_entitlements = plistlib.loads(
            subprocess.check_output(["ldid", "-e", str(binary_path)])
        )

    with (ROOT / entitlements_file).open("rb") as source:
        expected_entitlements = plistlib.load(source)
    if actual_entitlements != expected_entitlements:
        raise ValueError(f"{bundle}: embedded entitlements differ from {entitlements_file}")
    print(f"Verified {bundle}: {expected_id}, version {expected_version}, arm64, entitlements")


def verify_ipa(ipa_path, expected_version):
    if not ipa_path.is_file() or ipa_path.stat().st_size == 0:
        raise ValueError(f"Missing or empty IPA: {ipa_path}")
    with zipfile.ZipFile(ipa_path) as archive:
        check_archive(archive)
        main_bundle = "Payload/SideStore.app"
        check_bundle(
            archive,
            main_bundle,
            "com.SideStore.SideStore",
            expected_version,
            "AltStore/Resources/ReleaseEntitlements.plist",
        )
        check_bundle(
            archive,
            f"{main_bundle}/PlugIns/AltWidgetExtension.appex",
            "com.SideStore.SideStore.AltWidget",
            expected_version,
            "AltWidget/Resources/ReleaseEntitlements.plist",
        )
        with (ROOT / "SideBackup/Info.plist").open("rb") as source:
            backup_version = plistlib.load(source)["CFBundleShortVersionString"]
        with zipfile.ZipFile(io.BytesIO(archive.read(f"{main_bundle}/SideBackup.ipa"))) as backup:
            check_archive(backup)
            check_bundle(
                backup,
                "Payload/SideBackup.app",
                "com.SideStore.SideStore.SideBackup",
                backup_version,
                "SideBackup/SideBackup.entitlements",
            )
    print(f"Verified IPA: {ipa_path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("version")
    args = parser.parse_args()
    verify_ipa(args.ipa, args.version)


if __name__ == "__main__":
    main()
