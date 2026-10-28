<!-- layout:managed. Source: dev-layout-kit\templates\AGENTS.md. Edit it there, then run Layout.ps1 scaffold -Go on each PC. -->
# Start here: the map

This file tells any agent (or person) where everything lives, so nobody has to search. Read it before you look for anything outside the folder you're in.

**Next:** open `INDEX.md` in this folder. It lists every project with its path, repo, host, status and drive folder. The synced drive has its own `INDEX.md` for documents. **Rules:** `CLAUDE.md` in this folder.

## The three homes

| Home | What lives there | Source of truth? |
|---|---|---|
| GitHub | All code | Yes, for code |
| This folder (the dev root) | Working copies of code, at the same path on every PC | No. Rebuildable from GitHub with `Layout.ps1 run -Go` |
| The synced drive | Documents, PDFs, decks, sheets, images, exports | Yes, for files |

Code never lives in the synced drive (apps can't run from it reliably), and documents don't go in repos.

## One set of domains everywhere

The same `NN-slug` folder names are used here and in the drive. To find anything, decide the domain, then open that domain's folder in the right home.

| Folder | Domain | What's in it | Here | In the drive |
|---|---|---|---|---|
| `00-inbox` | Inbox | Not filed yet | no | yes |
| `01-core` | Me | Personal site, bio, writing voice | yes | yes |
| `02-ai` | AI & Agents | Prompts, agent settings, review tooling | yes | yes |
| `03-work` | Day job | Employer code and data | **work PC only** | **never** |
| `04-business` | Business | Client sites (`clients\`), client files | yes | yes |
| `05-products` | Products | Apps and tools other people use | yes | yes |
| `06-money` | Money | Taxes, statements, finance tools | yes | yes, **private** |
| `07-creative` | Writing & Creative | Blog, writing, video | yes | yes |
| `08-life` | Home & Play | Hobbies, games, photos | yes | yes (photos private) |
| `09-stack` | Tech Stack | Machine setup, infrastructure scripts | yes | yes |

Inside a domain, the same sub-name means the same thing in both homes. A client's site code is `04-business\clients\<repo>` here; its quotes and contracts are `04-business\clients\<client>` in the drive. INDEX.md links the two.

## Fast paths

- **A project's code, repo or host:** its row in `INDEX.md`.
- **Where a project stands and what's next:** the hub folder (`notes\`), then the project's README.
- **Something just downloaded:** `Downloads` is an inbox. File it within a week.
