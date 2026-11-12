#!/usr/bin/env python3
"""Plans release builds and maintains the update feed that Stockbar's updater reads.

Only .github/workflows/release.yml calls this.

  release_feed.py plan   --ref-type branch --ref-name testing \\
                         --describe v3.6.0-14-gabc1234 \\
                         [--ahead-of-testing 5] [--behind-branch] \\
                         --project Stockbar.xcodeproj/project.pbxproj
  release_feed.py add    --appcast appcast.xml --channel testing --build 360.14 \\
                         --version 3.6.0 --url https://... --length 1234 \\
                         --signature <EdDSA signature> --minimum-system 15.4 \\
                         --notes-file notes.md [--link https://...]
  release_feed.py superseded --appcast appcast.xml --channel testing < tags

plan        prints key=value lines describing the build a push should produce.
add         adds one build to the feed, newest first, and drops the builds
            nobody would be offered any more. The feed must be signed again
            afterwards.
superseded  reads release tags, one a line, and prints those of the channel's
            builds that the feed no longer lists.
"""
from __future__ import annotations

import argparse
import base64
import binascii
import re
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
STABLE = "stable"
# The name testing builds carry in the feed. The app asks for the same name:
# UpdateChannel.testingFeedChannel in Stockbar/Services/AppUpdateService.swift.
TESTING = "testing"
# The branch experimental builds are made from and the name they carry in their
# feed. The app asks for the same name: UpdateChannel.experimentalFeedChannel.
EXPERIMENTAL = "experimental"
# How many builds of each channel a feed lists. Older released versions stay
# listed for Macs the newest one no longer supports.
KEEP = {STABLE: 3, TESTING: 10, EXPERIMENTAL: 10}
# Each feed is appcast.xml alone on a branch. Experimental builds have a feed
# to themselves, which the app reads from StockbarExperimentalFeedURL in
# Stockbar/Info.plist, so that publishing one can never disturb the feed
# released and testing builds are offered from.
FEED_BRANCH = "appcast"
EXPERIMENTAL_FEED_BRANCH = "appcast-experimental"
# A dry run of an experimental build: a branch whose name starts with this.
EXPERIMENTAL_DRY_RUN = "release-test/experimental"

VERSION_TAG = re.compile(r"v(\d+)\.(\d+)\.(\d+)")
DESCRIBE = re.compile(r"(v\d+\.\d+\.\d+)-(\d+)-g[0-9a-f]+")
BUILD = re.compile(r"\d+(\.\d+){0,2}")
LOOPBACK_URL = re.compile(r"http://(127\.0\.0\.1|localhost)(:\d+)?/")


class ReleaseError(Exception):
    """A release that must not go ahead, with the reason to show."""


@dataclass(frozen=True)
class Plan:
    mode: str  # "publish", "dry-run" or "skip"
    channel: str
    build: str
    version: str
    release_tag: str
    asset_name: str
    feed_branch: str
    reason: str = ""


@dataclass(frozen=True)
class Item:
    build: str
    version: str
    channel: str
    url: str
    length: int
    signature: str
    minimum_system: str
    published: str
    notes: str
    link: str = ""


def build_key(build: str) -> tuple[int, ...]:
    """Orders build numbers the way the updater does: 360 < 360.14 < 370.

    One difference: to the updater a missing part is 0, so 360.9 and 360.9.0
    are the same build, while here the longer one sorts higher. The two forms
    never share a feed: only experimental builds have three parts.
    """
    return tuple(int(part) for part in build.split("."))


def stable_build(tag: str) -> str:
    """v3.6.0 -> 360: the version without dots, as script/release.sh sets it."""
    match = VERSION_TAG.fullmatch(tag)
    if not match:
        raise ReleaseError(f"{tag} is not a version tag of the form vX.Y.Z.")
    major, minor, patch = (int(part) for part in match.groups())
    if minor > 9 or patch > 9:
        raise ReleaseError(f"{tag}: the build number is the version without dots, so minor and patch must be 0-9.")
    return f"{major}{minor}{patch}"


def project_setting(project_text: str, name: str) -> str:
    values = set(re.findall(rf"\b{name} = ([0-9.]+);", project_text))
    if len(values) != 1:
        raise ReleaseError(f"Expected one value of {name} in the project, found {sorted(values) or 'none'}.")
    return values.pop()


