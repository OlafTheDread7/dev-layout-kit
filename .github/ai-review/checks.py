#!/usr/bin/env python3
"""AI Review: the plain checks that run before the AI reviewer.

Three checks, no AI, a few seconds each:

  surface   What a deploy would publish. Fails on review notes, Markdown, docs,
            "Claude outputs", secret files and databases that would go live.
  secrets   gitleaks over this push (the whole history on a whole-repo run).
  deps      Known holes in npm packages (npm audit) and pinned Python
            packages (OSV database).

Results go to .ai-review-run/checks.json, and enforce.py turns them into the
pass/fail. This script exits non-zero only when a check itself breaks; enforce.py
then holds the deploy (fail closed). A dependency audit that can't reach its
database is reported as a medium finding instead, so an outage elsewhere doesn't
hold every deploy.

Optional per-repo settings live in .github/ai-review/surface.json:
  {
    "host": "auto",            # or vercel-static, vercel-output, vercel-build, railway, server, none
    "root": "",                # subfolder Vercel deploys from (its Root Directory)
    "output_dir": "",          # Vercel outputDirectory, if not in vercel.json
    "static_dirs": [],         # Railway: folders the server publishes as files
    "publish": [],             # paths allowed to go live anyway (gitignore-style)
    "issues": true             # read by enforce.py: false stops it opening GitHub issues
  }
Standard library only.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

RUN_DIR = os.path.join(os.environ.get("GITHUB_WORKSPACE", "."), ".ai-review-run")
CONFIG_DIR = ".github/ai-review"
SURFACE_CONFIG = os.path.join(CONFIG_DIR, "surface.json")
GITLEAKS_CONFIG = os.path.join(CONFIG_DIR, "gitleaks.toml")

# Vercel never uploads these, whatever .vercelignore says.
VERCEL_ALWAYS_IGNORED = [
    ".git/", ".vercel/", "node_modules/", ".next/", ".cache/",
    "__pycache__/", "venv/", ".venv/", ".DS_Store",
]

# Folders a Railway app usually publishes as plain files.
RAILWAY_STATIC_DIRS = ["static", "public", "site", "dist", "build", "www"]

# Code that publishes the whole repository folder as files.
SERVES_REPO_ROOT = [
    re.compile(r"""express\.static\(\s*(__dirname|process\.cwd\(\)|['"]\.?/?['"])\s*[,)]"""),
    re.compile(r"""static_folder\s*=\s*['"]\.?/?['"]"""),
    re.compile(r"""send_from_directory\(\s*['"]\.?/?['"]"""),
]

ENV_EXAMPLES = {".env.example", ".env.sample", ".env.template", ".env.dist", ".env.defaults"}
SECRET_SUFFIXES = (".pem", ".key", ".p12", ".pfx", ".jks", ".keystore", ".kdbx", ".ppk", ".asc", ".gpg")
DB_SUFFIXES = (".db", ".sqlite", ".sqlite3", ".db-journal", ".db-wal", ".mdb", ".accdb")
DATA_SUFFIXES = (".csv", ".tsv", ".xlsx", ".xls", ".parquet", ".ndjson")
SCRIPT_SUFFIXES = (".ps1", ".bat", ".cmd", ".sh", ".py", ".sql", ".log", ".ipynb")
ARCHIVE_SUFFIXES = (".zip", ".7z", ".rar", ".tar", ".tgz", ".gz")


# --------------------------------------------------------------------------- helpers

def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def fingerprint(*parts):
    return hashlib.sha1("|".join(str(p) for p in parts).encode("utf-8")).hexdigest()[:12]


def finding(source, severity, category, file, title, detail, fix, line=0, key=None):
    return {
        "source": source,
        "severity": severity,
        "category": category,
        "file": file,
        "line": int(line or 0),
        "title": title[:120],
        "detail": detail,
        "fix": fix,
        "fingerprint": fingerprint(source, category, file, key or title),
    }


def load_json(path, default):
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, type(default)) else default
    except (FileNotFoundError, json.JSONDecodeError, UnicodeDecodeError):
        return default


