#!/usr/bin/env python3
"""Record and verify a file tree without following symlinks or accepting special files."""
import hashlib
import json
import os
from pathlib import Path
import stat
import sys


def inventory(root):
    entries = {}

    def visit(path):
        info = path.lstat()
        record = {"mode": stat.S_IMODE(info.st_mode), "uid": info.st_uid, "gid": info.st_gid}
        if stat.S_ISLNK(info.st_mode):
            record.update(type="link", target=os.readlink(path))
        elif stat.S_ISREG(info.st_mode):
            digest = hashlib.sha256()
            with path.open("rb") as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(block)
            record.update(type="file", size=info.st_size, sha256=digest.hexdigest())
        elif stat.S_ISDIR(info.st_mode):
            record.update(type="directory")
        else:
            raise ValueError(f"Unsupported special file: {path}")
        entries[str(path.relative_to(root))] = record
        if record["type"] == "directory":
            for child in sorted(path.iterdir()):
                visit(child)

    if not root.is_dir() or root.is_symlink():
        raise ValueError("Expected a real directory")
    visit(root)
    return entries


def main():
    action, directory, manifest = sys.argv[1:]
    entries = inventory(Path(directory))
    if action == "create":
        with open(manifest, "x", encoding="utf-8") as stream:
            json.dump(entries, stream, sort_keys=True)
            stream.write("\n")
    elif action == "check":
        with open(manifest, encoding="utf-8") as stream:
            expected = json.load(stream)
        if entries != expected:
            raise ValueError("File inventory, contents, ownership or permissions differ from backup manifest")
    else:
        raise ValueError("Usage: backup-manifest.py create|check DIRECTORY MANIFEST")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        print(f"Backup manifest FAILED: {error}", file=sys.stderr)
        sys.exit(1)