def plan(ref_type: str, ref_name: str, describe: str, project_version: str, project_build: str,
         newest_tag: str = "", ahead_of_testing: int | None = None, behind_branch: bool = False) -> Plan:
    """Decides what a push builds.

    A version tag is a stable release. A push to `testing` is a testing build,
    numbered after the release it follows: the 14th commit after v3.6.0 is
    360.14, which sorts above 360 and below the next release. Any other branch
    is a dry run that publishes nothing.

    A push to `experimental` is an experimental build with a third part.
    `ahead_of_testing` is how many of its commits `testing` does not have.
    With 14 commits since v3.6.0, 5 of them not in `testing`, the build is
    360.9.5: just above 360.9, the testing build it contains, and below
    360.10. Bringing `testing` into the branch raises the middle part, and
    every other commit raises the last, so each build sorts above the one
    before it. The tagged commit itself is built too, as 360.0.0, which the
    updater takes for the release: the feed of experimental builds lists
    nothing else, so that is how a release reaches the channel.

    That number depends on where `testing` is when the build is made, so an
    older commit built again later could be numbered above a newer one.
    `behind_branch` says the branch has moved on since the pushed commit; such
    a commit is never published.

    `newest_tag` is the highest version tag in the repository. A testing or
    experimental build numbered after an older release would sort below the
    newest one and never be offered, so it is refused.
    """
    if ref_type == "tag":
        build = stable_build(ref_name)
        version = ref_name[1:]
        if (project_version, project_build) != (version, build):
            raise ReleaseError(
                f"Tag {ref_name} needs the project at version {version} (build {build}), "
                f"but it is at {project_version} (build {project_build}). Run script/release.sh first."
            )
        return Plan("publish", STABLE, build, version, ref_name, f"Stockbar-{version}.zip", FEED_BRANCH)

    match = DESCRIBE.fullmatch(describe.strip())
    if not match:
        raise ReleaseError(f"No version tag is reachable from this commit (git describe gave '{describe.strip()}').")
    base, count = stable_build(match.group(1)), int(match.group(2))
    if ref_name == EXPERIMENTAL or ref_name.startswith(EXPERIMENTAL_DRY_RUN):
        if ahead_of_testing is None or ahead_of_testing < 0:
            raise ReleaseError(
                f"An experimental build needs the number of its commits that {TESTING} does not have; "
                f"got {ahead_of_testing}."
            )
        channel, feed_branch = EXPERIMENTAL, EXPERIMENTAL_FEED_BRANCH
        # More than the commits since the tag only while `testing` lacks the tag itself.
        ahead = min(ahead_of_testing, count)
        build = f"{base}.{count - ahead}.{ahead}"
    else:
        channel, feed_branch = TESTING, FEED_BRANCH
        build = f"{base}.{count}"
    mode = "publish" if ref_name in (TESTING, EXPERIMENTAL) else "dry-run"
    if mode == "publish" and newest_tag and build_key(stable_build(newest_tag)) > build_key(base):
        raise ReleaseError(
            f"{newest_tag} is not in the history of {ref_name}, so build {build} would sort below it "
            f"and never be offered. Bring {ref_name} up to date with the branch that carries {newest_tag} first."
        )
    reason = ""
    if mode == "publish" and channel == TESTING and count == 0:
        mode, reason = "skip", f"This commit is {match.group(1)} itself; its release build covers it."
    elif mode == "publish" and channel == EXPERIMENTAL and behind_branch:
        mode, reason = "skip", f"{ref_name} has moved on since this commit; the build of its newest commit covers it."
    return Plan(mode, channel, build, project_version, f"{channel}-{build}", f"Stockbar-{build}.zip",
                feed_branch, reason)


def _qualified(name: str) -> str:
    return f"{{{SPARKLE_NS}}}{name}"


def _text(element: ET.Element, tag: str, required: bool = True) -> str:
    value = (element.findtext(tag) or "").strip()
    if required and not value:
        raise ReleaseError(f"The feed has an item without <{tag.rsplit('}', 1)[-1]}>. Refusing to rewrite it.")
    return value


