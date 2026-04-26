#!/usr/bin/env python3
"""
Seed hermit UserDefaults for the ad-hoc debug build from config/hermit.yaml.

Ad-hoc signed macOS apps (TeamIdentifier=not set) read UserDefaults from
~/Library/Preferences/<bundle-id>.plist rather than from the sandbox container.
This script writes the config values there so the app doesn't prompt for the
repo folder on every launch.

Usage:
    python3 scripts/seed-native-prefs.py <bundle-id> [config/hermit.yaml]
"""

import plistlib
import os
import re
import sys

def main():
    if len(sys.argv) < 2:
        print("Usage: seed-native-prefs.py <bundle-id> [config/hermit.yaml]", file=sys.stderr)
        sys.exit(1)

    bundle_id = sys.argv[1]
    cfg_path  = sys.argv[2] if len(sys.argv) > 2 else "config/hermit.yaml"

    if not os.path.exists(cfg_path):
        print(f"Warning: {cfg_path} not found — skipping pref seed")
        sys.exit(0)

    cfg = open(cfg_path).read()

    def first(pattern, default=""):
        m = re.search(pattern, cfg, re.MULTILINE)
        return m.group(1).strip() if m else default

    owner    = first(r"^  - owner:\s+(.+)")
    name     = first(r"^    name:\s+(.+)")
    docs     = first(r"^    docs_path_policy:\s+(.+)", "docs-cms/rfcs").rstrip("/")
    registry = first(r"^    registry:\s+(.+)", "gitea-local")

    # Find the base_url for the registry used by the first repo
    base_url = ""
    for m in re.finditer(r"- name: (.+)\n    kind:.*\n    base_url: (.+)", cfg):
        if m.group(1).strip() == registry:
            base_url = m.group(2).strip() + "/"
            break

    plist_path = os.path.expanduser(f"~/Library/Preferences/{bundle_id}.plist")
    d = plistlib.load(open(plist_path, "rb")) if os.path.exists(plist_path) else {}
    d.update({
        "hermit.baseURL":       base_url,
        "hermit.serverBaseURL": "http://localhost:8080",
        "hermit.repoOwner":     owner,
        "hermit.repoName":      name,
        "hermit.docsPath":      docs,
        "hermit.rfcLabel":      "hermit:rfc-ready",
        "hermit.serverMode":    '{"type":"embeddedLocal"}',
    })
    plistlib.dump(d, open(plist_path, "wb"))
    print(f"Seeded UserDefaults for {bundle_id} (owner={owner} repo={name} baseURL={base_url})")

if __name__ == "__main__":
    main()
