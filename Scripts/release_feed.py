#!/usr/bin/env python3
"""Plans release builds and maintains the update feed that Stockbar's updater reads.

Only .github/workflows/release.yml calls this.

  release_feed.py plan   --ref-type branch --ref-name testing \\
                         --describe v3.6.0-14-gabc1234 \\
                         --project Stockbar.xcodeproj/project.pbxproj
  release_feed.py add    --appcast appcast.xml --channel testing --build 360.14 \\
                         --version 3.6.0 --url https://... --length 1234 \\
                         --signature <EdDSA signature> --minimum-system 15.4 \\
                         --notes-file notes.md [--link https://...]
  release_feed.py builds --appcast appcast.xml --channel testing

plan    prints key=value lines describing the build a push should produce.
add     adds one build to the feed, newest first, and drops the builds nobody
        would be offered any more. The feed must be signed again afterwards.
builds  prints the build numbers the feed still lists for a channel.
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
# Older released versions stay listed for Macs the newest one no longer supports.
KEEP_STABLE = 3
KEEP_TESTING = 10

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
    """Orders build numbers the way the updater does: 360 < 360.14 < 370."""
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
         newest_tag: str = "") -> Plan:
    """Decides what a push builds.

    A version tag is a stable release. A push to `testing` is a testing build,
    numbered after the release it follows: the 14th commit after v3.6.0 is
    360.14, which sorts above 360 and below the next release. Any other branch
    is a dry run that publishes nothing.

    `newest_tag` is the highest version tag in the repository. A testing build
    numbered after an older release would sort below the newest one and never
    be offered, so it is refused.
    """
    if ref_type == "tag":
        build = stable_build(ref_name)
        version = ref_name[1:]
        if (project_version, project_build) != (version, build):
            raise ReleaseError(
                f"Tag {ref_name} needs the project at version {version} (build {build}), "
                f"but it is at {project_version} (build {project_build}). Run script/release.sh first."
            )
        return Plan("publish", STABLE, build, version, ref_name, f"Stockbar-{version}.zip")

    match = DESCRIBE.fullmatch(describe.strip())
    if not match:
        raise ReleaseError(f"No version tag is reachable from this commit (git describe gave '{describe.strip()}').")
    base, count = stable_build(match.group(1)), int(match.group(2))
    build = f"{base}.{count}"
    mode = "publish" if ref_name == TESTING else "dry-run"
    if mode == "publish" and newest_tag and build_key(stable_build(newest_tag)) > build_key(base):
        raise ReleaseError(
            f"{newest_tag} is not in the history of {ref_name}, so build {build} would sort below it "
            f"and never be offered. Bring {ref_name} up to date with the branch that carries {newest_tag} first."
        )
    reason = ""
    if mode == "publish" and count == 0:
        mode, reason = "skip", f"This commit is {match.group(1)} itself; its release build covers it."
    return Plan(mode, TESTING, build, project_version, f"testing-{build}", f"Stockbar-{build}.zip", reason)


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
        if channel not in (STABLE, TESTING):
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
        if item.channel == TESTING:
            ET.SubElement(element, _qualified("channel")).text = TESTING
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


def prune(items: list[Item], keep_stable: int = KEEP_STABLE, keep_testing: int = KEEP_TESTING) -> list[Item]:
    """Newest first, without the builds no one would be offered.

    A testing build older than the newest release is one of those: everyone on
    the testing channel is offered the release instead.
    """
    newest_first = sorted(items, key=lambda item: build_key(item.build), reverse=True)
    stable = [item for item in newest_first if item.channel == STABLE][:keep_stable]
    floor = build_key(stable[0].build) if stable else ()
    testing = [item for item in newest_first
               if item.channel == TESTING and build_key(item.build) > floor][:keep_testing]
    return sorted(stable + testing, key=lambda item: build_key(item.build), reverse=True)


def three_part(version: str) -> str:
    """15.4 -> 15.4.0, the form the updater compares against the running system."""
    parts = version.split(".")
    if not 1 <= len(parts) <= 3 or not all(part.isdigit() for part in parts):
        raise ReleaseError(f"'{version}' is not a macOS version.")
    return ".".join(parts + ["0"] * (3 - len(parts)))


def validated(item: Item) -> Item:
    if item.channel not in (STABLE, TESTING):
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
    others = [existing for existing in items if build_key(existing.build) != build_key(item.build)]
    return prune(others + [item])


def _main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Plan release builds and maintain the update feed.")
    commands = parser.add_subparsers(dest="command", required=True)

    plan_parser = commands.add_parser("plan")
    plan_parser.add_argument("--ref-type", required=True, choices=["branch", "tag"])
    plan_parser.add_argument("--ref-name", required=True)
    plan_parser.add_argument("--describe", default="")
    plan_parser.add_argument("--newest-tag", default="")
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

    builds_parser = commands.add_parser("builds")
    builds_parser.add_argument("--appcast", required=True, type=Path)
    builds_parser.add_argument("--channel", required=True, choices=[STABLE, TESTING])

    args = parser.parse_args(argv)
    try:
        if args.command == "plan":
            project = args.project.read_text(encoding="utf-8")
            result = plan(args.ref_type, args.ref_name, args.describe,
                          project_setting(project, "MARKETING_VERSION"),
                          project_setting(project, "CURRENT_PROJECT_VERSION"),
                          args.newest_tag)
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
            for item in read_feed(args.appcast):
                if item.channel == args.channel:
                    print(item.build)
    except ReleaseError as error:
        print(f"release_feed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
