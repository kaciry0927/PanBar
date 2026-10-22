#!/usr/bin/env python3
"""Fix the macOS 26 (Tahoe) StatusKit "menu bar allow-list" block for PanBar.

macOS 26 keeps a per-bundle-ID allow-list for third-party menu bar items in:

  ~/Library/Group Containers/group.com.apple.controlcenter/
      Library/Preferences/group.com.apple.controlcenter.plist

The `trackedApplications` key contains a nested binary plist.  When an app is
blocked, ControlCenter logs:

  [com.apple.controlcenter:appStatusItems] Moving host to blocked list; ...

and the app's NSStatusBarWindow stays at (0, -22, ..., 22) with screen == nil.
Changing the bundle ID, recreating the status item, or restarting ControlCenter
does not clear the state.  This script:

  1. sets `isAllowed = True` on the entry for the given bundle ID, and
  2. removes that bundle ID from *other* apps' `menuItemLocations` lists
     (a stale parent mapping, e.g. WorkBuddy, can keep the item blocked), then
  3. restarts cfprefsd/ControlCenter so the new state is loaded.

The file is protected by com.apple.macl, so this must run as root:

  sudo python3 scripts/fix-menubar-allowlist.py app.panbar.PanBar.dev3

A backup is written to /tmp before any change.  You can inspect what would
happen first with --dry-run.  Use --no-restart if you want to restart
ControlCenter yourself.

Official alternative (try this first):
  System Settings -> Control Center -> Menu Bar -> allow PanBar Dev.

After running this script, relaunch PanBar from Finder or a normal Terminal:

  pkill -f 'PanBar-Dev.app/Contents/MacOS' || true
  open /path/to/PanBar-Dev.app

Do NOT launch the binary directly from an IDE/AI terminal: macOS attributes the
status item to the parent app and may block it again.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import os
import plistlib
import pwd
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Iterator

DEFAULT_BUNDLE_ID = "app.panbar.PanBar.dev3"
PLIST_RELATIVE = (
    "Library/Group Containers/group.com.apple.controlcenter/"
    "Library/Preferences/group.com.apple.controlcenter.plist"
)


def invoking_user_home() -> Path | None:
    """Return the real user's home even when the script runs under sudo."""
    sudo_user = os.environ.get("SUDO_USER")
    if sudo_user:
        try:
            return Path(pwd.getpwnam(sudo_user).pw_dir)
        except KeyError:
            return None
    home = os.environ.get("HOME")
    return Path(home) if home else None


def iter_dicts(obj: Any) -> Iterator[dict[str, Any]]:
    if isinstance(obj, dict):
        yield obj
        for value in obj.values():
            yield from iter_dicts(value)
    elif isinstance(obj, list):
        for value in obj:
            yield from iter_dicts(value)


def entry_bundle(entry: dict[str, Any]) -> str | None:
    """The bundle ID an allow-list entry belongs to."""
    location = entry.get("location")
    if isinstance(location, dict):
        bundle = location.get("bundle")
        if isinstance(bundle, dict):
            value = bundle.get("_0")
            if isinstance(value, str):
                return value
    return None


def object_mentions_bundle(obj: Any, bundle_id: str) -> bool:
    """True if a menuItemLocations node refers to bundle_id."""
    if isinstance(obj, dict):
        bundle = obj.get("bundle")
        if isinstance(bundle, dict) and bundle.get("_0") == bundle_id:
            return True
        return any(object_mentions_bundle(v, bundle_id) for v in obj.values())
    if isinstance(obj, list):
        return any(object_mentions_bundle(v, bundle_id) for v in obj)
    return False


def load_plist(path: Path) -> dict[str, Any]:
    with path.open("rb") as handle:
        data = plistlib.load(handle)
    if not isinstance(data, dict):
        raise SystemExit(f"Unexpected plist root type: {type(data)!r}")
    return data


def decode_tracked_applications(data: dict[str, Any]) -> tuple[Any, Any]:
    raw = data.get("trackedApplications")
    if raw is None:
        raise SystemExit(
            "No `trackedApplications` key found. Has the app ever created a "
            "status item? Launch it once, then retry."
        )
    if isinstance(raw, (bytes, bytearray)):
        inner = plistlib.loads(bytes(raw))
    elif isinstance(raw, (list, dict)):
        inner = raw
    else:
        raise SystemExit(f"Unexpected trackedApplications type: {type(raw)!r}")
    return raw, inner


def patch_allowlist(
    data: dict[str, Any], bundle_id: str
) -> tuple[int, int, bool]:
    """Patch in place. Returns (entries_allowed, mappings_removed, found)."""
    _, inner = decode_tracked_applications(data)

    allowed = 0
    found = False
    for entry in iter_dicts(inner):
        if entry_bundle(entry) != bundle_id:
            continue
        found = True
        if "isAllowed" in entry:
            if entry.get("isAllowed") is not True:
                entry["isAllowed"] = True
                allowed += 1

    removed = 0
    for entry in iter_dicts(inner):
        if entry_bundle(entry) == bundle_id:
            continue  # don't scrub the app's own mapping
        locations = entry.get("menuItemLocations")
        if not isinstance(locations, list):
            continue
        kept = [item for item in locations if not object_mentions_bundle(item, bundle_id)]
        if len(kept) != len(locations):
            removed += len(locations) - len(kept)
            entry["menuItemLocations"] = kept

    if found:
        data["trackedApplications"] = plistlib.dumps(inner, fmt=plistlib.FMT_BINARY)
    return allowed, removed, found


