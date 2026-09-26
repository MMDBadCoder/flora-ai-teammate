#!/usr/bin/env python3
"""Reconcile Flora's shared skills across Hermes and OpenCode.

THE MODEL
---------
`shared/skills/<name>/SKILL.md` is the one real copy of every team skill. It is
git-tracked, reviewable and backed up. Both agents see that same directory
through symlinks, so a skill is never copied and the two agents can never drift:

    shared/skills/gerrit-change/SKILL.md          <- the file on disk
      state/hermes/home/skills/team               -> shared/skills      (whole tree)
      state/opencode/config/skills/gerrit-change  -> shared/skills/gerrit-change
      state/opencode/home/.claude/skills/...      -> same
      state/opencode/home/.agents/skills/...      -> same

Hermes groups skills as <category>/<skill>/SKILL.md and OpenCode expects a flat
<skill>/SKILL.md, which is why Hermes gets one symlink for the whole tree and
OpenCode gets one symlink per skill. Editing the file through either path edits
the same inode: "tell Hermes to change a skill" and OpenCode has already changed.

ADOPTION
--------
When an agent writes a brand new skill into its own directory instead of the
shared one, that directory is a real folder, not a symlink. This script moves it
into shared/skills and leaves a symlink behind, so skills the agents invent for
themselves join the team brain automatically on the next run.

Run with --check to report drift without touching anything (used by `flora doctor`).
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys

HOME = os.environ["FLORA_HOME"]
SHARED_ROOT = os.path.join(HOME, "shared")
SHARED = os.path.join(SHARED_ROOT, "skills")
HERMES_SKILLS = os.path.join(HOME, "state", "hermes", "home", "skills")
CATEGORY = os.environ.get("FLORA_HERMES_SKILL_CATEGORY", "team")
OC = os.path.join(HOME, "state", "opencode")

# Every place OpenCode looks for globally available skills. Writing to all of
# them costs nothing (they are symlinks) and means the sync keeps working if a
# future release changes which path wins.
OPENCODE_SKILL_DIRS = [
    os.path.join(OC, "config", "skills"),
    os.path.join(OC, "xdg", "config", "opencode", "skills"),
    os.path.join(OC, "home", ".claude", "skills"),
    os.path.join(OC, "home", ".agents", "skills"),
]

NAME_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")

changes = []
problems = []
QUIET = False


def say(msg, kind="ok"):
    if QUIET and kind == "same":
        return
    colors = {"ok": "\033[32m[ ok ]", "same": "\033[2m[same]", "warn": "\033[33m[warn]",
              "move": "\033[34m[move]", "fail": "\033[31m[fail]"}
    tty = sys.stdout.isatty()
    prefix = colors.get(kind, "[ ok ]") if tty else "[%s]" % kind
    reset = "\033[0m" if tty else ""
    print("%s%s %s" % (prefix, reset, msg))


def read_frontmatter(path):
    """Parse the YAML frontmatter far enough to validate it, without PyYAML."""
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        return None, str(exc)
    if not text.startswith("---"):
        return None, "no YAML frontmatter (the file must start with ---)"
    end = text.find("\n---", 3)
    if end == -1:
        return None, "frontmatter is never closed with ---"
    fields = {}
    for line in text[3:end].splitlines():
        if not line.strip() or line.startswith("#") or line.startswith(" "):
            continue
        if ":" in line:
            k, _, v = line.partition(":")
            fields[k.strip()] = v.strip().strip('"').strip("'")
    return fields, None


def lint(name, skill_dir):
    """Both agents must accept the same file, so validate against both rulesets."""
    md = os.path.join(skill_dir, "SKILL.md")
    if not os.path.isfile(md):
        problems.append("%s: no SKILL.md" % name)
        return False
    fields, err = read_frontmatter(md)
    if err:
        problems.append("%s: %s" % (name, err))
        return False
    fm_name = fields.get("name", "")
    desc = fields.get("description", "")
    if not fm_name:
        problems.append("%s: frontmatter has no 'name'" % name)
    elif fm_name != name:
        problems.append("%s: frontmatter name is '%s' but the directory is '%s' "
                        "(OpenCode keys skills by directory, Hermes by name)" % (name, fm_name, name))
    if not NAME_RE.match(name):
        problems.append("%s: invalid name -- use lowercase letters, digits and single hyphens" % name)
    if not desc:
        problems.append("%s: frontmatter has no 'description'; agents decide when to "
                        "load a skill from this line alone" % name)
    elif len(desc) > 1024:
        problems.append("%s: description is %d chars, over OpenCode's 1024 limit" % (name, len(desc)))
    return True


def shared_skills():
    if not os.path.isdir(SHARED):
        return []
    out = []
    for entry in sorted(os.listdir(SHARED)):
        p = os.path.join(SHARED, entry)
        if entry.startswith(".") or not os.path.isdir(p):
            continue
        out.append(entry)
    return out


def adopt_strays(check):
    """Move agent-authored skills out of the private dirs into shared/."""
    candidates = []

    # Hermes: any category other than the shared one is considered Hermes-local
    # (bundled or hub-installed) and is left alone unless explicitly exported.
    export_bundled = os.environ.get("FLORA_SKILLS_EXPORT_BUNDLED", "false") == "true"
    if os.path.isdir(HERMES_SKILLS):
        for cat in sorted(os.listdir(HERMES_SKILLS)):
            cat_path = os.path.join(HERMES_SKILLS, cat)
            if cat == CATEGORY or os.path.islink(cat_path) or not os.path.isdir(cat_path):
                continue
            if not export_bundled:
                continue
            for skill in sorted(os.listdir(cat_path)):
                p = os.path.join(cat_path, skill)
                if os.path.isdir(p) and os.path.isfile(os.path.join(p, "SKILL.md")):
                    candidates.append((skill, p))

    # OpenCode: a real directory here was written by OpenCode itself.
    for d in OPENCODE_SKILL_DIRS:
        if not os.path.isdir(d):
            continue
        for skill in sorted(os.listdir(d)):
            p = os.path.join(d, skill)
            if os.path.islink(p) or not os.path.isdir(p):
                continue
            if os.path.isfile(os.path.join(p, "SKILL.md")):
                candidates.append((skill, p))

    for name, path in candidates:
        target = os.path.join(SHARED, name)
        if os.path.exists(target):
            problems.append("%s exists in shared/skills AND as a real directory at %s -- "
                            "merge them by hand, then re-run" % (name, path))
            continue
        if check:
            changes.append("would adopt %s from %s" % (name, path))
            continue
        shutil.move(path, target)
        os.symlink(target, path)
        changes.append("adopted %s" % name)
        say("adopted %s into shared/skills (was written by the agent directly)" % name, "move")


def ensure_symlink(link, target, check):
    """Point `link` at `target`, replacing a wrong link. Never clobbers real data."""
    if os.path.islink(link):
        if os.path.realpath(link) == os.path.realpath(target):
            return False
        if check:
            changes.append("would repoint %s" % link)
            return True
        os.unlink(link)
    elif os.path.exists(link):
        problems.append("%s is a real path where a symlink belongs -- move it aside" % link)
        return False
    if check:
        changes.append("would link %s -> %s" % (link, target))
        return True
    os.makedirs(os.path.dirname(link), exist_ok=True)
    os.symlink(target, link)
    changes.append("linked %s" % os.path.basename(link))
    say("%s -> %s" % (link.replace(HOME, "."), target.replace(HOME, ".")))
    return True


def prune(d, valid, check):
    """Remove symlinks for skills that no longer exist."""
    if not os.path.isdir(d):
        return
    for entry in sorted(os.listdir(d)):
        p = os.path.join(d, entry)
        if not os.path.islink(p):
            continue
        inside_shared = os.path.realpath(p).startswith(os.path.realpath(SHARED))
        if entry in valid and os.path.exists(p):
            continue
        if not inside_shared and os.path.exists(p):
            continue  # someone else's symlink; leave it be
        if check:
            changes.append("would remove stale link %s" % p)
            continue
        os.unlink(p)
        changes.append("pruned %s" % entry)
        say("pruned stale link %s" % p.replace(HOME, "."), "move")


def git_commit(check):
    """Version the shared brain -- in shared/'s OWN repository, if it has one.

    The platform repository deliberately does not track shared/: both agents
    write there, and tracking live data in the repo you `git pull` from makes
    every upgrade collide with the platform's own data. Skill history is still
    worth having, so if someone runs `git init` inside shared/ this commits
    there. Without that, it does nothing and says nothing.
    """
    if check or os.environ.get("FLORA_SKILLS_GIT", "true") != "true":
        return
    if not os.path.isdir(os.path.join(SHARED_ROOT, ".git")):
        return
    try:
        status = subprocess.run(["git", "-C", SHARED_ROOT, "status", "--porcelain"],
                                capture_output=True, text=True, check=True).stdout.strip()
        if not status:
            return
        subprocess.run(["git", "-C", SHARED_ROOT, "add", "-A"], check=True, stdout=subprocess.DEVNULL)
        subprocess.run(["git", "-C", SHARED_ROOT,
                        "-c", "user.name=Flora", "-c", "user.email=flora@localhost",
                        "commit", "-q", "-m", "skills: sync shared brain"],
                       check=True, stdout=subprocess.DEVNULL)
        say("committed to shared/'s own git repository", "move")
    except (subprocess.CalledProcessError, FileNotFoundError) as exc:
        say("could not commit in shared/: %s" % exc, "warn")


def main():
    global QUIET
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true", help="report drift, change nothing")
    ap.add_argument("--quiet", action="store_true", help="only print changes and problems")
    ap.add_argument("--json", action="store_true", help="machine-readable summary")
    args = ap.parse_args()
    QUIET = args.quiet or args.json

    os.makedirs(SHARED, exist_ok=True)

    # 1. Pull agent-authored skills into the shared tree.
    adopt_strays(args.check)

    # 2. Hermes sees the whole shared tree as one category.
    if not args.check:
        os.makedirs(HERMES_SKILLS, exist_ok=True)
    ensure_symlink(os.path.join(HERMES_SKILLS, CATEGORY), SHARED, args.check)

    # 3. OpenCode sees one symlink per skill, in every directory it searches.
    names = shared_skills()
    for d in OPENCODE_SKILL_DIRS:
        if not args.check:
            os.makedirs(d, exist_ok=True)
        for name in names:
            ensure_symlink(os.path.join(d, name), os.path.join(SHARED, name), args.check)
        prune(d, set(names), args.check)

    # 4. Validate: a malformed skill is silently ignored by both agents, which
    #    is the single most confusing failure mode in this whole platform.
    for name in names:
        lint(name, os.path.join(SHARED, name))

    git_commit(args.check)

    if args.json:
        print(json.dumps({"skills": names, "changes": changes, "problems": problems}, indent=2))
    else:
        if not changes:
            say("%d shared skills, all in sync" % len(names), "same")
        else:
            say("%d shared skills, %d change(s)" % (len(names), len(changes)))
        for p in problems:
            say(p, "warn")

    if args.check and (changes or problems):
        return 1
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