class IgnoreList:
    """A small gitignore-style matcher, enough for .vercelignore and allow-lists."""

    def __init__(self, lines):
        self.rules = []
        for raw in lines:
            line = raw.rstrip("\n").rstrip("\r")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            line = line.strip()
            negate = line.startswith("!")
            if negate:
                line = line[1:]
            dir_only = line.endswith("/")
            line = line.strip("/") if dir_only else line
            anchored = line.startswith("/") or "/" in line
            line = line.lstrip("/")
            if line:
                self.rules.append((negate, dir_only, anchored, self._regex(line)))

    @staticmethod
    def _regex(pattern):
        out, i = [], 0
        while i < len(pattern):
            if pattern.startswith("**/", i):
                out.append("(?:.*/)?")
                i += 3
            elif pattern.startswith("/**", i):
                out.append("(?:/.*)?")
                i += 3
            elif pattern.startswith("**", i):
                out.append(".*")
                i += 2
            elif pattern[i] == "*":
                out.append("[^/]*")
                i += 1
            elif pattern[i] == "?":
                out.append("[^/]")
                i += 1
            elif pattern[i] == "[":
                j = pattern.find("]", i)
                if j == -1:
                    out.append(re.escape(pattern[i]))
                    i += 1
                else:
                    out.append(pattern[i:j + 1])
                    i = j + 1
            else:
                out.append(re.escape(pattern[i]))
                i += 1
        return re.compile("^" + "".join(out) + "$")

    def matches(self, path):
        parts = path.split("/")
        result = False
        for negate, dir_only, anchored, rx in self.rules:
            hit = False
            # Every leading folder of the path, then (unless dir_only) the path itself.
            candidates = ["/".join(parts[:n]) for n in range(1, len(parts))]
            if not dir_only:
                candidates.append(path)
            for cand in candidates:
                target = cand if anchored else cand.rsplit("/", 1)[-1]
                if rx.match(target):
                    hit = True
                    break
            if hit:
                result = not negate
        return result


# --------------------------------------------------------------------------- surface

def classify(path):
    """Return (severity, category, title, why) for a file that would be published, or None."""
    name = path.rsplit("/", 1)[-1]
    lower = name.lower()
    parts = path.split("/")
    if lower == ".env" or (lower.startswith(".env.") and lower not in ENV_EXAMPLES) \
            or lower.endswith(SECRET_SUFFIXES) or re.match(r"id_(rsa|dsa|ecdsa|ed25519)$", lower) \
            or (lower.endswith(".json") and ("service-account" in lower or "service_account" in lower
                                             or "credentials" in lower)) \
            or re.fullmatch(r"[\w.-]*(access|refresh)[-_ ]?token[\w-]*(\.txt)?"
                            r"|[\w.-]+[-_]access(\.txt)?|token\.json", lower):
        return ("critical", "secrets", f"Secret file would be public: {path}",
                "It looks like a key, credential or environment file, and the deploy publishes it as a download.")
    if lower.endswith(DB_SUFFIXES):
        return ("critical", "data-integrity", f"Database would be public: {path}",
                "Anyone could download the whole database file.")
    if parts[0] == ".github":
        return ("high", "deploy-surface", f"Review notes and CI files would be public: {path}",
                "The .github folder holds the AI Review notes, which describe this site's weak spots for a reviewer.")
    if any(p == "Claude outputs" for p in parts):
        return ("high", "deploy-surface", f"Internal 'Claude outputs' file would be public: {path}",
                "Claude outputs holds internal deliverables (plans, pricing, client names).")
    if parts[0] == "docs" and len(parts) > 1:
        return ("high", "deploy-surface", f"Working doc would be public: {path}",
                "docs/ usually holds internal working notes, not pages.")
    if lower.endswith(".md"):
        return ("high", "deploy-surface", f"Markdown note would be public: {path}",
                "Markdown files here are notes (README, CLAUDE.md, plans), not pages, and they often describe how the site works.")
    if lower.endswith(DATA_SUFFIXES):
        return ("medium", "deploy-surface", f"Data file would be public: {path}",
                "Spreadsheets and exports can hold leads or customer data.")
    if lower.endswith(SCRIPT_SUFFIXES):
        return ("medium", "deploy-surface", f"Script or log would be public: {path}",
                "Local scripts, source and logs aren't site content and can reveal paths, hosts or keys.")
    if lower.endswith(ARCHIVE_SUFFIXES):
        return ("medium", "deploy-surface", f"Archive would be public: {path}",
                "Zip and tar files usually hold source, exports or backups.")
    return None


