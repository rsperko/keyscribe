#!/usr/bin/env python3
"""Canary for upstream dependency mutation.

Two failure modes, both of which have bitten this repo:

  moved-tag   A dependency's version tag is repointed at a different commit, so
              Package.resolved's pinned revision no longer matches what the tag
              names. Detection only; the pin still builds.

  changed-asset  A dependency's binaryTarget points at a GitHub release asset
              that is re-uploaded in place. The pinned manifest's declared
              checksum then no longer matches the live bytes and every fresh
              checkout dies at `swift package resolve`. This is a hard failure.

Both checks are download-free: manifests come from raw.githubusercontent at the
pinned revision, and asset hashes come from the GitHub release API's per-asset
`digest` field, so a ~1 GB xcframework is never fetched.

Usage:
  scripts/check-binary-artifacts.py [--resolved PATH] [--strict] [--quiet]

Exit 0 clean, 1 on a hard failure, 2 on a warning under --strict.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

RELEASE_ASSET = re.compile(
    r"^https://github\.com/(?P<owner>[^/]+)/(?P<repo>[^/]+)/releases/download/(?P<tag>.+)/(?P<asset>[^/]+)$"
)
URL_ARG = re.compile(r'url:\s*(?:"([^"]+)"|([A-Za-z_]\w*))', re.S)
CHECKSUM_ARG = re.compile(r'checksum:\s*(?:"([^"]+)"|([A-Za-z_]\w*))', re.S)
LET_BINDING = re.compile(r'^\s*(?:let|var)\s+([A-Za-z_]\w*)\s*(?::\s*String\s*)?=\s*"([^"]*)"', re.M)
INTERPOLATION = re.compile(r"\\\(([A-Za-z_]\w*)\)")
SHA256 = re.compile(r"^[0-9a-fA-F]{64}$")

GREEN, RED, YELLOW, DIM, RESET = "\033[32m", "\033[31m", "\033[33m", "\033[2m", "\033[0m"


def github_token() -> str | None:
    for var in ("GITHUB_TOKEN", "GH_TOKEN"):
        if os.environ.get(var):
            return os.environ[var]
    try:
        out = subprocess.run(
            ["gh", "auth", "token"], capture_output=True, text=True, timeout=10
        )
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    return None


def fetch(url: str, token: str | None, accept: str | None = None) -> bytes:
    req = urllib.request.Request(url)
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    if accept:
        req.add_header("Accept", accept)
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read()


def load_pins(path: str) -> list[dict]:
    with open(path) as handle:
        doc = json.load(handle)
    pins = doc.get("pins", doc.get("object", {}).get("pins", []))
    out = []
    for pin in pins:
        if pin.get("kind") != "remoteSourceControl":
            continue
        location = pin.get("location", "")
        match = re.match(r"^https://github\.com/([^/]+)/([^/]+?)(?:\.git)?/?$", location)
        if not match:
            continue
        out.append(
            {
                "identity": pin.get("identity", ""),
                "owner": match.group(1),
                "repo": match.group(2),
                "location": location,
                "revision": pin.get("state", {}).get("revision", ""),
                "version": pin.get("state", {}).get("version"),
            }
        )
    return out


def tag_revision(location: str, version: str) -> str | None:
    """Commit the dependency's version tag currently names, or None if absent."""
    try:
        out = subprocess.run(
            ["git", "ls-remote", "--tags", location],
            capture_output=True,
            text=True,
            timeout=60,
        )
    except subprocess.TimeoutExpired:
        return None
    if out.returncode != 0:
        return None
    candidates = {f"refs/tags/{version}", f"refs/tags/v{version}"}
    peeled, plain = {}, {}
    for line in out.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) != 2:
            continue
        sha, ref = parts
        if ref.endswith("^{}"):
            peeled[ref[:-3]] = sha
        else:
            plain[ref] = sha
    for ref in candidates:
        if ref in peeled:
            return peeled[ref]
        if ref in plain:
            return plain[ref]
    return None


def swift_constants(source: str) -> dict[str, str]:
    """Top-level `let x = "..."` bindings, with \\(interpolation) resolved.

    Sparkle and friends build their binaryTarget url/checksum out of variables
    rather than inline literals, so a literal-only parser silently reports that
    such a package has no binary artifact at all.
    """
    symbols = {name: value for name, value in LET_BINDING.findall(source)}
    for _ in range(5):
        changed = False
        for name, value in symbols.items():
            resolved = INTERPOLATION.sub(
                lambda m: symbols.get(m.group(1), m.group(0)), value
            )
            if resolved != value:
                symbols[name] = resolved
                changed = True
        if not changed:
            break
    return symbols


