---
name: skill-authoring
description: Use when asked to create, edit or refactor a Flora skill.
version: 1.0.0
metadata:
  hermes:
    tags: [meta, skills]
    category: team
---

# Writing a skill both agents can read

## When to use

"Remember how to do X", "write a skill for Y", "that was painful, save it", or
when you notice you have solved the same non-obvious problem twice.

## Procedure

1. Create the directory and file:
   ```bash
   bin/flora skills new <name>          # lowercase-with-hyphens
   ```
   It lands in `shared/skills/<name>/SKILL.md`, which is the one real copy both
   Hermes and OpenCode read through symlinks.

2. Frontmatter -- these two fields are the contract with both agents:
   ```yaml
   ---
   name: <exactly the directory name, lowercase-with-hyphens>
   description: <one line naming WHEN to use this>
   version: 1.0.0
   metadata:
     hermes:
       tags: [team]
       category: team
   ---
   ```
   `description` is the only thing an agent sees when deciding whether to load
   the skill. Name the trigger situation, not the topic.

3. Body sections, in this order: **When to use**, **Procedure**, **Pitfalls**,
   **Verification**. Procedures are numbered and contain literal commands.

4. Publish:
   ```bash
   bin/flora skills sync
   ```
   Both agents see it immediately; the change is committed to git.

## Pitfalls

- A `name` that differs from the directory name: OpenCode keys skills by
  directory and Hermes by frontmatter, so they disagree and the skill half-works.
- Malformed frontmatter makes the skill **silently invisible** to both agents.
  `bin/flora skills lint` catches it.
- Writing what the code already says. A skill is for what the code does not tell
  you: the flag that is always needed, the step everyone forgets.
- Secrets, hostnames or customer names in a skill. It is committed to git.

## Verification

```bash
bin/flora skills lint && bin/flora skills list
```
The skill appears with its description, and lint reports no problems.
