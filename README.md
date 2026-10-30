# dev-layout-kit

One folder layout on every PC, built and kept in order by one PowerShell script.

I work across three Windows machines: a laptop, a work PC and a desktop at home. Projects were in different places on each one. Documents ended up in repos. AI agents had to search before they could start. This kit fixed that. The same numbered domain folders exist on every machine and in the synced drive. Every project has one home. An `INDEX.md` at the top tells an agent where everything is before it starts looking.

## How it works

- **`standard.json`** defines the layout: the domains (`01-core`, `04-business` and so on), the folders inside each one, which drive folders are private, and which domains exist on one machine only.
- **`projects.json`** lists every project: its location under the dev root, its repo, host and status, and the matching drive folder.
- **`Layout.ps1`** builds the layout, moves projects into it, clones what's missing from GitHub, installs the `AGENTS.md` and `CLAUDE.md` files from `templates\`, and writes `INDEX.md`.
- **`templates\`** holds the map and rules files an agent reads first. A file is only replaced if it has the `layout:managed` marker. Files you wrote by hand are never overwritten.

Everything is a dry run until you add `-Go`. Every change is logged to `_system\logs`. The `undo` mode reads that log to put things back.

## Modes

| Mode | What it does |
|---|---|
| `run` | All of it, in order: scaffold, plan, apply, templates, index. |
| `scaffold` | Creates the domain folders in the dev root and the synced drive, and installs the templates. |
| `plan` | Compares `projects.json` with this PC and writes a move list to `_system\manifests\pending`: move a project found in the wrong place, clone one that's missing, note one that only exists on another PC. |
| `apply` | Carries out every manifest in `pending` (or `-Manifest <file>`). |
| `undo` | Reverses the latest run from its log (or `-Log <file>`). |
| `index` | Rewrites `INDEX.md` in the dev root and in the drive, plus `_system\index.json`. |
| `venvs` | Lists Python venvs that broke because their folder moved. `-Go` rebuilds them. |

## Try it on a scratch folder

Run these from this folder in PowerShell 7 or Windows PowerShell 5.1:

```powershell
New-Item -ItemType Directory -Force $env:TEMP\layout-demo\drive | Out-Null
.\Layout.ps1 run -DevRoot $env:TEMP\layout-demo\dev -DriveRoot $env:TEMP\layout-demo\drive        # preview
.\Layout.ps1 run -DevRoot $env:TEMP\layout-demo\dev -DriveRoot $env:TEMP\layout-demo\drive -Go    # build it
```

That builds the example layout, clones the public projects in the example `projects.json` into their domain folders, and writes `INDEX.md`. Open `$env:TEMP\layout-demo\dev\INDEX.md`. That's what an agent reads first.

## Use it for real

1. Edit `standard.json`: your `devRoot`, your synced drive's `driveRoot`, your domains. Give a domain `"onlyOn": ["MACHINE-NAME"]` if it must exist on one machine only (day-job code that should never sync, for example). It's skipped everywhere else and left out of the index.
2. Add a row to `projects.json` for each project.
3. Close VS Code so no project folder is held open. Run `.\Layout.ps1 run`, read the preview, then run it again with `-Go`.
4. On each other PC, clone this kit and run the same two commands. Projects with a repo are cloned into place. Projects without one are listed as living on one PC only.
5. After you add or move a project: `.\Layout.ps1 index -Go`.

## Manifests

For one-off clean-ups, write a CSV with `action,source,dest,note` and drop it in `_system\manifests\pending`. Use it for a messy Desktop, a Downloads folder or files in the wrong drive folder. `examples\manifest-example.csv` shows every action:

- `mkdir`: make a folder.
- `move`: move a file or folder. A source can end in a wildcard (`G:\My Drive\Acme*`). A folder merges into an existing one of the same name. If a file's name is already taken, it's recycled if it's an identical copy and left alone if it isn't.
- `recycle`: send to the Recycle Bin (or the drive's trash).
- `recycle-dup`: recycle the source only if it's byte-identical to the dest.
- `clone`: `git clone` a repo into place.
- `prune`: remove a folder only if nothing but empty folders is left in it.
- `note`: just log a line.

Manifests are per machine and usually name personal files. That's why `_system\` stays out of git.

## What it won't do

- Run git, other than `git clone` for a missing project.
- Move a folder something has open. A same-drive move is one rename, all or nothing. A cross-drive move copies, checks the file count, and only then removes the source.
- Overwrite a file you wrote. Templates need the `layout:managed` marker to be replaced.

## Limits

- Windows-first. It uses `robocopy`, the Recycle Bin and the `py` launcher. It runs elsewhere, but "recycle" is a plain delete there.
- Recycling goes through the Windows shell with prompts off. An item too big for the Recycle Bin is probably deleted outright. Keep very large folders out of manifests.
- `venvs -Go` deletes a broken venv before rebuilding it. If that Python version isn't installed, the venv is gone until you install it.
- Aliases match without regard to case.

## License

MIT. See `LICENSE`.
