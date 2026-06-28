#!/usr/bin/env python3
"""
Seed hermit UserDefaults for the debug build from config/hermit.yaml.

Sandboxed macOS apps (app-sandbox=true) read UserDefaults from
~/Library/Containers/<bundle-id>/Data/Library/Preferences/<bundle-id>.plist.
Non-sandboxed ad-hoc builds read from ~/Library/Preferences/<bundle-id>.plist.

This script detects which location applies and writes to both, so it works
regardless of sandbox state. It writes hermit.accounts / hermit.repositories
JSON so the app has fully-populated stores on first launch without prompting.

Usage:
    python3 scripts/seed-native-prefs.py <bundle-id> [config/hermit.yaml] [--repos-json config/hermit-repos.meridian.json] [--token TOKEN]
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
DEV_UUID_NAMESPACE = uuid.UUID("9df7786a-6338-4bd4-bebb-3f225c005a6a")

def main():
    if len(sys.argv) < 2:
        print("Usage: seed-native-prefs.py <bundle-id> [config/hermit.yaml] [--repos-json path] [--token TOKEN]", file=sys.stderr)
        sys.exit(1)

    bundle_id = sys.argv[1]
    cfg_path  = "config/hermit.yaml"
    repos_json_path = None
    token_override = None

    args = sys.argv[2:]
    i = 0
    while i < len(args):
        if args[i] == "--token" and i + 1 < len(args):
            token_override = args[i + 1]
            i += 2
        elif args[i] == "--repos-json" and i + 1 < len(args):
            repos_json_path = args[i + 1]
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
    plist_path = os.path.expanduser(f"~/Library/Preferences/{bundle_id}.plist")
    sandbox_plist = os.path.expanduser(
        f"~/Library/Containers/{bundle_id}/Data/Library/Preferences/{bundle_id}.plist"
    )

    def load_plist(path):
        return plistlib.load(open(path, "rb")) if os.path.exists(path) else {}

    existing_prefs = {}
    existing_prefs.update(load_plist(plist_path))
    existing_prefs.update(load_plist(sandbox_plist))

    def decode_existing_json(key):
        value = existing_prefs.get(key)
        if isinstance(value, bytes):
            raw = value
        elif isinstance(value, str):
            raw = value.encode()
        else:
            return []
        try:
            return json.loads(raw.decode())
        except Exception:
            return []

    def existing_token_for(endpoint):
        endpoint = endpoint.rstrip("/")
        for account in decode_existing_json("hermit.accounts"):
            if str(account.get("endpoint", "")).rstrip("/") == endpoint:
                token = account.get("token")
                if token:
                    return token
        return ""

    def stable_uuid(kind, key):
        return str(uuid.uuid5(DEV_UUID_NAMESPACE, f"{kind}:{key}"))

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

    accounts = []
    repositories = []

    if repos_json_path and os.path.exists(repos_json_path):
        repo_cfg = json.load(open(repos_json_path))
        account_ids = {}
        for account in repo_cfg.get("accounts", []):
            account_key = account.get("id") or account.get("endpoint") or account.get("name")
            endpoint = str(account.get("endpoint", "")).rstrip("/")
            account_id = stable_uuid("account", account_key)
            account_ids[account_key] = account_id
            account_token = token_override or existing_token_for(endpoint)
            next_account = {
                "id": account_id,
                "name": account.get("name") or account_key,
                "endpoint": endpoint,
            }
            if account_token:
                next_account["token"] = account_token
            accounts.append(next_account)

        for repo in repo_cfg.get("repositories", []):
            account_key = repo.get("account")
            account_id = account_ids.get(account_key)
            if not account_id:
                continue
            repo_owner = repo.get("owner", "")
            repo_name = repo.get("name", "")
            repo_docs = repo.get("docs_path", "docs-cms/rfcs").rstrip("/")
            repositories.append({
                "id": stable_uuid("repo", f"{account_key}/{repo_owner}/{repo_name}"),
                "accountID": account_id,
                "owner": repo_owner,
                "name": repo_name,
                "docsPath": repo_docs,
                "rfcLabel": repo.get("rfc_label", "hermit:rfc-ready"),
            })

        if not accounts or not repositories:
            print(f"Warning: {repos_json_path} did not contain usable accounts/repositories; falling back to {cfg_path}")

    if not accounts or not repositories:
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
    else:
        first_repo = repositories[0]
        owner = first_repo["owner"]
        name = first_repo["name"]
        docs = first_repo["docsPath"]
        first_account = next((account for account in accounts if account["id"] == first_repo["accountID"]), accounts[0])
        account_endpoint = first_account["endpoint"]
        base_url = account_endpoint.rstrip("/")
        token = first_account.get("token", "")

    d = load_plist(plist_path)
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
    print(f"Seeded UserDefaults (non-sandboxed) for {bundle_id}")

    # Also write into the sandbox container if it exists.
    # Sandboxed apps (app-sandbox=true) read from the container, not ~/Library/Preferences.
    sandbox_prefs_dir = os.path.dirname(sandbox_plist)
    if os.path.isdir(os.path.expanduser(f"~/Library/Containers/{bundle_id}")):
        os.makedirs(sandbox_prefs_dir, exist_ok=True)
        sd = load_plist(sandbox_plist)
        sd.update(d)
        plistlib.dump(sd, open(sandbox_plist, "wb"))
        print(f"Seeded UserDefaults (sandboxed container) for {bundle_id}")

    print(f"  account:  {account_endpoint} (token: {token[:8]}…)" if token else f"  account:  {account_endpoint} (no token)")
    print(f"  repos:    {len(repositories)} configured; default {owner}/{name} @ {docs}")

if __name__ == "__main__":
    main()
