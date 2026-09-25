---
name: confluence-docs
description: Use when asked to read, write or update a Confluence page.
version: 1.0.0
metadata:
  hermes:
    tags: [confluence, docs]
    category: team
---

# Editing Confluence

## When to use

"Document this", "update the runbook", "what does the onboarding page say",
"add a section to the architecture page".

## Procedure

1. **Find the page** before writing anything:
   ```bash
   scripts/integrations/confluence.py search "runbook deploy"
   scripts/integrations/confluence.py get ENG:Deployment Runbook
   ```
2. **Read the whole current page.** Editing a page you have not read is how
   sections get silently deleted.
3. **Write the new content to a file** in `/tmp`, in Markdown.
4. **Update, do not replace, unless asked:**
   ```bash
   scripts/integrations/confluence.py append <page-id> /tmp/section.md
   scripts/integrations/confluence.py update <page-id> /tmp/page.md
   ```
   `update` replaces the body entirely; `append` adds to the end.
5. **New pages** need a space and a parent:
   ```bash
   scripts/integrations/confluence.py create ENG "Title" /tmp/page.md --parent <id>
   ```
6. Report the page URL that the command prints.

## Pitfalls

- Confluence rejects an update whose version number is not exactly one higher
  than the current one. That error means somebody else edited the page while you
  worked: re-read it and redo your edit on top.
- Say in chat which page you are about to change before changing a page that
  belongs to someone else.
- Never paste credentials, tokens or customer data into a page.

## Verification

`confluence.py get <page-id>` and check the version number went up by one and
your section is present and nothing else vanished.