def tracked_secret(path):
    """Secret or database files committed anywhere, published or not."""
    c = classify(path)
    if c and c[1] in ("secrets", "data-integrity"):
        return c
    return None


def detect_host(files, cfg):
    host = (cfg.get("host") or "auto").strip()
    root = (cfg.get("root") or "").strip("/")
    if host != "auto":
        return host, root
    prefix = (root + "/") if root else ""
    has = set(files)
    if prefix + "vercel.json" in has or prefix + ".vercelignore" in has:
        vercel = load_json(prefix + "vercel.json", {}) if prefix + "vercel.json" in has else {}
        if cfg.get("output_dir") or vercel.get("outputDirectory"):
            return "vercel-output", root
        pkg = load_json(prefix + "package.json", {}) if prefix + "package.json" in has else {}
        if (pkg.get("scripts") or {}).get("build") or vercel.get("buildCommand"):
            return "vercel-build", root
        return "vercel-static", root
    if {"railway.json", "railway.toml", "Procfile", "Dockerfile", "nixpacks.toml"} & has:
        return "railway", root
    # A server app with no host file (Railway detects these on its own)
    pkg = load_json("package.json", {}) if "package.json" in has else {}
    if (pkg.get("scripts") or {}).get("start") or "requirements.txt" in has:
        return "server", root
    # A plain site with no config file (Vercel's zero-config static hosting publishes everything)
    if prefix + "index.html" in has:
        return "vercel-static", root
    return "none", root


def published_files(files, host, root, cfg, notes):
    """The tracked files the deploy would serve as plain files, as (repo_path, url_path)."""
    out = []
    prefix = (root + "/") if root else ""
    if host.startswith("vercel"):
        ignore_lines = list(VERCEL_ALWAYS_IGNORED)
        vi = prefix + ".vercelignore"
        if os.path.exists(vi):
            with open(vi, encoding="utf-8") as fh:
                ignore_lines += fh.read().splitlines()
        else:
            notes.append("No .vercelignore, so everything in the repo except Vercel's defaults is uploaded.")
        ignore = IgnoreList(ignore_lines)
        serve_root = prefix
        if host == "vercel-output":
            vercel = load_json(prefix + "vercel.json", {}) if os.path.exists(prefix + "vercel.json") else {}
            serve_root = prefix + (cfg.get("output_dir") or vercel.get("outputDirectory") or "").strip("/") + "/"
        elif host == "vercel-build":
            serve_root = prefix + "public/"
            notes.append("Framework build: only public/ is checked, since the built pages aren't in the repo.")
        for f in files:
            if not f.startswith(prefix):
                continue
            rel_to_project = f[len(prefix):]
            if ignore.matches(rel_to_project):
                continue
            if not f.startswith(serve_root):
                continue
            url = f[len(serve_root):]
            if host == "vercel-static" and url.split("/", 1)[0] == "api":
                continue  # serverless functions, not files
            out.append((f, url))
    elif host in ("railway", "server"):
        dirs = list(cfg.get("static_dirs") or [])
        if not dirs:
            dirs = [d for d in RAILWAY_STATIC_DIRS if any(f.startswith(d + "/") for f in files)]
        serves_root = False
        for f in files:
            if "/" in f or not f.endswith((".py", ".js", ".mjs", ".cjs", ".ts")):
                continue
            try:
                with open(f, encoding="utf-8", errors="replace") as fh:
                    text = fh.read()
            except OSError:
                continue
            if any(rx.search(text) for rx in SERVES_REPO_ROOT):
                serves_root = True
                notes.append(f"{f} appears to publish the whole repository folder, so every file is checked.")
                break
        for f in files:
            if serves_root:
                out.append((f, f))
                continue
            for d in dirs:
                if f.startswith(d.strip("/") + "/"):
                    out.append((f, f[len(d.strip("/")) + 1:]))
                    break
        if not serves_root:
            notes.append("Published folders checked: " + (", ".join(dirs) if dirs else "none found") + ".")
    return out


