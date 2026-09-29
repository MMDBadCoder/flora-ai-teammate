#!/usr/bin/env python3
"""Check that every path the generated nginx config names actually exists.

`nginx -t` proves the syntax parses; it says nothing about whether the files
referenced are there. A vhost pointing at a password file that was never created
starts perfectly and then answers 403 to every login, right or wrong -- a status
code that describes nothing useful and reads as a corrupted install.

So this walks the config, following include directives, and reports:

  auth_basic_user_file   must exist and be non-empty (missing -> 403 on every
                         credential; empty -> the same, with no user to match)
  root + index           the document root must exist and contain the index file
                         (missing index -> 403, because autoindex is off)
  include                must exist, or nginx will not start at all

Exits non-zero with one problem per line on stdout.
"""
import os
import re
import sys

DIRECTIVE = re.compile(r'^\s*(auth_basic_user_file|root|include|index)\s+([^;]+);', re.M)


def scan(path, seen, roots, auth_files, includes, indexes):
    if path in seen:
        return
    seen.add(path)
    try:
        text = open(path).read()
    except OSError:
        return
    for name, value in DIRECTIVE.findall(text):
        value = value.strip()
        if name == "include":
            includes.append(value)
            if value.startswith("/") and "*" not in value:
                scan(value, seen, roots, auth_files, includes, indexes)
        elif name == "auth_basic_user_file":
            auth_files.append(value)
        elif name == "root":
            roots.append(value)
        elif name == "index":
            indexes.extend(value.split())


def main():
    conf = sys.argv[1]
    roots, auth_files, includes, indexes = [], [], [], []
    scan(conf, set(), roots, auth_files, includes, indexes)

    problems = []

    for f in sorted(set(includes)):
        if not f.startswith("/") or "*" in f:
            continue
        if not os.path.exists(f):
            problems.append("config includes a file that is not there: %s" % f)

    for f in sorted(set(auth_files)):
        if not os.path.exists(f):
            problems.append(
                "the account file %s does not exist -- nginx will prompt and then "
                "refuse EVERY login with 403" % f)
        elif os.path.getsize(f) == 0:
            problems.append(
                "the account file %s is empty -- no login can succeed" % f)
        elif not (os.stat(f).st_mode & 0o004):
            problems.append(
                "the account file %s is not readable by nginx -- logins fail with 500" % f)

    for d in sorted(set(roots)):
        if not os.path.isdir(d):
            problems.append("document root %s does not exist" % d)
            continue
        if not (os.stat(d).st_mode & 0o001):
            problems.append("document root %s is not traversable by nginx" % d)
        # autoindex is off, so a root with no index file answers 403.
        if indexes and not any(os.path.exists(os.path.join(d, i)) for i in set(indexes)):
            problems.append(
                "%s contains none of the index files %s -- requests for / answer 403"
                % (d, ", ".join(sorted(set(indexes)))))

    if problems:
        print("\n".join(problems))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