def write_plist_preserving_inode(path: Path, data: dict[str, Any]) -> None:
    """Write via the existing inode so com.apple.macl / ownership survive."""
    fd, tmp_name = tempfile.mkstemp(prefix="panbar-cc-", suffix=".plist")
    os.close(fd)
    tmp = Path(tmp_name)
    try:
        with tmp.open("wb") as handle:
            plistlib.dump(data, handle, fmt=plistlib.FMT_BINARY)
        # copyfile opens the destination and truncates it: this keeps the
        # destination inode (and thus its MACL) instead of replacing it.
        shutil.copyfile(tmp, path)
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


def restart_control_center() -> None:
    print("→ restarting cfprefsd / ControlCenter ...")
    subprocess.run(["killall", "cfprefsd"], check=False)
    time.sleep(0.5)
    result = subprocess.run(
        ["pgrep", "-x", "ControlCenter"], capture_output=True, text=True
    )
    for line in result.stdout.split():
        try:
            os.kill(int(line), signal.SIGKILL)
        except (ProcessLookupError, ValueError):
            pass
    # ControlCenter is relaunched automatically by launchd.
    time.sleep(1.0)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Unblock a macOS 26 StatusKit menu bar item for a bundle ID."
    )
    parser.add_argument(
        "bundle_id",
        nargs="?",
        default=DEFAULT_BUNDLE_ID,
        help=f"bundle ID to unblock (default: {DEFAULT_BUNDLE_ID})",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="show what would change without writing or restarting",
    )
    parser.add_argument(
        "--no-restart",
        action="store_true",
        help="patch the plist but do not restart cfprefsd/ControlCenter",
    )
    parser.add_argument(
        "--path",
        help=argparse.SUPPRESS,  # for tests: use an explicit plist path
    )
    args = parser.parse_args()

    explicit_path = Path(args.path).expanduser() if args.path else None
    if explicit_path is None and os.geteuid() != 0:
        print(
            "This script must run as root (the allow-list plist is com.apple.macl protected).\n"
            f"  sudo python3 {sys.argv[0]} {args.bundle_id}\n"
            "Or use System Settings -> Control Center -> Menu Bar instead.",
            file=sys.stderr,
        )
        return 2

    if explicit_path is not None:
        plist_path = explicit_path
    else:
        home = invoking_user_home()
        if home is None:
            print("Cannot determine the invoking user's home (SUDO_USER/HOME).", file=sys.stderr)
            return 2
        plist_path = home / PLIST_RELATIVE

    if not plist_path.exists():
        print(f"Plist not found: {plist_path}", file=sys.stderr)
        return 2

    print(f"bundle ID : {args.bundle_id}")
    print(f"plist     : {plist_path}")

    data = load_plist(plist_path)
    allowed, removed, found = patch_allowlist(data, args.bundle_id)

    if not found:
        print(
            f"✗ No allow-list entry for {args.bundle_id} was found.\n"
            "  Launch the app once (it creates the entry), quit it, then rerun.\n"
            "  If the app is currently blocked, see docs/TROUBLESHOOTING.md §6.",
            file=sys.stderr,
        )
        return 1

    print(f"  isAllowed changed : {allowed}")
    print(f"  stale mappings    : {removed}")

    if args.dry_run:
        print("✓ dry-run: nothing written, ControlCenter not restarted")
        return 0

    stamp = _dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = Path(f"/tmp/group.com.apple.controlcenter.plist.bak-{stamp}")
    shutil.copy2(plist_path, backup)
    print(f"  backup            : {backup}")

    write_plist_preserving_inode(plist_path, data)

    # Preserve the invoking user's ownership and mode 0600.
    if explicit_path is None:
        sudo_user = os.environ.get("SUDO_USER")
        try:
            pw = pwd.getpwnam(sudo_user) if sudo_user else None
        except KeyError:
            pw = None
        if pw is not None:
            os.chown(plist_path, pw.pw_uid, pw.pw_gid)
    os.chmod(plist_path, 0o600)
    print("✓ allow-list patched")

    if not args.no_restart:
        restart_control_center()
        print("✓ ControlCenter restarted")

    print(
        "\nNext: relaunch PanBar from Finder or a normal Terminal (not an IDE terminal):\n"
        "  pkill -f 'PanBar-Dev.app/Contents/MacOS' || true\n"
        "  open /path/to/PanBar-Dev.app\n"
        "Then check: System Settings -> Control Center -> Menu Bar."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
