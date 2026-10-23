#!/usr/bin/env python3
"""Updates the third-party store source (AltStore/SideStore/Feather format) and uploads it to the gist.

    python3 tools/update_store_source.py --upload
        uploads distribution/keibord-source.json as it is
    python3 tools/update_store_source.py --version 1.0.8 --build 9 --size 17931014 \\
        --date 2026-10-23T12:00:00Z --notes-file docs/RELEASE_NOTES.md --upload
        sets the latest version first (the release workflow does this after every release)

Uploading needs GIST_TOKEN (a token with the "gist" scope, a repository secret in CI) and the gist id
in GIST_ID or distribution/gist-id.txt. Without them the upload is skipped with a note, not an error.
"""
import argparse
import json
import os
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "distribution", "keibord-source.json")
GIST_ID_FILE = os.path.join(ROOT, "distribution", "gist-id.txt")
GIST_FILE_NAME = "keibord-source.json"


def release_summary(path):
    """The release notes up to the install instructions, as plain text."""
    lines = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("Install "):
                break
            lines.append(line.rstrip().replace("`", ""))
    return "\n".join(lines).strip()


def update(source, version, build, size, date, notes):
    app = source["apps"][0]
    entry = dict(app["versions"][0]) if app.get("versions") else {}
    entry.update({"version": version, "buildVersion": str(build), "date": date, "size": int(size)})
    if notes:
        entry["localizedDescription"] = notes
    app["versions"] = [entry]


def upload(text):
    token = os.environ.get("GIST_TOKEN", "").strip()
    gist_id = os.environ.get("GIST_ID", "").strip()
    if not gist_id and os.path.exists(GIST_ID_FILE):
        with open(GIST_ID_FILE, encoding="utf-8") as f:
            gist_id = f.read().strip()
    if not token or not gist_id:
        print("Gist not updated: GIST_TOKEN or the gist id is missing.")
        return
    body = json.dumps({"files": {GIST_FILE_NAME: {"content": text}}}).encode("utf-8")
    request = urllib.request.Request(
        f"https://api.github.com/gists/{gist_id}", data=body, method="PATCH",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
                 "Content-Type": "application/json", "X-GitHub-Api-Version": "2022-11-28"})
    with urllib.request.urlopen(request) as response:
        gist = json.load(response)
    print(f"Gist updated: {gist.get('html_url', gist_id)}")
    # What the gist holds now, and what its raw link serves (stores read the raw link).
    for name, f in sorted(gist.get("files", {}).items()):
        print(f"  file {name}: version {source_version(f.get('content'))}")
    owner = (gist.get("owner") or {}).get("login", "")
    raw = f"https://gist.githubusercontent.com/{owner}/{gist_id}/raw/{GIST_FILE_NAME}"
    try:
        with urllib.request.urlopen(raw) as response:
            served = response.read().decode("utf-8")
            cache = response.headers.get("Cache-Control", "")
        print(f"  raw link {raw}: version {source_version(served)} (Cache-Control: {cache})")
    except Exception as error:  # informational only
        print(f"  raw link {raw}: not readable ({error})")


def source_version(text):
    try:
        return json.loads(text or "")["apps"][0]["versions"][0]["version"]
    except Exception:
        return "?"


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--version")
    parser.add_argument("--build")
    parser.add_argument("--size")
    parser.add_argument("--date")
    parser.add_argument("--notes-file")
    parser.add_argument("--upload", action="store_true")
    args = parser.parse_args(argv)
    with open(SOURCE, encoding="utf-8") as f:
        source = json.load(f)
    if args.version:
        missing = [n for n in ("build", "size", "date") if getattr(args, n) is None]
        if missing:
            parser.error("--version needs --" + ", --".join(missing))
        notes = release_summary(args.notes_file) if args.notes_file else None
        update(source, args.version, args.build, args.size, args.date, notes)
    text = json.dumps(source, ensure_ascii=False, indent=2) + "\n"
    with open(SOURCE, "w", encoding="utf-8") as f:
        f.write(text)
    if args.upload:
        upload(text)


if __name__ == "__main__":
    main(sys.argv[1:])
