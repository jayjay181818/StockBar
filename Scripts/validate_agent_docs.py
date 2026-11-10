#!/usr/bin/env python3
"""Check shared instruction links and duplication; size thresholds are advisory."""
import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
SKIP = {'.git', 'build', 'DerivedData', '.build', 'Pods', 'node_modules', '.venv', 'venv'}


def instruction_files(root):
    # Avoid walking build products and dependency trees at all.
    import os
    result = []
    for directory, names, files in os.walk(root):
        names[:] = [name for name in names if name not in SKIP and not name.startswith('.')]
        for name in files:
            if name in ('AGENTS.md', 'AGENTS.override.md', 'CLAUDE.md', 'GEMINI.md') or name.endswith('_AGENTS.md'):
                result.append(Path(directory) / name)
    return sorted(result)


def validate(root):
    errors, warnings = [], []
    instructions = instruction_files(root)
    references = [root / p for p in ('Docs/Architecture.md', 'Docs/Development.md', 'Scripts/README.md')]
    for path in instructions:
        if path.name.endswith('_AGENTS.md'):
            errors.append(f'{path.relative_to(root)}: use one canonical AGENTS.md per directory')
        if path.name == 'AGENTS.override.md' and (path.parent / 'AGENTS.md').exists():
            warnings.append(f'{path.relative_to(root)} shadows AGENTS.md; confirm this is intentional')
        limit = 4000 if path == root / 'AGENTS.md' else 1500
        if path.name in ('CLAUDE.md', 'GEMINI.md'):
            limit = 700
        count = len(path.read_text(encoding='utf-8'))
        if count > limit:
            warnings.append(f'{path.relative_to(root)}: {count} characters exceeds review target {limit}; retain necessary safeguards')
    for path in instructions + [p for p in references if p.exists()]:
        # Check inline Markdown file links, excluding examples inside fenced code.
        text = re.sub(r'```.*?```', '', path.read_text(encoding='utf-8'), flags=re.S)
        for destination in re.findall(r'\[[^\]]*\]\(([^)]+)\)', text):
            target = destination.strip().strip('<>')
            if urlsplit(target).scheme or target.startswith('#'):
                continue
            local = unquote(target.split('#', 1)[0])
            if not (path.parent / local).exists():
                errors.append(f'{path.relative_to(root)}: broken file link {destination}')
    total = sum(len(p.read_text(encoding='utf-8')) for p in instructions)
    return errors, warnings, len(instructions), total


def version_errors(root):
    """The version is written in the project, the README and the release notes.

    A release that updates only some of them ships an app whose About box,
    README and notes disagree.
    """
    project = (root / 'Stockbar.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
    marketing = set(re.findall(r'MARKETING_VERSION = ([0-9.]+);', project))
    builds = set(re.findall(r'CURRENT_PROJECT_VERSION = ([0-9]+);', project))
    errors = []
    if len(marketing) != 1:
        return [f'project.pbxproj: MARKETING_VERSION differs between configurations: {sorted(marketing)}']
    if len(builds) != 1:
        errors.append(f'project.pbxproj: CURRENT_PROJECT_VERSION differs between configurations: {sorted(builds)}')
    version = marketing.pop()
    readme = (root / 'README.md').read_text(encoding='utf-8')
    footer = re.search(r'Last updated: [^·<]*· Version ([0-9.]+)', readme)
    if not footer or footer.group(1) != version:
        found = footer.group(1) if footer else 'none'
        errors.append(f'README.md: footer version is {found}, project is {version}')
    if not re.search(rf'^### .*Version {re.escape(version)}\b', readme, flags=re.M):
        errors.append(f'README.md: no release-history entry for version {version}')
    if not (root / f'Changelogs/release_notes_v{version}.md').exists():
        errors.append(f'Changelogs/release_notes_v{version}.md is missing')
    return errors


def main():
    errors, warnings, count, total = validate(ROOT)
    errors += version_errors(ROOT)
    for warning in warnings:
        print(f'WARNING: {warning}')
    for error in errors:
        print(f'ERROR: {error}', file=sys.stderr)
    print(f'Instruction docs: {count} files, {total} characters (~{round(total / 4)} tokens; estimate only).')
    if not errors:
        print('Documentation validation passed')
    return bool(errors)


if __name__ == '__main__':
    sys.exit(main())