def check_surface(files, cfg):
    findings, notes = [], []
    host, root = detect_host(files, cfg)
    notes.append(f"Host: {host}" + (f" (root {root}/)" if root else "") + ".")
    allow = IgnoreList(cfg.get("publish") or [])
    reported = set()
    groups = {}  # one finding per kind of problem per top-level folder, so one leak isn't 20 issues
    for repo_path, url in published_files(files, host, root, cfg, notes):
        if allow.matches(url) or allow.matches(repo_path):
            continue
        c = classify(url)
        if not c:
            continue
        reported.add(repo_path)
        sev, cat, title, why = c
        if cat in ("secrets", "data-integrity"):
            fix = ("Treat it as leaked: rotate it at the provider, delete the file and add it to .gitignore. "
                   + ("Also add it to .vercelignore." if host.startswith("vercel") else ""))
            findings.append(finding("surface", sev, cat, repo_path,
                                    title, f"{why} Live at /{url} after the next deploy.", fix.strip(), key=repo_path))
            continue
        top = url.split("/", 1)[0] if "/" in url else url
        kind = title.split(" would be public")[0]
        groups.setdefault((kind, top), []).append((repo_path, url, sev, cat, title, why))
    for (kind, top), items in groups.items():
        repo_path, url, sev, cat, title, why = items[0]
        if len(items) == 1:
            where, shown = repo_path, f"/{url}"
        else:
            folder = repo_path[: len(repo_path) - len(url)] + top
            where, title = folder + "/", f"{kind} would be public: {folder}/ ({len(items)} files)"
            shown = ", ".join("/" + u for _, u, *_ in items[:5]) + (" …" if len(items) > 5 else "")
        fix = (f"Add {'/' + top + ('/' if len(items) > 1 or '/' in url else '')} to .vercelignore, or move it out of the repo."
               if host.startswith("vercel") else "Move it out of the published folder, or out of the repo.")
        findings.append(finding("surface", sev, cat, where, title,
                                f"{why} Live after the next deploy at: {shown}.", fix, key=f"{kind}|{where}"))
    for f in files:
        if f in reported:
            continue
        c = tracked_secret(f)
        if not c:
            continue
        sev, cat, _, _ = c
        is_secret = cat == "secrets"
        findings.append(finding("surface", "high" if is_secret else "medium", cat, f,
                                f"{'Secret' if is_secret else 'Database'} file committed: {f}",
                                ("It looks like a key, credential or environment file. " if is_secret
                                 else "A database file is committed. ")
                                + "The deploy doesn't publish it, but it's in the repo and its git history on GitHub.",
                                ("Rotate what's in it, then delete it from the repo and add it to .gitignore." if is_secret
                                 else "Delete it from the repo and add it to .gitignore; keep data out of git."),
                                key=f))
    if host == "vercel-static" and not os.path.exists(((root + "/") if root else "") + ".vercelignore") and not findings:
        findings.append(finding("surface", "low", "deploy-surface", ".vercelignore",
                                "Static site has no .vercelignore",
                                "Nothing private is published today, but the next note or script added to this repo would go live.",
                                "Add the standard .vercelignore (/.github, *.md, /docs, /Claude outputs, *.ps1, *.bat).",
                                key="no-vercelignore"))
    return findings, notes


# --------------------------------------------------------------------------- secrets

def check_secrets(base, mode):
    report = os.path.join(RUN_DIR, "gitleaks.json")
    cmd = [os.environ.get("GITLEAKS", "gitleaks"), "git", "--no-banner", "--redact",
           "--report-format", "json", "--report-path", report, "--exit-code", "0"]
    if os.path.exists(GITLEAKS_CONFIG):
        cmd += ["--config", GITLEAKS_CONFIG]
    if mode == "diff" and base:
        cmd += ["--log-opts", f"{base}..HEAD"]
    cmd.append(".")
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"gitleaks failed ({proc.returncode}): {proc.stderr.strip()[:500]}")
    results = load_json(report, [])
    findings = []
    for r in results or []:
        rule = r.get("RuleID", "secret")
        file = r.get("File", "")
        commit = (r.get("Commit") or "")[:7]
        findings.append(finding(
            "secrets", "critical", "secrets", file,
            f"Possible secret ({rule}) in {file}",
            f"gitleaks rule '{rule}' ({r.get('Description', '').strip()}) matched"
            + (f" in commit {commit}" if commit else "") + ". The value is redacted here.",
            "If it's real, rotate it at the provider first, then load it from an environment variable. "
            "Deleting it in a new commit doesn't remove it from git history. If it's public by design, "
            "add its fingerprint to .gitleaksignore.",
            line=r.get("StartLine", 0), key=f"{rule}|{file}|{r.get('Match', '')}"))
    note = f"gitleaks scanned {'this push' if mode == 'diff' and base else 'the whole history'}: {len(findings)} finding(s)."
    return findings, [note]


