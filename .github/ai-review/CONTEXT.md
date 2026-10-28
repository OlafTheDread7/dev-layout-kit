# dev-layout-kit: notes for the reviewer

Public repo. A PowerShell script (`Layout.ps1`) that builds one folder layout on a Windows PC from `standard.json` and `projects.json`, moves project folders into it, clones missing repos with `git clone`, installs instruction files from `templates/`, and writes `INDEX.md`. Nothing here deploys.

- Everything is a dry run unless `-Go` is passed. Moves and recycles are logged to `<devRoot>\_system\logs`, which `undo` reads.
- Manifests (`examples/manifest-example.csv`) are CSVs the user writes; their paths come from the user, not from the network.
- The JSON files and templates are examples with made-up projects. The public repos in `projects.json` belong to the author.

What matters most: anything that could delete instead of recycle, move outside the paths given, or follow a path from a file it didn't expect. The known limit that an item too big for the Recycle Bin may be deleted outright is documented in the README.
