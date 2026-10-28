<!-- layout:managed. Source: dev-layout-kit\templates\04-business\CLAUDE.md. Edit it there, then run Layout.ps1 scaffold -Go. -->
# 04-business: client work

Client site code is in `clients\<repo>`. Quotes, contracts and reports are in the synced drive under `04-business\clients\<client>\`.

- Static sites deploy on Vercel and every one has a `.vercelignore`, so notes and CI files are never served.
- Client names, pricing and contact details stay out of commit messages and public pages.
- A new client site gets a row in `projects.json` the day it's created.
