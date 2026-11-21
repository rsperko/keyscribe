import argparse
import hashlib
import os
from pathlib import Path
import stat
import subprocess


def digest_path(digest, path, opened=frozenset()):
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError:
        digest.update(b"missing\0")
        return
    digest.update(str(stat.S_IFMT(mode)).encode() + b"\0")
    digest.update(str(mode & 0o111).encode() + b"\0")
    if path.is_symlink():
        digest.update(os.fsencode(os.readlink(path)) + b"\0")
        try:
            reached = path.resolve(strict=True)
        except (OSError, RuntimeError):
            reached = None
        if reached is None or reached in opened:
            digest.update(b"unreached\0")
        else:
            digest_path(digest, reached, opened)
    elif path.is_dir():
        opened = opened | {path.resolve()}
        for child in sorted(path.iterdir()):
            if child.name == ".git":
                continue
            digest.update(os.fsencode(child.name) + b"\0")
            digest_path(digest, child, opened)
    elif path.is_file():
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
    else:
        raise ValueError(f"unsupported verification input: {path}")
    digest.update(b"\0end\0")


def source_digest(root):
    files = subprocess.check_output(
        ["git", "-C", str(root), "ls-files", "-z", "--cached", "--others", "--exclude-standard"], timeout=30
    )
    digest = hashlib.sha256(b"verification-source-v1\0")
    for name in sorted(set(files.split(b"\0")) - {b""}):
        digest.update(name + b"\0")
        digest_path(digest, Path(root) / os.fsdecode(name))
    return digest.hexdigest()


def artifact_digest(path):
    digest = hashlib.sha256(b"verification-artifact-v1\0")
    digest_path(digest, Path(path))
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("kind", choices=["source", "artifact"])
    parser.add_argument("path", type=Path)
    args = parser.parse_args()
    print(source_digest(args.path) if args.kind == "source" else artifact_digest(args.path))


if __name__ == "__main__":
    main()
