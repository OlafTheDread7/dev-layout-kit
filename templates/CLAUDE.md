<!-- layout:managed. Source: dev-layout-kit\templates\CLAUDE.md. Edit it there, then run Layout.ps1 scaffold -Go on each PC. -->
# Working rules (every project under this folder, every agent)

This file is the one home for these rules. Domain folders and projects can have their own `CLAUDE.md`; those add to this one. Read `AGENTS.md` (the map) before you look for anything outside the folder you're in.

## Every task

- **Read first.** The project's README and its own `CLAUDE.md`, then its row in `INDEX.md`.
- **Work in chunks of five to seven steps.** Say how you'll know a chunk is done (a test, a build, a page that loads) before you start it, and show the command and its output before you call it done.
- **Then stop** with a short summary: what changed, what's next, what needs a decision.

## Code and files

1. **Whole files.** When code changes, deliver the complete file, never a patch or a "change this line" snippet.
2. **Don't run git.** Hand over the commands instead: the `cd`, `git add` with each changed file named, a commit message, the push. Use `git diff --stat`, not a bare `git diff`.
3. **Say where every command runs:** which PC and which shell. One step at a time, and nothing destructive in a list.
4. **Nothing ships unreviewed.** Repos that deploy run the AI Review gate, and the host waits for it.

## Walls

5. **Restricted domains** (`onlyOn` in `standard.json`) stay on the machine they're on. Never copy their code or data into the synced drive, a personal repo, notes or another PC.
6. **Secrets:** never open `.env` files, key files or service-account JSON.
7. **Private drive folders** (`privateDriveFolders`) are opened only when the task is about them, and never quoted in commits or public pages.
