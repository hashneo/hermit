#!/usr/bin/env python3
"""Regression tests for scripts/seed-native-prefs.py.

These tests intentionally use a temporary HOME and the real preference seeder so
CI covers the same merge behavior used by `make native-seed-prefs`.
"""

import json
import os
import plistlib
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
BUNDLE_ID = "com.test.hermit-native"
NAMESPACE = uuid.UUID("9df7786a-6338-4bd4-bebb-3f225c005a6a")


def stable_uuid(kind, key):
    return str(uuid.uuid5(NAMESPACE, f"{kind}:{key}"))


def read_json_pref(plist, key):
    value = plist[key]
    if isinstance(value, bytes):
        value = value.decode()
    return json.loads(value)


def run_seed(temp_home):
    env = os.environ.copy()
    env["HOME"] = str(temp_home)
    subprocess.run(
        [
            sys.executable,
            str(REPO_ROOT / "scripts" / "seed-native-prefs.py"),
            BUNDLE_ID,
            "config/hermit.yaml",
            "--repos-json",
            "config/hermit-repos.meridian.json",
        ],
        cwd=REPO_ROOT,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    )


def test_preserves_settings_added_repository():
    with tempfile.TemporaryDirectory() as raw_home:
        home = Path(raw_home)
        prefs_dir = home / "Library" / "Preferences"
        prefs_dir.mkdir(parents=True)
        prefs_path = prefs_dir / f"{BUNDLE_ID}.plist"

        github_account_id = stable_uuid("account", "github")
        settings_repo = {
            "id": stable_uuid("repo", "settings/jrepp/merge-god"),
            "accountID": github_account_id,
            "owner": "jrepp",
            "name": "merge-god",
            "docsPath": "docs-cms/rfcs",
            "rfcLabel": "hermit:rfc-ready",
            "serverID": "repo_existing",
        }
        existing_accounts = [
            {
                "id": github_account_id,
                "name": "github.com",
                "endpoint": "https://api.github.com",
                "token": "github-token",
            }
        ]
        plistlib.dump(
            {
                "hermit.accounts": json.dumps(existing_accounts).encode(),
                "hermit.repositories": json.dumps([settings_repo]).encode(),
            },
            prefs_path.open("wb"),
        )

        run_seed(home)

        plist = plistlib.load(prefs_path.open("rb"))
        accounts = read_json_pref(plist, "hermit.accounts")
        repositories = read_json_pref(plist, "hermit.repositories")

        assert repositories[0]["owner"] == "meridian", repositories[0]
        assert repositories[0]["name"] == "web", repositories[0]
        merge_god = [
            repo
            for repo in repositories
            if repo["owner"] == "jrepp" and repo["name"] == "merge-god"
        ]
        assert merge_god == [settings_repo], merge_god

        github_accounts = [
            account
            for account in accounts
            if account["endpoint"] == "https://api.github.com"
        ]
        assert len(github_accounts) == 1, github_accounts
        assert github_accounts[0]["token"] == "github-token", github_accounts[0]


def test_seed_config_does_not_include_local_canary_repo():
    config_path = REPO_ROOT / "config" / "hermit-repos.meridian.json"
    config = json.loads(config_path.read_text())
    local_canaries = [
        repo
        for repo in config["repositories"]
        if repo["owner"] == "jrepp" and repo["name"] == "merge-god"
    ]
    assert local_canaries == [], local_canaries


def main():
    test_preserves_settings_added_repository()
    test_seed_config_does_not_include_local_canary_repo()
    print("native seed preference tests passed")


if __name__ == "__main__":
    main()