# --------------------------------------------------------------------------- dependencies

NPM_SEVERITY = {"critical": "high", "high": "high", "moderate": "medium", "low": "low", "info": "low"}
OSV_SEVERITY = {"CRITICAL": "high", "HIGH": "high", "MODERATE": "medium", "MEDIUM": "medium", "LOW": "low"}


def http_json(url, payload=None, timeout=20):
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def npm_audit(lockfile):
    folder = os.path.dirname(lockfile) or "."
    proc = subprocess.run(["npm", "audit", "--omit=dev", "--json", "--package-lock-only"],
                          cwd=folder, capture_output=True, text=True, timeout=180)
    try:
        data = json.loads(proc.stdout or "{}")
    except json.JSONDecodeError:
        data = {}
    if "vulnerabilities" not in data:
        err = (data.get("error") or {}).get("summary") or proc.stderr.strip()[:300] or "no output"
        return [finding("deps", "medium", "dependency", lockfile,
                        f"npm audit couldn't run for {lockfile}",
                        f"npm audit returned: {err}", "Re-run the job; if it keeps failing, run npm audit locally.",
                        key="npm-audit-failed")]
    out = []
    for name, v in sorted(data["vulnerabilities"].items()):
        advisories = [a for a in v.get("via", []) if isinstance(a, dict)]
        if not advisories:
            continue  # only vulnerable through another package, which gets its own entry
        sev = NPM_SEVERITY.get(v.get("severity", "low"), "low")
        titles = "; ".join(f"{a.get('title', '').strip()} ({a.get('url', '')})" for a in advisories[:3])
        fix = v.get("fixAvailable")
        if isinstance(fix, dict):
            fix_text = f"Upgrade to {fix.get('name')} {fix.get('version')}" + (" (a major version change; test it)" if fix.get("isSemVerMajor") else "") + "."
        elif fix:
            fix_text = f"Run npm audit fix in {os.path.dirname(lockfile) or 'the repo root'} and commit the lockfile."
        else:
            fix_text = "No fixed version yet; check whether the vulnerable code path is used, or replace the package."
        out.append(finding("deps", sev, "dependency", lockfile,
                           f"{name} {v.get('range', '')} has a known {v.get('severity', '')} hole",
                           titles, fix_text, key=f"npm|{lockfile}|{name}"))
    return out


REQ_LINE = re.compile(r"^\s*([A-Za-z0-9][A-Za-z0-9._-]*)(\[[^\]]*\])?\s*==\s*([A-Za-z0-9.!+_-]+)")


def osv_severity(vuln_id, cache):
    if vuln_id in cache:
        return cache[vuln_id]
    sev, title = None, ""
    try:
        v = http_json(f"https://api.osv.dev/v1/vulns/{vuln_id}")
        title = v.get("summary") or ""
        sev = (v.get("database_specific") or {}).get("severity")
        if not sev:
            for alias in v.get("aliases") or []:
                if alias.startswith("GHSA-"):
                    a = http_json(f"https://api.osv.dev/v1/vulns/{alias}")
                    sev = (a.get("database_specific") or {}).get("severity")
                    title = title or a.get("summary") or ""
                    if sev:
                        break
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError):
        pass
    cache[vuln_id] = (OSV_SEVERITY.get((sev or "").upper(), "medium"), title)
    return cache[vuln_id]


