#!/usr/bin/env python3
"""Release version math and the Sparkle appcast feed, shared by release.sh and appcast.sh.

  release_tools.py current                                               print the version tag being released
  release_tools.py next <patch|minor|major|beta|vX.Y.Z|vX.Y.Z-beta.N>   print the next tag
  release_tools.py trace                                                 check release-branch commits name their main commit
  release_tools.py notes-start <tag>                                     print the release to start notes from
  release_tools.py appcast <file> <version> <build> <min_os> <enclosure_url> <sig_attrs>
"""
import re
import subprocess
import sys

TAG = re.compile(r"^v(\d+)\.(\d+)\.(\d+)(?:-beta\.([1-9]\d*))?$")
BETA_CHANNEL = "beta"
KEEP = 10


def parse(tag):
    m = TAG.match(tag)
    if not m:
        return None
    maj, mnr, pat, beta = m.groups()
    return int(maj), int(mnr), int(pat), int(beta) if beta else None


def precedence(version):
    maj, mnr, pat, beta = version
    return maj, mnr, pat, float("inf") if beta is None else beta


def format_tag(maj, mnr, pat, beta=None):
    return f"v{maj}.{mnr}.{pat}" + (f"-beta.{beta}" if beta else "")


# Sparkle orders installs by build number (the commit count), so two versions on one commit would share it
# and the newer one would never be offered.
def next_tag(bump, tags, tags_at_head=()):
    taken = [t for t in tags_at_head if parse(t)]
    if taken:
        raise ValueError(f"HEAD already carries {', '.join(sorted(taken))}; commit first so the new tag gets its own build number")
    versions = [v for v in map(parse, tags) if v]
    latest = max(versions, key=precedence, default=None)
    releases = [v for v in versions if v[3] is None]
    release = max(releases, key=precedence, default=None)

    if bump in ("patch", "minor", "major"):
        if release is None:
            raise ValueError("no release to bump from; pass an explicit version such as v0.1.0")
        maj, mnr, pat, _ = release
        new = {"major": (maj + 1, 0, 0, None), "minor": (maj, mnr + 1, 0, None),
               "patch": (maj, mnr, pat + 1, None)}[bump]
    elif bump == "beta":
        if latest is None or latest[3] is None:
            base = release or (0, 0, 0, None)
            start = format_tag(base[0], base[1] + 1, 0, 1)
            raise ValueError(f"no beta in progress; start one with an explicit version such as {start}")
        new = latest[:3] + (latest[3] + 1,)
    else:
        new = parse(bump)
        if new is None:
            raise ValueError(f"'{bump}' is not patch, minor, major, beta, vX.Y.Z, or vX.Y.Z-beta.N")

    if latest is not None and precedence(new) <= precedence(latest):
        raise ValueError(f"{format_tag(*new)} is not newer than {format_tag(*latest)}")
    return format_tag(*new)


# git describe's pick between two tags on one commit depends on tag kind and name, so a hand-made second tag
# would decide the version by accident; the newest version tag at HEAD decides instead.
def current_tag(tags_at_head, described):
    versions = [t for t in tags_at_head if parse(t)]
    return max(versions, key=lambda t: precedence(parse(t)), default=described)


def previous_release(tag, tags):
    new = parse(tag)
    if new is None or new[3] is not None:
        return None
    earlier = [t for t in tags if (v := parse(t)) and v[3] is None and precedence(v) < precedence(new)]
    return max(earlier, key=lambda t: precedence(parse(t)), default=None)


def is_prerelease(version):
    return "-" in version


def render_item(version, build, min_os, enclosure_url, sig_attrs):
    channel = f"      <sparkle:channel>{BETA_CHANNEL}</sparkle:channel>\n" if is_prerelease(version) else ""
    return (
        "    <item>\n"
        f"      <title>{version}</title>\n"
        f"{channel}"
        f"      <sparkle:version>{build}</sparkle:version>\n"
        f"      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>\n"
        f"      <sparkle:minimumSystemVersion>{min_os}</sparkle:minimumSystemVersion>\n"
        f'      <enclosure url="{enclosure_url}" {sig_attrs} type="application/octet-stream" />\n'
        "    </item>"
    )


def is_release_item(item):
    return "<sparkle:channel>" not in item


