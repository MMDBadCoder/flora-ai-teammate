#!/usr/bin/env python3
"""Substitute {{VAR}} placeholders in a template with values from the environment.

Exits 3 and names every missing variable rather than emitting a half-rendered
file: a config that is silently wrong is much harder to debug than one that
refuses to be written.

Usage:  FLORA_TMPL=path/to/template.tmpl python3 render.py > output
"""
import os
import re
import sys

path = os.environ.get("FLORA_TMPL")
if not path:
    sys.exit("render.py: FLORA_TMPL is not set")

with open(path) as fh:
    src = fh.read()

missing = set()


def sub(match):
    key = match.group(1)
    val = os.environ.get(key)
    if val is None:
        missing.add(key)
        return match.group(0)
    return val


out = re.sub(r"\{\{([A-Z0-9_]+)\}\}", sub, src)

if missing:
    sys.stderr.write(
        "render.py: %s references unset variables: %s\n" % (path, ", ".join(sorted(missing)))
    )
    sys.exit(3)

sys.stdout.write(out)