def read_feed(path: Path) -> list[Item]:
    """The feed's items. A missing file is an empty feed; a broken one is an error."""
    if not path.exists():
        return []
    text = path.read_text(encoding="utf-8")
    # The feed this script writes declares no document type. One that does
    # could define entities for the parser to expand, so it is not parsed.
    if "<!DOCTYPE" in text or "<!ENTITY" in text:
        raise ReleaseError(f"{path} declares a document type. Refusing to read it.")
    try:
        root = ET.fromstring(text)
    except ET.ParseError as error:
        raise ReleaseError(f"{path} is not valid XML ({error}). Refusing to replace it.") from error
    items = []
    for element in root.iterfind("channel/item"):
        enclosure = element.find("enclosure")
        if enclosure is None:
            raise ReleaseError("The feed has an item without a download. Refusing to rewrite it.")
        channel = _text(element, _qualified("channel"), required=False) or STABLE
        if channel not in KEEP:
            raise ReleaseError(f"The feed has an item on an unknown channel '{channel}'.")
        items.append(Item(
            build=_text(element, _qualified("version")),
            version=_text(element, _qualified("shortVersionString")),
            channel=channel,
            url=enclosure.get("url", ""),
            length=int(enclosure.get("length", "0")),
            signature=enclosure.get(_qualified("edSignature"), ""),
            minimum_system=_text(element, _qualified("minimumSystemVersion")),
            published=_text(element, "pubDate"),
            notes=element.findtext("description") or "",
            link=_text(element, "link", required=False),
        ))
    return items


def render_feed(items: list[Item], repository_url: str) -> str:
    ET.register_namespace("sparkle", SPARKLE_NS)
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Stockbar"
    ET.SubElement(channel, "link").text = repository_url
    ET.SubElement(channel, "description").text = "Stockbar updates."
    ET.SubElement(channel, "language").text = "en"
    for item in items:
        element = ET.SubElement(channel, "item")
        ET.SubElement(element, "title").text = f"{item.version} ({item.build})"
        if item.link:
            ET.SubElement(element, "link").text = item.link
        ET.SubElement(element, "pubDate").text = item.published
        ET.SubElement(element, _qualified("version")).text = item.build
        ET.SubElement(element, _qualified("shortVersionString")).text = item.version
        if item.channel != STABLE:
            ET.SubElement(element, _qualified("channel")).text = item.channel
        ET.SubElement(element, _qualified("minimumSystemVersion")).text = item.minimum_system
        # Inside the feed, so the feed's signature covers the notes too.
        ET.SubElement(element, "description", {_qualified("format"): "markdown"}).text = item.notes
        ET.SubElement(element, "enclosure", {
            "url": item.url,
            "length": str(item.length),
            "type": "application/octet-stream",
            _qualified("edSignature"): item.signature,
        })
    ET.indent(rss, space="  ")
    return '<?xml version="1.0" encoding="utf-8"?>\n' + ET.tostring(rss, encoding="unicode") + "\n"


def prune(items: list[Item]) -> list[Item]:
    """Newest first, without the builds no one would be offered.

    A testing build older than the newest release is one of those: everyone on
    the testing channel is offered the release instead.
    """
    newest_first = sorted(items, key=lambda item: build_key(item.build), reverse=True)
    kept = [item for item in newest_first if item.channel == STABLE][:KEEP[STABLE]]
    floor = build_key(kept[0].build) if kept else ()
    for channel in (TESTING, EXPERIMENTAL):
        kept += [item for item in newest_first
                 if item.channel == channel and build_key(item.build) > floor][:KEEP[channel]]
    return sorted(kept, key=lambda item: build_key(item.build), reverse=True)


def three_part(version: str) -> str:
    """15.4 -> 15.4.0, the form the updater compares against the running system."""
    parts = version.split(".")
    if not 1 <= len(parts) <= 3 or not all(part.isdigit() for part in parts):
        raise ReleaseError(f"'{version}' is not a macOS version.")
    return ".".join(parts + ["0"] * (3 - len(parts)))


def validated(item: Item) -> Item:
    if item.channel not in KEEP:
        raise ReleaseError(f"Unknown channel '{item.channel}'.")
    if not BUILD.fullmatch(item.build):
        raise ReleaseError(f"'{item.build}' is not a build number.")
    if not item.version.strip():
        raise ReleaseError("The version is empty.")
    if not (item.url.startswith("https://") or LOOPBACK_URL.match(item.url)):
        raise ReleaseError(f"The download address must be https: {item.url}")
    if item.length <= 0:
        raise ReleaseError("The download length must be positive.")
    try:
        signature = base64.b64decode(item.signature, validate=True)
    except (binascii.Error, ValueError) as error:
        raise ReleaseError("The signature is not base64.") from error
    if len(signature) != 64:
        raise ReleaseError("The signature is not an EdDSA signature (64 bytes).")
    return item


