#!/usr/bin/env python3
"""
Seed hermit UserDefaults for the ad-hoc debug build from config/hermit.yaml.

Ad-hoc signed macOS apps (sandbox disabled) read UserDefaults from
~/Library/Preferences/<bundle-id>.plist rather than from the sandbox container.
This script writes legacy keys AND hermit.accounts / hermit.repositories JSON
so the app has fully-populated stores on first launch without prompting.

Usage:
    python3 scripts/seed-native-prefs.py <bundle-id> [config/hermit.yaml] [--token TOKEN]
"""

import json
import plistlib
import os
import re
import sys
import uuid

# Fixed dev UUIDs — stable across runs so UserDefaults data is idempotent.
DEV_ACCOUNT_ID = "00000000-0000-0000-0000-000000000001"
DEV_REPO_ID    = "00000000-0000-0000-0000-000000000002"

def main():
    if len(sys.argv) < 2:
        print("Usage: seed-native-prefs.py <bundle-id> [config/hermit.yaml] [--token TOKEN]", file=sys.stderr)
        sys.exit(1)

    bundle_id = sys.argv[1]
    cfg_path  = "config/hermit.yaml"
    token_override = None

    args = sys.argv[2:]
    i = 0
    while i < len(args):
        if args[i] == "--token" and i + 1 < len(args):
            token_override = args[i + 1]
            i += 2
        elif not args[i].startswith("--"):
            cfg_path = args[i]
            i += 1
        else:
            i += 1

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
            base_url = m.group(2).strip()
            break

    # Strip trailing /api/v1 for the account endpoint — that's the Gitea host URL.
    account_endpoint = base_url.rstrip("/")
    if account_endpoint.endswith("/api/v1"):
        account_endpoint = account_endpoint[:-len("/api/v1")]

    # Try to read the token from the DevConfig gitea-token-export.sh
    token = token_override or ""
    if not token:
        token_path = "hermit-native/HermitNative/DevConfig/gitea-token-export.sh"
        if os.path.exists(token_path):
            m = re.search(r"GITEA_TOKEN=(\S+)", open(token_path).read())
            if m:
                token = m.group(1).strip()

    # Build hermit.accounts JSON (debug builds store token inline)
    accounts = [
        {
            "id":       DEV_ACCOUNT_ID,
            "name":     "Default (Gitea)",
            "endpoint": account_endpoint,
            "token":    token,
        }
    ]

    # Build hermit.repositories JSON
    repositories = [
        {
            "id":        DEV_REPO_ID,
            "accountID": DEV_ACCOUNT_ID,
            "owner":     owner,
            "name":      name,
            "docsPath":  docs,
            "rfcLabel":  "hermit:rfc-ready",
        }
    ]

    plist_path = os.path.expanduser(f"~/Library/Preferences/{bundle_id}.plist")
    d = plistlib.load(open(plist_path, "rb")) if os.path.exists(plist_path) else {}
    d.update({
        # Legacy keys (used by GiteaAutoConfig / migration path)
        "hermit.baseURL":       base_url + "/",
        "hermit.serverBaseURL": "http://localhost:8080",
        "hermit.repoOwner":     owner,
        "hermit.repoName":      name,
        "hermit.docsPath":      docs,
        "hermit.rfcLabel":      "hermit:rfc-ready",
        "hermit.serverMode":    '{"type":"embeddedLocal"}',
        # New store keys
        "hermit.accounts":      json.dumps(accounts).encode(),
        "hermit.repositories":  json.dumps(repositories).encode(),
    })
    plistlib.dump(d, open(plist_path, "wb"))
    print(f"Seeded UserDefaults for {bundle_id}")
    print(f"  account:  {account_endpoint} (token: {token[:8]}…)" if token else f"  account:  {account_endpoint} (no token)")
    print(f"  repo:     {owner}/{name} @ {docs}")

if __name__ == "__main__":
    main()