def upsert_items(items, new_item, version, keep=KEEP):
    marker = f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>"
    items = [new_item] + [it for it in items if marker not in it]
    kept = items[:keep]
    if not any(map(is_release_item, kept)):
        kept += next(([it] for it in items[keep:] if is_release_item(it)), [])
    return kept


ITEM_FIELDS = re.compile(
    r"<sparkle:version>([^<]*)</sparkle:version>.*?<sparkle:shortVersionString>([^<]*)</sparkle:shortVersionString>",
    re.DOTALL)


# Sparkle offers whatever has the higher build number, so the feed's build order must match its version order or
# an install is offered an older version, or never offered a newer one.
def order_problem(items, version, build):
    new_version, new_build = precedence(parse(f"v{version}")), int(build)
    for it in items:
        m = ITEM_FIELDS.search(it)
        if not m or m.group(2) == version or not parse(f"v{m.group(2)}"):
            continue
        old_build, old_version = int(m.group(1)), precedence(parse(f"v{m.group(2)}"))
        if (new_version > old_version) != (new_build > old_build) or new_build == old_build:
            return (f"{version} (build {new_build}) and {m.group(2)} (build {old_build}) are in different "
                    "orders by version and by build, so Sparkle would offer the wrong one")
    return None


CHERRY_PICK = re.compile(r"^\(cherry picked from commit ([0-9a-f]{40})\)$", re.MULTILINE)
NO_MAIN_COMMIT = re.compile(r"^No main commit: *\S", re.MULTILINE)


# A downstream receives upstream only through main, so each fix made on a release branch has to say which main
# commit it carries (git cherry-pick -x writes the line) or why there is none.
def untraced(commits, on_main):
    def traced(message):
        picked = CHERRY_PICK.findall(message)
        return (picked and all(map(on_main, picked))) or NO_MAIN_COMMIT.search(message)
    return [sha for sha, message in commits if not traced(message)]


def branch_commits():
    base = git("merge-base", "HEAD", "origin/main")
    log = git("log", "--format=%H%x00%B%x01", f"{base}..HEAD") if base else ""
    return [tuple(entry.strip().split("\0", 1)) for entry in log.split("\x01") if entry.strip()]


def on_origin_main(sha):
    return subprocess.run(["git", "merge-base", "--is-ancestor", sha, "origin/main"], capture_output=True).returncode == 0


HEADER = (
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" '
    'xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
    '  <channel>\n'
    '    <title>KeyScribe</title>\n'
    '    <link>https://raw.githubusercontent.com/rsperko/keyscribe/main/appcast.xml</link>\n'
    '    <description>KeyScribe app updates</description>\n'
    '    <language>en</language>\n'
)
FOOTER = '  </channel>\n</rss>\n'


def write_appcast(path, version, build, min_os, enclosure_url, sig_attrs):
    try:
        with open(path) as f:
            existing = f.read()
    except FileNotFoundError:
        existing = ""
    items = re.findall(r"    <item>.*?    </item>", existing, re.DOTALL)
    problem = order_problem(items, version, build)
    if problem:
        raise ValueError(problem)
    new_item = render_item(version, build, min_os, enclosure_url, sig_attrs)
    with open(path, "w") as f:
        f.write(HEADER + "\n".join(upsert_items(items, new_item, version)) + "\n" + FOOTER)


def reachable_tags():
    return git("tag", "--merged", "HEAD", "--list", "v*").split()


def git(*args):
    result = subprocess.run(["git", *args], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else ""


def main(argv):
    if argv == ["current"]:
        print(current_tag(git("tag", "--points-at", "HEAD").split(),
                          git("describe", "--tags", "--abbrev=0", "--match", "v[0-9]*")))
        return 0
    if argv == ["trace"]:
        missing = untraced(branch_commits(), on_origin_main)
        for sha in missing:
            print(f"error: {sha[:12]} names no main commit; add (cherry picked from commit <sha>) or "
                  "'No main commit: <why>'", file=sys.stderr)
        return 1 if missing else 0
    if len(argv) == 2 and argv[0] == "notes-start":
        print(previous_release(argv[1], reachable_tags()) or "")
        return 0
    try:
        if len(argv) == 2 and argv[0] == "next":
            print(next_tag(argv[1], reachable_tags(), git("tag", "--points-at", "HEAD").split()))
            return 0
        if len(argv) == 7 and argv[0] == "appcast":
            write_appcast(*argv[1:])
            return 0
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