def add(items: list[Item], item: Item) -> list[Item]:
    """The feed with `item` added, replacing an earlier entry for the same build."""
    item = validated(item)
    if any((existing.channel == EXPERIMENTAL) != (item.channel == EXPERIMENTAL) for existing in items):
        raise ReleaseError(
            f"Experimental builds are listed in a feed of their own (the {EXPERIMENTAL_FEED_BRANCH} branch), "
            f"never beside released or testing builds."
        )
    others = [existing for existing in items if build_key(existing.build) != build_key(item.build)]
    return prune(others + [item])


def superseded(tags: list[str], items: list[Item], channel: str) -> list[str]:
    """The tags of `channel`'s builds that the feed no longer lists.

    Such a build can never be offered again, so the workflow removes its
    prerelease. Only a tag that is the channel's name, a hyphen and a build
    number is ever returned: `experimental-370.0.4`, never
    `experimental-checkpoint-2026-11-12`.
    """
    if channel not in (TESTING, EXPERIMENTAL):
        raise ReleaseError(f"Only testing and experimental builds are ever removed, not '{channel}'.")
    # Read against the other feed, or an empty one, every build of the channel would look superseded.
    if not items or any((item.channel == EXPERIMENTAL) != (channel == EXPERIMENTAL) for item in items):
        raise ReleaseError(f"This is not the feed {channel} builds are listed in. Refusing to call any superseded.")
    listed = {build_key(item.build) for item in items if item.channel == channel}
    prefix = f"{channel}-"
    return [tag for tag in tags
            if tag.startswith(prefix) and BUILD.fullmatch(tag[len(prefix):])
            and build_key(tag[len(prefix):]) not in listed]


def _main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Plan release builds and maintain the update feed.")
    commands = parser.add_subparsers(dest="command", required=True)

    plan_parser = commands.add_parser("plan")
    plan_parser.add_argument("--ref-type", required=True, choices=["branch", "tag"])
    plan_parser.add_argument("--ref-name", required=True)
    plan_parser.add_argument("--describe", default="")
    plan_parser.add_argument("--newest-tag", default="")
    plan_parser.add_argument("--ahead-of-testing", type=int)
    plan_parser.add_argument("--behind-branch", action="store_true")
    plan_parser.add_argument("--project", required=True, type=Path)

    add_parser = commands.add_parser("add")
    add_parser.add_argument("--appcast", required=True, type=Path)
    add_parser.add_argument("--channel", required=True)
    add_parser.add_argument("--build", required=True)
    add_parser.add_argument("--version", required=True)
    add_parser.add_argument("--url", required=True)
    add_parser.add_argument("--length", required=True, type=int)
    add_parser.add_argument("--signature", required=True)
    add_parser.add_argument("--minimum-system", required=True)
    add_parser.add_argument("--notes-file", required=True, type=Path)
    add_parser.add_argument("--link", default="")
    add_parser.add_argument("--repository-url", default="https://github.com/jayjay181818/StockBar")

    superseded_parser = commands.add_parser("superseded")
    superseded_parser.add_argument("--appcast", required=True, type=Path)
    superseded_parser.add_argument("--channel", required=True, choices=[TESTING, EXPERIMENTAL])

    args = parser.parse_args(argv)
    try:
        if args.command == "plan":
            project = args.project.read_text(encoding="utf-8")
            result = plan(args.ref_type, args.ref_name, args.describe,
                          project_setting(project, "MARKETING_VERSION"),
                          project_setting(project, "CURRENT_PROJECT_VERSION"),
                          args.newest_tag, args.ahead_of_testing, args.behind_branch)
            for key, value in vars(result).items():
                print(f"{key}={value}")
        elif args.command == "add":
            notes = args.notes_file.read_text(encoding="utf-8").strip() or "No release notes."
            item = Item(
                build=args.build, version=args.version, channel=args.channel, url=args.url,
                length=args.length, signature=args.signature,
                minimum_system=three_part(args.minimum_system),
                published=format_datetime(datetime.now(timezone.utc)), notes=notes, link=args.link,
            )
            items = add(read_feed(args.appcast), item)
            args.appcast.write_text(render_feed(items, args.repository_url), encoding="utf-8")
            print(f"{args.appcast}: {len(items)} build(s), newest {items[0].build}")
        else:
            tags = [line.strip() for line in sys.stdin if line.strip()]
            for tag in superseded(tags, read_feed(args.appcast), args.channel):
                print(tag)
    except ReleaseError as error:
        print(f"release_feed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