def binary_targets(dep: dict, token: str | None) -> list[tuple[str, str]]:
    """(url, checksum) for each binaryTarget in the dependency's pinned manifest."""
    raw = (
        f"https://raw.githubusercontent.com/{dep['owner']}/{dep['repo']}/"
        f"{dep['revision']}/Package.swift"
    )
    try:
        source = fetch(raw, token).decode("utf-8", "replace")
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError):
        return []

    symbols = swift_constants(source)

    def resolve(match: re.Match | None) -> str | None:
        if not match:
            return None
        literal, identifier = match.group(1), match.group(2)
        value = literal if literal is not None else symbols.get(identifier)
        if value is None:
            return None
        return INTERPOLATION.sub(lambda m: symbols.get(m.group(1), m.group(0)), value)

    found = []
    for chunk in source.split(".binaryTarget(")[1:]:
        url = resolve(URL_ARG.search(chunk))
        checksum = resolve(CHECKSUM_ARG.search(chunk))
        if url and checksum and SHA256.match(checksum):
            found.append((url, checksum.lower()))
    return found


def live_digest(url: str, token: str | None) -> tuple[str | None, str | None]:
    """(sha256, error) for a GitHub release asset, without downloading it."""
    match = RELEASE_ASSET.match(url)
    if not match:
        return None, "not a GitHub release asset"
    api = (
        f"https://api.github.com/repos/{match['owner']}/{match['repo']}"
        f"/releases/tags/{match['tag']}"
    )
    try:
        release = json.loads(fetch(api, token, "application/vnd.github+json"))
    except urllib.error.HTTPError as exc:
        return None, f"release API HTTP {exc.code}"
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        return None, f"release API unreachable ({exc})"
    for asset in release.get("assets", []):
        if asset.get("name") == match["asset"]:
            digest = asset.get("digest") or ""
            if digest.startswith("sha256:"):
                return digest.split(":", 1)[1].lower(), None
            return None, "asset has no sha256 digest"
    return None, "asset not found in release"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--resolved", default="Package.resolved")
    parser.add_argument("--strict", action="store_true", help="treat warnings as failure")
    parser.add_argument("--quiet", action="store_true", help="only print problems")
    args = parser.parse_args()

    token = github_token()
    deps = load_pins(args.resolved)
    if not deps:
        print(f"{RED}no GitHub source-control pins found in {args.resolved}{RESET}")
        return 1

    failures, warnings, checked = [], [], 0

    for dep in deps:
        if dep["version"]:
            current = tag_revision(dep["location"], dep["version"])
            if current is None:
                warnings.append(
                    f"{dep['identity']}: tag for {dep['version']} not found upstream"
                )
            elif current != dep["revision"]:
                warnings.append(
                    f"{dep['identity']}: tag {dep['version']} MOVED "
                    f"{dep['revision'][:10]} -> {current[:10]} "
                    f"(pin still builds; re-pin deliberately)"
                )

        for url, declared in binary_targets(dep, token):
            checked += 1
            digest, error = live_digest(url, token)
            label = f"{dep['identity']} {url.rsplit('/', 1)[-1]}"
            if digest is None:
                warnings.append(f"{label}: unverifiable ({error})")
            elif digest != declared:
                failures.append(
                    f"{label}: ASSET CHANGED — pinned manifest declares "
                    f"{declared[:16]}… but the live asset is {digest[:16]}…; "
                    f"every fresh checkout will fail `swift package resolve`"
                )
            elif not args.quiet:
                print(f"  {GREEN}✓{RESET} {label} {DIM}{declared[:16]}…{RESET}")

    for warning in warnings:
        print(f"  {YELLOW}! WARN{RESET} {warning}")
    for failure in failures:
        print(f"  {RED}✗ FAIL{RESET} {failure}")

    if failures:
        print(
            f"\n{RED}{len(failures)} binary artifact(s) mutated upstream.{RESET} "
            "Re-pin to the dependency revision whose manifest declares the new "
            "checksum, then clear the stale caches (see AGENTS.md)."
        )
        return 1
    if not args.quiet:
        print(
            f"\n{GREEN}ok{RESET} — {checked} binary artifact(s) match their pinned "
            f"manifest across {len(deps)} pinned dependencies"
            + (f", {len(warnings)} warning(s)" if warnings else "")
        )
    if warnings and args.strict:
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
