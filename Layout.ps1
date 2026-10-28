<#
.SYNOPSIS
    One filing layout on every PC: builds the same folder tree, moves projects into it,
    clones what's missing, and keeps an index (INDEX.md) that any AI agent can read first.

.DESCRIPTION
    run       Everything below, in order: scaffold, plan, apply, templates, index.
              A dry run unless you add -Go. The dry run changes nothing and writes a
              full preview to <devRoot>\_system\logs\dryrun-<time>.csv.
    scaffold  Creates the domain folders (standard.json) in the dev root and the synced drive and
              installs the root AGENTS.md / CLAUDE.md and the per-domain CLAUDE.md files.
    plan      Compares projects.json with this PC and writes a repo-move manifest to
              <devRoot>\_system\manifests\pending.
    apply     Carries out every manifest in manifests\pending (or -Manifest <file>).
    undo      Moves everything in the latest log back (or -Log <file>).
    index     Rewrites <devRoot>\INDEX.md, <devRoot>\_system\index.json and <driveRoot>\INDEX.md.
    venvs     Lists Python venvs that broke because their folder moved. -Go rebuilds them.

    On Windows nothing is deleted outright: local items go to the Recycle Bin, and items
    in a synced drive (Google Drive for Desktop and the like) go to that drive's trash.
    Elsewhere "recycle" is a plain delete. Every change is logged to <devRoot>\_system\logs,
    which is what undo reads. The only git it ever runs is `git clone`, for a project that
    is missing on this PC.

.EXAMPLE
    cd C:\code\dev-layout-kit
    .\Layout.ps1 run          # preview
    .\Layout.ps1 run -Go      # do it
    .\Layout.ps1 undo -Go     # put the last run back
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('run', 'scaffold', 'plan', 'apply', 'undo', 'index', 'venvs')]
    [string]$Mode = 'run',
    [switch]$Go,
    [string]$Manifest,
    [string]$Log,
    [string]$DevRoot,
    [string]$DriveRoot,
    [string]$Computer
)

$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot

# PowerShell's `cd` doesn't change the process's real working folder, and Windows won't
# let anyone move a folder that a process is "standing in". If this window was opened
# inside a project (say C:\dev\my-site), that project couldn't move. Step out of it.
try { [Environment]::CurrentDirectory = [Environment]::GetFolderPath('UserProfile') } catch { }
$DryRun = -not $Go
$sep = [IO.Path]::DirectorySeparatorChar

function Read-Json([string]$name) {
    $p = Join-Path $Here $name
    if (-not (Test-Path -LiteralPath $p)) { throw "Missing $p" }
    return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json)
}

$std = Read-Json 'standard.json'
$reg = Read-Json 'projects.json'
if (-not $DevRoot) { $DevRoot = $std.devRoot }
if (-not $DriveRoot) { $DriveRoot = $std.driveRoot }
$pc = $Computer
if (-not $pc) { $pc = $env:COMPUTERNAME }
if (-not $pc) { $pc = [System.Net.Dns]::GetHostName() }
$pc = $pc.ToUpper()
# A domain with "onlyOn": ["WORKPC"] exists on those machines and nowhere else (day-job
# code that must never sync, say). It is skipped on every other PC and left out of the index.
$restrictedFolders = @($std.domains | Where-Object { $_.onlyOn } | ForEach-Object { $_.folder })
$restrictedHere = @($std.domains | Where-Object { $_.onlyOn -and (@($_.onlyOn | ForEach-Object { "$_".ToUpper() }) -contains $pc) } | ForEach-Object { $_.folder })
$haveDrive = Test-Path -LiteralPath $DriveRoot -PathType Container

# Paths in the JSON files use backslashes; make them work on whatever runs this.
function Fix([string]$p) {
    if ($null -eq $p) { return $null }
    return ($p -replace '[\\/]', [string]$sep)
}
function Join-Rel([string]$base, [string]$rel) {
    if (-not $rel) { return $base }
    return (Join-Path $base (Fix $rel)).TrimEnd($sep)
}

$sysDir = Join-Rel $DevRoot '_system'
$pendingDir = Join-Rel $sysDir 'manifests\pending'
$doneDir = Join-Rel $sysDir 'manifests\done'
$logDir = Join-Rel $sysDir 'logs'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

# ---------------------------------------------------------------- logging

$script:LogFile = $null
$script:Counts = @{}
$script:Rows = New-Object System.Collections.Generic.List[object]

function Start-Log([string]$kind) {
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $script:LogFile = Join-Path $logDir ("{0}-{1}.csv" -f $kind, $stamp)
    '"time","action","source","dest","status","detail"' | Set-Content -LiteralPath $script:LogFile -Encoding UTF8
}

function Write-Row([string]$action, [string]$src, [string]$dst, [string]$status, [string]$detail) {
    $o = [pscustomobject]@{
        time   = (Get-Date -Format 's')
        action = $action
        source = $src
        dest   = $dst
        status = $status
        detail = $detail
    }
    $script:Rows.Add($o)
    if ($script:Counts.ContainsKey($status)) { $script:Counts[$status]++ } else { $script:Counts[$status] = 1 }
    if ($script:LogFile) {
        $line = ($o | ConvertTo-Csv -NoTypeInformation | Select-Object -Skip 1)
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    }
    $loud = @('FAILED', 'CONFLICT', 'PARTIAL', 'MISSING', 'WARN')
    if ($loud -contains $status) {
        Write-Host ("  {0,-9} {1}" -f $status, $src) -ForegroundColor Yellow
        if ($detail) { Write-Host ("            {0}" -f $detail) -ForegroundColor DarkYellow }
    }
}

function Write-Counts([string]$title) {
    Write-Host ''
    Write-Host $title -ForegroundColor Cyan
    foreach ($k in ($script:Counts.Keys | Sort-Object)) { Write-Host ("  {0,-13} {1}" -f $k, $script:Counts[$k]) }
}

# ---------------------------------------------------------------- file helpers