def python_audit(reqfile):
    pinned, unpinned = [], []
    with open(reqfile, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.split("#", 1)[0].strip()
            if not line or line.startswith(("-", "git+", "http")):
                continue
            m = REQ_LINE.match(line)
            if m:
                pinned.append((m.group(1), m.group(3)))
            else:
                unpinned.append(re.split(r"[<>=!~;\[ ]", line, maxsplit=1)[0])
    out = []
    if unpinned:
        out.append(finding("deps", "low", "dependency", reqfile,
                           f"{len(unpinned)} unpinned package(s) in {reqfile}",
                           "Packages without an exact version can't be checked and can change under you: "
                           + ", ".join(unpinned[:10]) + ".",
                           "Pin each one with == (pip freeze shows the versions you run today).",
                           key="unpinned"))
    if not pinned:
        return out
    try:
        res = http_json("https://api.osv.dev/v1/querybatch", {"queries": [
            {"package": {"name": n, "ecosystem": "PyPI"}, "version": ver} for n, ver in pinned]})
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError) as exc:
        out.append(finding("deps", "medium", "dependency", reqfile,
                           f"Python dependency audit couldn't reach OSV for {reqfile}",
                           f"The OSV vulnerability database didn't answer ({exc}).",
                           "Re-run the job later.", key="osv-unreachable"))
        return out
    cache = {}
    for (name, ver), result in zip(pinned, res.get("results") or []):
        vulns = result.get("vulns") or []
        if not vulns:
            continue
        rated = [(osv_severity(v["id"], cache), v["id"]) for v in vulns]
        order = {"high": 0, "medium": 1, "low": 2}
        rated.sort(key=lambda r: order[r[0][0]])
        worst = rated[0][0][0]
        listing = "; ".join(f"{vid} {t}".strip() for (s, t), vid in rated[:4])
        out.append(finding("deps", worst, "dependency", reqfile,
                           f"{name}=={ver} has {len(vulns)} known hole(s)",
                           listing + (" …" if len(rated) > 4 else ""),
                           f"Upgrade {name} to a fixed version (see the advisories at osv.dev) and redeploy.",
                           key=f"pypi|{reqfile}|{name}"))
    return out


def check_deps(files):
    findings, notes = [], []
    locks = [f for f in files if f.endswith("package-lock.json") and "node_modules/" not in f]
    pkgs = [f for f in files if f.endswith("package.json") and "node_modules/" not in f]
    for lock in locks:
        findings += npm_audit(lock)
    for pkg in pkgs:
        folder = os.path.dirname(pkg)
        lock = f"{folder}/package-lock.json" if folder else "package-lock.json"
        if lock in files:
            continue
        data = load_json(pkg, {})
        if data.get("dependencies"):
            findings.append(finding("deps", "low", "dependency", pkg,
                                    f"No package-lock.json next to {pkg}",
                                    "Without a lockfile npm installs whatever is newest, and the audit can't check it.",
                                    "Run npm install once and commit package-lock.json.", key="no-lockfile"))
    reqs = [f for f in files if re.search(r"(^|/)requirements[^/]*\.txt$", f)]
    for req in reqs:
        findings += python_audit(req)
    notes.append(f"Dependencies: {len(locks)} npm lockfile(s), {len(reqs)} Python requirements file(s).")
    return findings, notes


# --------------------------------------------------------------------------- main

def main():
    os.makedirs(RUN_DIR, exist_ok=True)
    base = os.environ.get("REVIEW_BASE", "").strip()
    mode = os.environ.get("REVIEW_MODE", "diff").strip() or "diff"
    files = [f for f in git("ls-files", "-z").split("\0") if f]
    cfg = load_json(SURFACE_CONFIG, {})

    result = {"findings": [], "notes": [], "checks": {}}
    for name, fn in (("surface", lambda: check_surface(files, cfg)),
                     ("secrets", lambda: check_secrets(base, mode)),
                     ("deps", lambda: check_deps(files))):
        found, notes = fn()
        result["findings"] += found
        result["notes"] += notes
        result["checks"][name] = len(found)

    with open(os.path.join(RUN_DIR, "checks.json"), "w", encoding="utf-8") as fh:
        json.dump(result, fh, indent=2)
    for n in result["notes"]:
        print(n)
    print(f"Plain checks: {len(result['findings'])} finding(s) "
          f"(surface {result['checks']['surface']}, secrets {result['checks']['secrets']}, deps {result['checks']['deps']}).")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # a broken check holds the deploy through enforce.py
        print(f"::error title=AI Review plain checks::{exc}")
        sys.exit(1)