$script:CanRecycle = $false
if ($env:OS -eq 'Windows_NT') {
    try { Add-Type -AssemblyName Microsoft.VisualBasic; $script:CanRecycle = $true } catch { $script:CanRecycle = $false }
}

function Test-OnDrive([string]$p) {
    if (-not $DriveRoot) { return $false }
    $r1 = [IO.Path]::GetPathRoot($p)
    $r2 = [IO.Path]::GetPathRoot($DriveRoot)
    return ($r1 -and $r2 -and [string]::Equals($r1, $r2, [StringComparison]::OrdinalIgnoreCase) -and $r1 -ne [string]$sep)
}

function Test-SameVolume([string]$a, [string]$b) {
    $ra = [IO.Path]::GetPathRoot($a)
    $rb = [IO.Path]::GetPathRoot($b)
    return [string]::Equals($ra, $rb, [StringComparison]::OrdinalIgnoreCase)
}

# Recycle Bin on local disks; the synced drive's own trash for anything under driveRoot.
function Remove-ToBin([string]$p) {
    $isDir = Test-Path -LiteralPath $p -PathType Container
    if ($script:CanRecycle -and -not (Test-OnDrive $p)) {
        $ui = [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs
        $bin = [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
        if ($isDir) { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($p, $ui, $bin) }
        else { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($p, $ui, $bin) }
    } else {
        Remove-Item -LiteralPath $p -Recurse -Force
    }
}

function Get-Hash([string]$p) { return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash }

function New-Parent([string]$p) {
    $parent = Split-Path -Parent $p
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
}

# Folder moves between drives (C: <-> H:) can't be a rename: copy everything, check the
# copy is complete, and only then remove the source. A failed copy leaves the source whole.
function Move-DirAcross([string]$src, [string]$dst) {
    $want = @(Get-ChildItem -LiteralPath $src -Recurse -Force -File -ErrorAction Stop).Count
    $rc = Get-Command robocopy -ErrorAction SilentlyContinue
    if ($rc) {
        & robocopy $src $dst /E /COPY:DAT /DCOPY:T /R:1 /W:1 /NP /NFL /NDL /NJH /NJS | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "copy failed (robocopy exit $LASTEXITCODE); the source is untouched" }
    } else {
        Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
    }
    $got = @(Get-ChildItem -LiteralPath $dst -Recurse -Force -File -ErrorAction SilentlyContinue).Count
    if ($got -lt $want) { throw "copy incomplete ($got of $want files); the source is untouched" }
    Remove-Item -LiteralPath $src -Recurse -Force
}

# Same drive: one rename, all or nothing. If anything inside is open, nothing moves.
function Move-DirSame([string]$src, [string]$dst) {
    try { [System.IO.Directory]::Move($src, $dst) }
    catch {
        $msg = $_.Exception.Message
        if ($_.Exception.InnerException) { $msg = $_.Exception.InnerException.Message }
        throw "$msg Something has this folder open (VS Code, a terminal or File Explorer window inside it, a running server). Close it and run again; nothing was moved."
    }
}

# Moves one file or folder. Folders merge into an existing folder of the same name.
# A file whose name is already taken is recycled if it's an identical copy and left
# alone (CONFLICT) if it isn't.
function Move-Entry([string]$src, [string]$dst) {
    if (-not (Test-Path -LiteralPath $src)) { Write-Row 'move' $src $dst 'GONE' 'source not found'; return }
    $srcIsDir = Test-Path -LiteralPath $src -PathType Container
    if (Test-Path -LiteralPath $dst) {
        $dstIsDir = Test-Path -LiteralPath $dst -PathType Container
        if ($srcIsDir -and $dstIsDir) {
            foreach ($child in @(Get-ChildItem -LiteralPath $src -Force)) {
                Move-Entry $child.FullName (Join-Path $dst $child.Name)
            }
            if ($DryRun) { return }
            if (-not (Get-ChildItem -LiteralPath $src -Force | Select-Object -First 1)) {
                Remove-Item -LiteralPath $src -Force -Recurse
                Write-Row 'merge' $src $dst 'MERGED' 'folder merged into the existing one'
            } else {
                Write-Row 'merge' $src $dst 'PARTIAL' 'some items could not merge and are still here'
            }
            return
        }
        if (-not $srcIsDir -and -not $dstIsDir) {
            if ($DryRun) { Write-Row 'move' $src $dst 'WOULD-CHECK' 'name already there: recycled if identical, else left in place'; return }
            try {
                if ((Get-Hash $src) -eq (Get-Hash $dst)) {
                    Remove-ToBin $src
                    Write-Row 'dedupe' $src $dst 'DEDUPED' 'identical copy already there; this one recycled'
                } else {
                    Write-Row 'move' $src $dst 'CONFLICT' 'a different file with this name is already there; left in place'
                }
            } catch { Write-Row 'move' $src $dst 'FAILED' $_.Exception.Message }
            return
        }
        Write-Row 'move' $src $dst 'CONFLICT' 'a file and a folder share this name; left in place'
        return
    }
    if ($DryRun) { Write-Row 'move' $src $dst 'WOULD-MOVE' ''; return }
    try {
        New-Parent $dst
        if ($srcIsDir -and -not (Test-SameVolume $src $dst)) { Move-DirAcross $src $dst }
        elseif ($srcIsDir) { Move-DirSame $src $dst }
        else { Move-Item -LiteralPath $src -Destination $dst -Force:$false }
        Write-Row 'move' $src $dst 'MOVED' ''
    } catch {
        Write-Row 'move' $src $dst 'FAILED' $_.Exception.Message
    }
}

# A manifest source may end in a wildcard (Drive\Clients\Acme*); expand it at run time.
function Expand-Source([string]$src) {
    $leaf = Split-Path -Leaf $src
    if ($leaf -match '[\*\?]') {
        $parent = Split-Path -Parent $src
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { return @() }
        return @(Get-ChildItem -LiteralPath $parent -Filter $leaf -Force | ForEach-Object { $_.FullName })
    }
    return @($src)
}

function Resolve-Dest([string]$item, [string]$dest, [bool]$wild) {
    if ($wild -or $dest.EndsWith('\') -or $dest.EndsWith('/')) {
        return (Join-Path $dest.TrimEnd('\', '/') (Split-Path -Leaf $item))
    }
    return $dest
}

# ---------------------------------------------------------------- manifests

function Invoke-Manifest([string]$path) {
    Write-Host ''
    Write-Host ("Manifest: {0}" -f $path) -ForegroundColor White
    $rows = @(Import-Csv -LiteralPath $path -Encoding UTF8)
    $claimed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($r in $rows) {
        $action = ($r.action + '').Trim().ToLower()
        if (-not $action -or $action.StartsWith('#')) { continue }
        $src = Fix $r.source
        $dst = Fix $r.dest
        try { Invoke-Row $r $action $src $dst $claimed }
        catch { Write-Row $action $src $dst 'FAILED' $_.Exception.Message }
    }
}

function Invoke-Row($r, [string]$action, [string]$src, [string]$dst, $claimed) {
        switch ($action) {
            'mkdir' {
                if (Test-Path -LiteralPath $dst) { continue }
                if ($DryRun) { Write-Row 'mkdir' '' $dst 'WOULD-MAKE' '' }
                else { New-Item -ItemType Directory -Path $dst -Force | Out-Null; Write-Row 'mkdir' '' $dst 'MADE' '' }
            }
            'move' {
                $leaf = Split-Path -Leaf $src
                $wild = $leaf -match '[\*\?]'
                foreach ($s in (Expand-Source $src)) {
                    if (-not $claimed.Add($s)) { continue }
                    Move-Entry $s (Resolve-Dest $s $dst $wild)
                }
            }
            'recycle' {
                foreach ($s in (Expand-Source $src)) {
                    if (-not $claimed.Add($s)) { continue }
                    if (-not (Test-Path -LiteralPath $s)) { Write-Row 'recycle' $s '' 'GONE' 'not found'; continue }
                    if ($DryRun) { Write-Row 'recycle' $s '' 'WOULD-RECYCLE' $r.note; continue }
                    try { Remove-ToBin $s; Write-Row 'recycle' $s '' 'RECYCLED' $r.note }
                    catch { Write-Row 'recycle' $s '' 'FAILED' $_.Exception.Message }
                }
            }
            'recycle-dup' {
                # source is a copy of dest (the one kept); recycled only if byte-identical
                if (-not $claimed.Add($src)) { continue }
                if (-not (Test-Path -LiteralPath $src)) { Write-Row 'dedupe' $src $dst 'GONE' 'not found'; continue }
                if (-not (Test-Path -LiteralPath $dst)) { Write-Row 'dedupe' $src $dst 'KEPT' 'the original is missing, so this copy stays'; [void]$claimed.Remove($src); continue }
                if ($DryRun) { Write-Row 'dedupe' $src $dst 'WOULD-CHECK' 'recycled if identical to the original'; continue }
                try {
                    if ((Get-Hash $src) -eq (Get-Hash $dst)) { Remove-ToBin $src; Write-Row 'dedupe' $src $dst 'DEDUPED' 'identical to the original; recycled' }
                    else { Write-Row 'dedupe' $src $dst 'KEPT' 'not identical to the original; kept'; [void]$claimed.Remove($src) }
                } catch { Write-Row 'dedupe' $src $dst 'FAILED' $_.Exception.Message }
            }
            'clone' {
                if (Test-Path -LiteralPath $dst) { continue }
                if ($DryRun) { Write-Row 'clone' $r.source $dst 'WOULD-CLONE' ''; continue }
                if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Write-Row 'clone' $r.source $dst 'FAILED' 'git not found'; continue }
                New-Parent $dst
                & git clone --quiet $r.source $dst 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { Write-Row 'clone' $r.source $dst 'CLONED' '' }
                else { Write-Row 'clone' $r.source $dst 'FAILED' "git clone exited $LASTEXITCODE" }
            }
            'prune' {
                # remove a folder only if nothing but empty folders is left in it
                if (-not (Test-Path -LiteralPath $src -PathType Container)) { continue }
                $files = @(Get-ChildItem -LiteralPath $src -Recurse -Force -File -ErrorAction SilentlyContinue)
                if ($files.Count -gt 0) { Write-Row 'prune' $src '' 'KEPT' "$($files.Count) file(s) still inside"; continue }
                if ($DryRun) { Write-Row 'prune' $src '' 'WOULD-PRUNE' 'empty'; continue }
                try { Remove-Item -LiteralPath $src -Recurse -Force; Write-Row 'prune' $src '' 'PRUNED' 'empty folder removed' }
                catch { Write-Row 'prune' $src '' 'FAILED' $_.Exception.Message }
            }
            'note' { Write-Row 'note' $src $dst 'NOTE' $r.note }
            default { Write-Row $action $src $dst 'WARN' "unknown action '$action'" }
        }
}

function Get-PendingManifests {
    if ($Manifest) { return @((Resolve-Path -LiteralPath $Manifest).Path) }
    if (-not (Test-Path -LiteralPath $pendingDir)) { return @() }
    # repo moves first, then everything else, each group by name
    $all = @(Get-ChildItem -LiteralPath $pendingDir -Filter '*.csv' | Sort-Object Name)
    $repos = @($all | Where-Object { $_.Name -like '*-repos-*' })
    $other = @($all | Where-Object { $_.Name -notlike '*-repos-*' })
    return @(($repos + $other) | ForEach-Object { $_.FullName })
}

function Get-ManifestTargets {
    # every source and destination named in the pending machine manifests, so plan
    # doesn't double-handle something a manifest already covers
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    if (-not (Test-Path -LiteralPath $pendingDir)) { return , $set }
    foreach ($f in @(Get-ChildItem -LiteralPath $pendingDir -Filter '*.csv' | Where-Object { $_.Name -notlike '*-repos-*' })) {
        foreach ($r in @(Import-Csv -LiteralPath $f.FullName -Encoding UTF8)) {
            if ($r.source) { [void]$set.Add((Fix $r.source).TrimEnd($sep)) }
            if ($r.dest) { [void]$set.Add((Fix $r.dest).TrimEnd($sep)) }
        }
    }
    return , $set
}

# ---------------------------------------------------------------- scaffold

function Get-Domains { return @($std.domains) }

function Test-DomainHere($d) {
    if (-not $d.onlyOn) { return $true }
    return ($restrictedHere -contains $d.folder)
}

function Install-Folder([string]$p) {
    if (Test-Path -LiteralPath $p) { return }
    if ($DryRun) { Write-Row 'mkdir' '' $p 'WOULD-MAKE' ''; return }
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    Write-Row 'mkdir' '' $p 'MADE' ''
}

function Invoke-Scaffold {
    Write-Host ''
    Write-Host 'Folders' -ForegroundColor White
    if (-not (Test-Path -LiteralPath $DevRoot)) { Install-Folder $DevRoot }
    foreach ($x in @($std.devExtras)) { Install-Folder (Join-Rel $DevRoot $x) }
    foreach ($d in (Get-Domains)) {
        if (-not (Test-DomainHere $d)) { continue }
        if (-not ($d.dev -is [bool])) {
            $base = Join-Rel $DevRoot $d.folder
            Install-Folder $base
            foreach ($s in @($d.dev)) { if ($s) { Install-Folder (Join-Rel $base $s) } }
        }
        if ($haveDrive -and -not ($d.drive -is [bool])) {
            $base = Join-Rel $DriveRoot $d.folder
            Install-Folder $base
            foreach ($s in @($d.drive)) { if ($s) { Install-Folder (Join-Rel $base $s) } }
        }
    }
    if ($haveDrive) { foreach ($x in @($std.driveExtras)) { Install-Folder (Join-Rel $DriveRoot $x) } }
    elseif ($DriveRoot) { Write-Row 'scaffold' $DriveRoot '' 'WARN' 'synced drive not found here; drive folders skipped (install its desktop app, then run again)' }
}

# Root AGENTS.md / CLAUDE.md and per-domain CLAUDE.md. A file is replaced only when it
# carries the "layout:managed" marker, so a file you wrote yourself is never overwritten.
function Install-Templates {
    Write-Host ''
    Write-Host 'Instruction files' -ForegroundColor White
    $tdir = Join-Path $Here 'templates'
    if (-not (Test-Path -LiteralPath $tdir)) { return }
    $prefix = (Resolve-Path -LiteralPath $tdir).Path.TrimEnd($sep) + $sep
    foreach ($t in @(Get-ChildItem -LiteralPath $tdir -Recurse -File)) {
        $rel = $t.FullName.Substring($prefix.Length)
        $top = ($rel -split '[\\/]')[0]
        if (($restrictedFolders -contains $top) -and -not ($restrictedHere -contains $top)) { continue }
        $target = Join-Path $DevRoot $rel
        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent)) {
            if ($DryRun) { Write-Row 'template' $t.FullName $target 'WOULD-WRITE' ''; continue }
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        $new = Get-Content -LiteralPath $t.FullName -Raw -Encoding UTF8
        if (Test-Path -LiteralPath $target) {
            $old = Get-Content -LiteralPath $target -Raw -Encoding UTF8
            if ($old -eq $new) { continue }
            if ($old -notmatch 'layout:managed') {
                Write-Row 'template' $t.FullName $target 'KEPT' 'existing file is not managed by this kit; left as is (move it first)'
                continue
            }
        }
        if ($DryRun) { Write-Row 'template' $t.FullName $target 'WOULD-WRITE' ''; continue }
        Copy-Item -LiteralPath $t.FullName -Destination $target -Force
        Write-Row 'template' $t.FullName $target 'WROTE' ''
    }
}

# ---------------------------------------------------------------- plan

function Find-ByName([string]$name) {
    # a project folder someone already moved somewhere under the dev root by hand
    $hits = New-Object System.Collections.Generic.List[string]
    foreach ($d in (Get-Domains)) {
        $base = Join-Rel $DevRoot $d.folder
        if (-not (Test-Path -LiteralPath $base)) { continue }
        $p1 = Join-Path $base $name
        if (Test-Path -LiteralPath $p1 -PathType Container) { $hits.Add($p1) }
        foreach ($g in @($d.groups)) {
            if (-not $g) { continue }
            $p2 = Join-Path (Join-Rel $base $g) $name
            if (Test-Path -LiteralPath $p2 -PathType Container) { $hits.Add($p2) }
        }
    }
    return @($hits)
}

function Invoke-Plan {
    Write-Host ''
    Write-Host 'Projects (projects.json)' -ForegroundColor White
    $covered = Get-ManifestTargets
    $out = New-Object System.Collections.Generic.List[object]
    $registered = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $inPlace = 0
    foreach ($p in @($reg.projects)) {
        $target = Join-Rel $DevRoot $p.path
        [void]$registered.Add($p.folder)
        foreach ($a in @($p.aliases)) { if ($a) { [void]$registered.Add($a) } }
        if (Test-Path -LiteralPath $target) { $inPlace++; continue }
        if ($covered.Contains($target)) { continue }
        $cands = @($p.folder) + @($p.aliases) | Where-Object { $_ } | ForEach-Object { Join-Path $DevRoot $_ }
        $found = $null
        foreach ($c in $cands) { if ((Test-Path -LiteralPath $c -PathType Container) -and ($c -ne $target)) { $found = $c; break } }
        if (-not $found) {
            $hits = @(Find-ByName $p.folder | Where-Object { $_ -ne $target })
            if ($hits.Count -gt 0) { $found = $hits[0] }
        }
        if ($found) {
            $out.Add([pscustomobject]@{ action = 'move'; source = $found; dest = $target; note = 'into its domain folder' })
        } elseif ($p.repo) {
            $out.Add([pscustomobject]@{ action = 'clone'; source = $p.repo; dest = $target; note = 'not on this PC yet' })
        } else {
            $out.Add([pscustomobject]@{ action = 'note'; source = $target; dest = ''; note = 'not on this PC and not on GitHub, so it can only live on the PC that has it' })
        }
    }
    # top-level folders nothing knows about
    $known = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($d in (Get-Domains)) { [void]$known.Add($d.folder) }
    if (Test-Path -LiteralPath $DevRoot) {
        foreach ($dir in @(Get-ChildItem -LiteralPath $DevRoot -Directory -Force)) {
            if ($dir.Name.StartsWith('_') -or $dir.Name.StartsWith('.')) { continue }
            if ($known.Contains($dir.Name) -or $registered.Contains($dir.Name)) { continue }
            if ($covered.Contains($dir.FullName)) { continue }
            $out.Add([pscustomobject]@{ action = 'note'; source = $dir.FullName; dest = ''; note = 'not in projects.json: add a row for it, then run plan again' })
        }
    }
    if (-not (Test-Path -LiteralPath $pendingDir)) { New-Item -ItemType Directory -Path $pendingDir -Force | Out-Null }
    $file = Join-Path $pendingDir ("{0}-repos-{1}.csv" -f $pc.ToLower(), (Get-Date -Format 'yyyy-MM-dd'))
    if ($out.Count -eq 0) {
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
        Write-Host ("  all {0} registered projects are already in place" -f $inPlace)
        return
    }
    $out | Export-Csv -LiteralPath $file -NoTypeInformation -Encoding UTF8
    $moves = @($out | Where-Object { $_.action -eq 'move' }).Count
    $clones = @($out | Where-Object { $_.action -eq 'clone' }).Count
    $notes = @($out | Where-Object { $_.action -eq 'note' }).Count
    Write-Host ("  {0} in place, {1} to move, {2} to clone, {3} notes -> {4}" -f $inPlace, $moves, $clones, $notes, $file)
}

# ---------------------------------------------------------------- index

function Get-GitInfo([string]$dir) {
    $g = Join-Path $dir '.git'
    $info = [pscustomobject]@{ remote = ''; branch = ''; kind = 'none'; touched = $null }
    if (Test-Path -LiteralPath (Join-Path $dir '.nogit')) { $info.kind = 'nogit' }
    if (Test-Path -LiteralPath $g -PathType Leaf) { $info.kind = 'worktree'; return $info }
    if (-not (Test-Path -LiteralPath $g -PathType Container)) { return $info }
    $info.kind = 'git'
    $cfg = Join-Path $g 'config'
    if (Test-Path -LiteralPath $cfg) {
        $text = Get-Content -LiteralPath $cfg -Raw
        $m = [regex]::Match($text, '\[remote "origin"\][^\[]*?url\s*=\s*(\S+)')
        if ($m.Success) { $info.remote = $m.Groups[1].Value }
    }
    $head = Join-Path $g 'HEAD'
    if (Test-Path -LiteralPath $head) { $info.branch = ((Get-Content -LiteralPath $head -Raw).Trim() -replace '^ref: refs/heads/', '') }
    foreach ($f in @('index', 'FETCH_HEAD', 'ORIG_HEAD')) {
        $fp = Join-Path $g $f
        if (Test-Path -LiteralPath $fp) {
            $t = (Get-Item -LiteralPath $fp).LastWriteTime
            if (-not $info.touched -or $t -gt $info.touched) { $info.touched = $t }
        }
    }
    return $info
}

function Get-HostKind([string]$dir, $r) {
    if ($r -and $r.host -and $r.host -ne 'none') { return $r.host }
    if (Test-Path -LiteralPath (Join-Path $dir 'vercel.json')) { return 'vercel' }
    foreach ($f in @('railway.json', 'railway.toml', 'Procfile')) { if (Test-Path -LiteralPath (Join-Path $dir $f)) { return 'railway' } }
    foreach ($f in @('appsscript.json', '.clasp.json')) { if (Test-Path -LiteralPath (Join-Path $dir $f)) { return 'apps-script' } }
    return ''
}

function Get-ProjectDirs {
    $list = New-Object System.Collections.Generic.List[object]
    # An optional hub folder at the top of the dev root (notes, state files), listed first.
    if ($std.hubFolder) {
        $sb = Join-Rel $DevRoot $std.hubFolder
        if (Test-Path -LiteralPath $sb) { $list.Add([pscustomobject]@{ domain = $null; dir = (Get-Item -LiteralPath $sb) }) }
    }
    foreach ($d in (Get-Domains)) {
        if ($d.dev -is [bool]) { continue }
        if (-not (Test-DomainHere $d)) { continue }
        $base = Join-Rel $DevRoot $d.folder
        if (-not (Test-Path -LiteralPath $base)) { continue }
        $groups = @($d.groups | Where-Object { $_ })
        foreach ($c in @(Get-ChildItem -LiteralPath $base -Directory -Force | Sort-Object Name)) {
            if ($c.Name.StartsWith('.') -or $c.Name.StartsWith('_')) { continue }
            if ($groups -contains $c.Name) {
                foreach ($cc in @(Get-ChildItem -LiteralPath $c.FullName -Directory -Force | Sort-Object Name)) {
                    if ($cc.Name.StartsWith('.') -or $cc.Name.StartsWith('_')) { continue }
                    $list.Add([pscustomobject]@{ domain = $d; dir = $cc })
                }
            } else {
                $list.Add([pscustomobject]@{ domain = $d; dir = $c })
            }
        }
    }
    return , $list.ToArray()
}

function Esc([string]$s) { if (-not $s) { return '' }; return ($s -replace '\|', '\|') }

function Invoke-Index {
    Write-Host ''
    Write-Host 'Index' -ForegroundColor White
    $byPath = @{}
    foreach ($p in @($reg.projects)) { $byPath[(Join-Rel $DevRoot $p.path).ToLower()] = $p }
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($e in (Get-ProjectDirs)) {
        $dir = $e.dir.FullName
        $r = $byPath[$dir.ToLower()]
        $gi = Get-GitInfo $dir
        $touched = $gi.touched
        if (-not $touched) { $touched = $e.dir.LastWriteTime }
        $repo = $gi.remote
        if (-not $repo -and $r -and $r.repo) { $repo = $r.repo }
        $rel = $dir.Substring($DevRoot.TrimEnd($sep).Length + 1)
        $dslug = ''
        if ($e.domain) { $dslug = $e.domain.folder }
        $items.Add([pscustomobject]@{
            name       = $e.dir.Name
            path       = $rel
            domain     = $dslug
            repo       = $repo
            branch     = $gi.branch
            git        = $gi.kind
            host       = (Get-HostKind $dir $r)
            status     = $(if ($r) { $r.status } else { '' })
            lastWork   = $touched.ToString('yyyy-MM-dd')
            drive      = $(if ($r -and $r.drive) { $r.drive } else { '' })
            node       = $(if ($r -and $r.node) { $r.node } else { '' })
            registered = [bool]$r
        })
    }
    if ($DryRun) {
        Write-Host ("  would index {0} project folders (run with -Go to write INDEX.md)" -f $items.Count)
        return
    }
    if (-not (Test-Path -LiteralPath $sysDir)) { New-Item -ItemType Directory -Path $sysDir -Force | Out-Null }
    $items | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $sysDir 'index.json') -Encoding UTF8

    $md = New-Object System.Text.StringBuilder
    [void]$md.AppendLine('<!-- layout:generated. Rebuilt by Layout.ps1 index. Do not edit by hand. -->')
    [void]$md.AppendLine("# $DevRoot index ($pc)")
    [void]$md.AppendLine('')
    $intro = "Read AGENTS.md first for how everything is organised. Paths are relative to $DevRoot and are the same on every PC."
    if ($std.indexIntro) { $intro = $std.indexIntro }
    [void]$md.AppendLine(("Generated {0}. {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), $intro))
    [void]$md.AppendLine('')
    $sections = @([pscustomobject]@{ folder = ''; label = 'Hub' }) + @(Get-Domains | ForEach-Object { [pscustomobject]@{ folder = $_.folder; label = $_.label } })
    foreach ($s in $sections) {
        $rows = @($items | Where-Object { $_.domain -eq $s.folder })
        if ($rows.Count -eq 0) { continue }
        $title = $s.label
        if ($s.folder) { $title = "$($s.folder) - $($s.label)" }
        [void]$md.AppendLine("## $title")
        [void]$md.AppendLine('')
        [void]$md.AppendLine('| Project | Path | GitHub | Host | Status | Last work | Drive | Notes |')
        [void]$md.AppendLine('|---|---|---|---|---|---|---|---|')
        foreach ($i in $rows) {
            $gh = ''
            if ($i.repo -match 'github\.com[:/](.+?)(\.git)?$') { $gh = $Matches[1] }
            elseif ($i.repo) { $gh = $i.repo }
            elseif ($i.git -eq 'nogit') { $gh = '(no git by design)' }
            elseif ($i.git -eq 'git') { $gh = '(local repo, no remote)' }
            else { $gh = '(not a repo)' }
            [void]$md.AppendLine(("| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} |" -f (Esc $i.name), (Esc $i.path), (Esc $gh), (Esc $i.host), (Esc $i.status), $i.lastWork, (Esc $i.drive), (Esc $i.node)))
        }
        [void]$md.AppendLine('')
    }
    $local = @($items | Where-Object { -not ($_.repo -match 'github\.com') -and $restrictedFolders -notcontains $_.domain })
    if ($local.Count) {
        [void]$md.AppendLine('## Not on GitHub (exists only on the PC that has it)')
        [void]$md.AppendLine('')
        foreach ($i in $local) { [void]$md.AppendLine("- $($i.path)") }
        [void]$md.AppendLine('')
    }
    $unreg = @($items | Where-Object { -not $_.registered -and $restrictedFolders -notcontains $_.domain })
    if ($unreg.Count) {
        [void]$md.AppendLine('## Not in projects.json yet')
        [void]$md.AppendLine('')
        foreach ($i in $unreg) { [void]$md.AppendLine("- $($i.path)") }
        [void]$md.AppendLine('')
    }
    $loose = @()
    if (Test-Path -LiteralPath $DevRoot) {
        $loose = @(Get-ChildItem -LiteralPath $DevRoot -File -Force | Where-Object { @('AGENTS.md', 'CLAUDE.md', 'INDEX.md') -notcontains $_.Name })
    }
    if ($loose.Count) {
        [void]$md.AppendLine("## Loose files at the top of $DevRoot (file them)")
        [void]$md.AppendLine('')
        foreach ($f in $loose) { [void]$md.AppendLine("- $($f.Name)") }
        [void]$md.AppendLine('')
    }
    Set-Content -LiteralPath (Join-Path $DevRoot 'INDEX.md') -Value $md.ToString() -Encoding UTF8
    Write-Row 'index' '' (Join-Path $DevRoot 'INDEX.md') 'WROTE' ("{0} projects" -f $items.Count)
    Write-Host ("  INDEX.md: {0} projects" -f $items.Count)
    if ($haveDrive) { Invoke-DriveIndex }
}

function Get-FileCount([string]$dir) {
    return @(Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue).Count
}

function Invoke-DriveIndex {
    $private = @($std.privateDriveFolders | ForEach-Object { (Fix $_).ToLower() })
    $md = New-Object System.Text.StringBuilder
    [void]$md.AppendLine('<!-- layout:generated. Rebuilt by Layout.ps1 index. Do not edit by hand. -->')
    [void]$md.AppendLine('# Drive map')
    [void]$md.AppendLine('')
    [void]$md.AppendLine(("Generated {0} on {1}. Same domain folders as {2}. Private folders show file counts only." -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), $pc, $DevRoot))
    [void]$md.AppendLine('')
    foreach ($d in (Get-Domains)) {
        if ($d.drive -is [bool]) { continue }
        $base = Join-Rel $DriveRoot $d.folder
        if (-not (Test-Path -LiteralPath $base)) { continue }
        $isPrivate = $private -contains $d.folder.ToLower()
        $tag = ''
        if ($isPrivate) { $tag = ' (private)' }
        [void]$md.AppendLine("## $($d.folder) - $($d.label)$tag")
        [void]$md.AppendLine('')
        [void]$md.AppendLine($d.about)
        [void]$md.AppendLine('')
        $top = @(Get-ChildItem -LiteralPath $base -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' })
        if ($top.Count) { [void]$md.AppendLine("- (top level): $($top.Count) files") }
        $empty = New-Object System.Collections.Generic.List[string]
        foreach ($c in @(Get-ChildItem -LiteralPath $base -Directory -Force | Sort-Object Name)) {
            $relc = (Join-Path $d.folder $c.Name).ToLower()
            $cPrivate = $isPrivate -or ($private -contains $relc)
            $n = Get-FileCount $c.FullName
            if ($n -eq 0) { $empty.Add($c.Name); continue }
            $line = "- $($c.Name)\ : $n files"
            $subs = @(Get-ChildItem -LiteralPath $c.FullName -Directory -Force | Sort-Object Name)
            if ($subs.Count -and -not $cPrivate) {
                $names = ($subs | ForEach-Object { "$($_.Name) ($(Get-FileCount $_.FullName))" }) -join ', '
                $line += " - $names"
            }
            [void]$md.AppendLine($line)
        }
        if ($empty.Count) { [void]$md.AppendLine("- empty so far: " + ($empty -join ', ')) }
        [void]$md.AppendLine('')
    }
    $loose = @(Get-ChildItem -LiteralPath $DriveRoot -File -Force -ErrorAction SilentlyContinue | Where-Object { @('desktop.ini', 'INDEX.md') -notcontains $_.Name })
    $known = @(Get-Domains | ForEach-Object { $_.folder }) + @($std.driveExtras)
    $odd = @(Get-ChildItem -LiteralPath $DriveRoot -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $known -notcontains $_.Name -and -not $_.Name.StartsWith('.') -and -not $_.Name.StartsWith('$') })
    [void]$md.AppendLine('## Not filed yet')
    [void]$md.AppendLine('')
    [void]$md.AppendLine("- Loose files at the top of Drive: $($loose.Count)")
    foreach ($o in $odd) { [void]$md.AppendLine("- Folder outside the standard: $($o.Name)") }
    $p = Join-Path $DriveRoot 'INDEX.md'
    Set-Content -LiteralPath $p -Value $md.ToString() -Encoding UTF8
    Write-Row 'index' '' $p 'WROTE' ''
    Write-Host '  Drive INDEX.md written'
}

# ---------------------------------------------------------------- venvs

function Invoke-Venvs([bool]$Rebuild) {
    Write-Host ''
    Write-Host 'Python venvs' -ForegroundColor White
    $found = New-Object System.Collections.Generic.List[object]
    $queue = New-Object System.Collections.Generic.Queue[object]
    $queue.Enqueue(@((Get-Item -LiteralPath $DevRoot), 0))
    $skip = @('node_modules', '.git', '_archive', '_system', '__pycache__')
    while ($queue.Count) {
        $pair = $queue.Dequeue()
        $dir = $pair[0]; $depth = $pair[1]
        foreach ($c in @(Get-ChildItem -LiteralPath $dir.FullName -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($skip -contains $c.Name -or $c.Name.StartsWith('_')) { continue }
            if (Test-Path -LiteralPath (Join-Path $c.FullName 'pyvenv.cfg')) { $found.Add($c); continue }
            if ($depth -lt 4) { $queue.Enqueue(@($c, ($depth + 1))) }
        }
    }
    $broken = 0
    foreach ($v in $found) {
        $act = Join-Path $v.FullName 'Scripts\activate.bat'
        if (-not (Test-Path -LiteralPath $act)) { $act = Join-Path $v.FullName 'bin/activate' }
        $ok = $false
        if (Test-Path -LiteralPath $act) { $ok = (Get-Content -LiteralPath $act -Raw).IndexOf($v.FullName, [StringComparison]::OrdinalIgnoreCase) -ge 0 }
        if ($ok) { continue }
        $broken++
        $proj = Split-Path -Parent $v.FullName
        $cfg = Get-Content -LiteralPath (Join-Path $v.FullName 'pyvenv.cfg') -Raw
        $ver = ''
        $m = [regex]::Match($cfg, 'version(_info)?\s*=\s*(\d+\.\d+)')
        if ($m.Success) { $ver = $m.Groups[2].Value }
        if (-not $Rebuild) {
            Write-Row 'venv' $v.FullName '' 'BROKEN' "built for an old path; rebuild with: Layout.ps1 venvs -Go (Python $ver)"
            Write-Host ("  BROKEN    {0}" -f $v.FullName) -ForegroundColor Yellow
            continue
        }
        try {
            Remove-Item -LiteralPath $v.FullName -Recurse -Force
            $py = Get-Command py -ErrorAction SilentlyContinue
            if ($py -and $ver) { & py "-$ver" -m venv $v.FullName } else { & python -m venv $v.FullName }
            if ($LASTEXITCODE -ne 0) { throw "venv creation exited $LASTEXITCODE" }
            $req = Join-Path $proj 'requirements.txt'
            $vpy = Join-Path $v.FullName 'Scripts\python.exe'
            if ((Test-Path -LiteralPath $req) -and (Test-Path -LiteralPath $vpy)) {
                & $vpy -m pip install --quiet -r $req
                if ($LASTEXITCODE -ne 0) { throw "pip install exited $LASTEXITCODE" }
            }
            Write-Row 'venv' $v.FullName '' 'REBUILT' "Python $ver"
            Write-Host ("  REBUILT   {0}" -f $v.FullName) -ForegroundColor Green
        } catch {
            Write-Row 'venv' $v.FullName '' 'FAILED' $_.Exception.Message
        }
    }
    if ($broken -eq 0) { Write-Host ("  all {0} venvs point at their current folders" -f $found.Count) }
}

# ---------------------------------------------------------------- undo

function Invoke-Undo {
    $file = $Log
    if (-not $file) {
        $last = @(Get-ChildItem -LiteralPath $logDir -Filter 'run-*.csv' -ErrorAction SilentlyContinue) + @(Get-ChildItem -LiteralPath $logDir -Filter 'apply-*.csv' -ErrorAction SilentlyContinue) |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $last) { Write-Host 'No run log found.' -ForegroundColor Yellow; return }
        $file = $last.FullName
    }
    Write-Host ("Undoing {0}" -f $file) -ForegroundColor White
    $rows = @(Import-Csv -LiteralPath $file -Encoding UTF8)
    [array]::Reverse($rows)
    foreach ($r in $rows) {
        if ($r.status -eq 'MOVED') { Move-Entry $r.dest $r.source; continue }
        if ($r.action -eq 'template' -and $r.status -eq 'WROTE' -and (Test-Path -LiteralPath $r.dest)) {
            if ($DryRun) { Write-Row 'template' $r.dest '' 'WOULD-RECYCLE' 'instruction file this run installed'; continue }
            Remove-ToBin $r.dest
            Write-Row 'template' $r.dest '' 'RECYCLED' 'instruction file this run installed'
            continue
        }
        if ($r.action -eq 'mkdir' -and $r.status -eq 'MADE' -and (Test-Path -LiteralPath $r.dest -PathType Container)) {
            $inside = @(Get-ChildItem -LiteralPath $r.dest -Recurse -Force -File -ErrorAction SilentlyContinue)
            if ($inside.Count -gt 0) { continue }
            if ($DryRun) { Write-Row 'mkdir' $r.dest '' 'WOULD-PRUNE' 'empty folder this run made'; continue }
            Remove-Item -LiteralPath $r.dest -Recurse -Force
            Write-Row 'mkdir' $r.dest '' 'PRUNED' 'empty folder this run made'
        }
    }
    $binned = @($rows | Where-Object { @('RECYCLED', 'DEDUPED') -contains $_.status })
    if ($binned.Count) {
        Write-Host ''
        Write-Host ("{0} item(s) went to the Recycle Bin (C:) or Drive trash (H:); restore any you want from there." -f $binned.Count) -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------- main

Write-Host ''
$modeText = 'DRY RUN, nothing changes'
if ($Go) { $modeText = 'LIVE' }
Write-Host ("Layout {0} on {1} ({2})" -f $Mode, $pc, $modeText) -ForegroundColor White
Write-Host ("  Dev     = {0}" -f $DevRoot)
$dtext = 'not found'
if ($haveDrive) { $dtext = 'found' }
Write-Host ("  Drive   = {0} ({1})" -f $DriveRoot, $dtext)
if ($restrictedHere.Count) { Write-Host ("  Restricted domains set up on this PC only: {0}" -f ($restrictedHere -join ', ')) }

$kind = $Mode
if ($DryRun -and @('run', 'apply', 'undo') -contains $Mode) { $kind = "dryrun-$Mode" }
if (@('run', 'apply', 'undo', 'scaffold', 'venvs') -contains $Mode) { Start-Log $kind }

if ($Go -and @('run', 'apply') -contains $Mode -and $env:OS -eq 'Windows_NT') {
    $code = @(Get-Process -Name 'Code' -ErrorAction SilentlyContinue)
    if ($code.Count) {
        Write-Host ''
        Write-Host 'VS Code is open. Folders it has open cannot move. Close VS Code first.' -ForegroundColor Yellow
        $ans = Read-Host 'Continue anyway? [y/N]'
        if ($ans -notmatch '^(y|yes)$') { exit 1 }
    }
}

switch ($Mode) {
    'scaffold' { Invoke-Scaffold; Install-Templates }
    'plan' { Invoke-Plan }
    'apply' { foreach ($m in (Get-PendingManifests)) { Invoke-Manifest $m } }
    'undo' { Invoke-Undo }
    'index' { $DryRun = $false; Invoke-Index }
    'venvs' { Invoke-Venvs $Go.IsPresent }
    'run' {
        Invoke-Scaffold
        Invoke-Plan
        $ms = @(Get-PendingManifests)
        foreach ($m in $ms) { Invoke-Manifest $m }
        Install-Templates
        if ($Go) {
            $bad = 0
            foreach ($k in @('FAILED')) { if ($script:Counts.ContainsKey($k)) { $bad += $script:Counts[$k] } }
            if (-not (Test-Path -LiteralPath $doneDir)) { New-Item -ItemType Directory -Path $doneDir -Force | Out-Null }
            if ($bad -eq 0) {
                foreach ($m in $ms) { Move-Item -LiteralPath $m -Destination (Join-Path $doneDir (Split-Path -Leaf $m)) -Force }
            } else {
                Write-Host ''
                Write-Host ("{0} item(s) failed; manifests stay in pending so you can fix and run again." -f $bad) -ForegroundColor Yellow
            }
            Invoke-Index
            Invoke-Venvs $false
        }
    }
}

if ($script:Counts.Count) { Write-Counts 'Summary' }
if ($script:LogFile) {
    Write-Host ''
    Write-Host ("Full list: {0}" -f $script:LogFile)
}
if ($DryRun -and @('run', 'apply', 'undo', 'venvs') -contains $Mode) {
    Write-Host ''
    Write-Host ("That was a preview. To do it:  .\Layout.ps1 {0} -Go" -f $Mode) -ForegroundColor Cyan
}
Write-Host ''
