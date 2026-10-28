#!/usr/bin/env python3
"""AI Review — turns the plain checks and Claude's JSON verdict into the pass/fail check.

Fails (holds the deploy) when either found anything critical or high, when the AI
verdict says block, or when a usable result is missing (fail closed): the plain
checks must always report, and the AI review must report unless prepare.sh
skipped it on purpose.

Writes a findings table to the job summary and inline annotations on the files,
then opens one GitHub issue per new critical, high or medium finding (labelled
ai-review), so findings don't vanish into job logs. Issues are best effort: a
GitHub hiccup is noted in the summary but never changes the verdict.

Set "issues": false in .github/ai-review/surface.json to stop the issues, for
example on a public repo where you'd rather not publish findings as issues.
On a public repo the job summary is public too.
"""
import hashlib
import json
import os
import subprocess
import sys

BLOCKING = {"critical", "high"}
ISSUE_WORTHY = {"critical", "high", "medium"}
ORDER = {"critical": 0, "high": 1, "medium": 2, "low": 3}
LEVEL = {"critical": "error", "high": "error", "medium": "warning", "low": "notice"}
SOURCE_NAME = {"surface": "Deploy surface", "secrets": "Secret scan", "deps": "Dependencies", "ai": "AI review"}
LABEL = "ai-review"
RUN_DIR = os.path.join(os.environ.get("GITHUB_WORKSPACE", "."), ".ai-review-run")
SETTINGS = os.path.join(os.environ.get("GITHUB_WORKSPACE", "."), ".github", "ai-review", "surface.json")


def issues_enabled():
    """False only when the repo's surface.json says "issues": false."""
    try:
        with open(SETTINGS, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError, UnicodeDecodeError):
        return True
    return not (isinstance(data, dict) and data.get("issues") is False)


def esc_data(value):
    return str(value).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def esc_prop(value):
    return esc_data(value).replace(":", "%3A").replace(",", "%2C")


def cell(value):
    return str(value).replace("|", "\\|").replace("\r", " ").replace("\n", " ").strip()


def write_summary(lines):
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    text = "\n".join(lines) + "\n"
    if path:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(text)
    else:
        sys.stdout.write(text)


def hold(reason):
    write_summary([
        "## AI Review: deploy held",
        "",
        reason,
        "",
        "Re-run this job from the Actions tab. If you need to ship before it passes, "
        "promote the deployment by hand in Vercel or use Deploy Latest Commit in Railway.",
    ])
    print(f"::error title=AI Review::{esc_data(reason)}")
    sys.exit(1)


def severity(f):
    return str(f.get("severity", "low")).lower()


def line_of(f):
    try:
        return max(int(f.get("line") or 0), 0)
    except (TypeError, ValueError):
        return 0


def load_checks():
    path = os.path.join(RUN_DIR, "checks.json")
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError):
        hold("The plain checks (deploy surface, secret scan, dependency audit) didn't finish, "
             "so this commit was not approved. Their step's log says why.")
    if not isinstance(data, dict) or not isinstance(data.get("findings"), list):
        hold("The plain checks returned an unexpected result, so this commit was not approved.")
    return data


def load_ai():
    """Returns (data, ran). ran is False when prepare.sh skipped the AI review on purpose."""
    if (os.environ.get("AI_SKIPPED") or "").lower() == "true":
        return {"verdict": "pass", "summary": "", "findings": []}, False
    raw = (os.environ.get("REVIEW_JSON") or "").strip()
    if not raw:
        hold("The AI review finished without returning a verdict, so this commit was not approved.")
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        hold("The AI review returned a verdict that could not be read, so this commit was not approved.")
    if not isinstance(data, dict):
        hold("The AI review returned an unexpected result, so this commit was not approved.")
    return data, True


def ai_fingerprint(f):
    title = " ".join(str(f.get("title", "")).lower().split())
    key = "|".join(["ai", str(f.get("category", "")), str(f.get("file", "")), title])
    return hashlib.sha1(key.encode("utf-8")).hexdigest()[:12]


def gh(*args, stdin=None):
    return subprocess.run(["gh", *args], input=stdin, capture_output=True, text=True, timeout=60)


def file_issues(findings):
    """Open an issue for each new issue-worthy finding. Returns a list of summary lines."""
    if not issues_enabled():
        return ["Issues: off for this repo (surface.json)."] if any(
            severity(f) in ISSUE_WORTHY for f in findings) else []
    repo = os.environ.get("GITHUB_REPOSITORY")
    if not repo or not os.environ.get("GH_TOKEN"):
        return ["Issues: skipped (no repository token in this run)."]
    worthy = [f for f in findings if severity(f) in ISSUE_WORTHY]
    if not worthy:
        return []
    try:
        gh("label", "create", LABEL, "--repo", repo, "--color", "B60205",
           "--description", "Opened by the AI Review ship gate", "--force")
        listed = gh("issue", "list", "--repo", repo, "--label", LABEL, "--state", "open",
                    "--limit", "300", "--json", "number,body")
        if listed.returncode != 0:
            return [f"Issues: couldn't list open issues ({cell(listed.stderr)[:200]}); none opened."]
        open_bodies = [i.get("body") or "" for i in json.loads(listed.stdout or "[]")]
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError) as exc:
        return [f"Issues: skipped ({cell(exc)[:200]})."]

    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
    run_url = f"{server}/{repo}/actions/runs/{os.environ.get('GITHUB_RUN_ID', '')}"
    sha = os.environ.get("GITHUB_SHA", "")[:7]
    opened, known, failed = [], 0, 0
    for f in worthy:
        fp = f["fingerprint"]
        marker = f"<!-- ai-review:fp={fp} -->"
        if any(marker in b for b in open_bodies):
            known += 1
            continue
        where = f.get("file", "") + (f":{line_of(f)}" if line_of(f) else "")
        title = f"[{severity(f).upper()}] {f.get('title', '')}"[:200]
        body = "\n".join([
            f"**Found by:** {SOURCE_NAME.get(f.get('source'), f.get('source'))} · **Severity:** {severity(f)} · "
            f"**Category:** {f.get('category', '')}",
            f"**Where:** `{where}`" if where else "",
            f"**Commit:** {sha} · **Run:** {run_url}",
            "",
            "### What's wrong",
            str(f.get("detail", "")),
            "",
            "### Fix",
            str(f.get("fix", "")),
            "",
            "Close this issue once it's fixed. The gate opens a new one if the same problem comes back.",
            marker,
        ])
        res = gh("issue", "create", "--repo", repo, "--title", title, "--label", LABEL, "--body-file", "-",
                 stdin=body)
        if res.returncode == 0:
            opened.append(res.stdout.strip())
            open_bodies.append(marker)
        else:
            failed += 1
    lines = []
    if opened:
        lines.append(f"Issues opened: {len(opened)} — " + ", ".join(opened))
    if known:
        lines.append(f"Already tracked in open issues: {known}.")
    if failed:
        lines.append(f"Issues that couldn't be opened: {failed} (see the findings above).")
    return lines


def main():
    checks = load_checks()
    ai, ai_ran = load_ai()
    scope = os.environ.get("REVIEW_RANGE") or ""

    findings = [f for f in checks.get("findings", []) if isinstance(f, dict)]
    for f in (ai.get("findings") or []):
        if isinstance(f, dict):
            f = dict(f)
            f["source"] = "ai"
            f["fingerprint"] = ai_fingerprint(f)
            findings.append(f)
    findings.sort(key=lambda f: (ORDER.get(severity(f), 9), f.get("source", "")))

    blocking = [f for f in findings if severity(f) in BLOCKING]
    ai_verdict = str(ai.get("verdict", "")).lower()
    blocked = bool(blocking) or ai_verdict == "block"

    for f in findings:
        sev = severity(f)
        props = []
        if f.get("file"):
            props.append(f"file={esc_prop(f['file'])}")
            if line_of(f):
                props.append(f"line={line_of(f)}")
        props.append(f"title={esc_prop(sev.upper() + ': ' + str(f.get('title', '')))}")
        message = f"{f.get('detail', '')}  Fix: {f.get('fix', '')}"
        print(f"::{LEVEL.get(sev, 'notice')} {','.join(props)}::{esc_data(message)}")

    counts = {s: sum(1 for f in findings if severity(f) == s) for s in ORDER}
    headline = "Deploy held" if blocked else "Approved"
    lines = [
        f"## AI Review: {headline}",
        "",
        f"**Reviewed:** {cell(scope) or 'this push'}  ",
        f"**Findings:** {counts['critical']} critical · {counts['high']} high · "
        f"{counts['medium']} medium · {counts['low']} low",
        "",
        "**Plain checks:** " + " ".join(cell(n) for n in checks.get("notes", [])),
        "",
        ("**AI review:** " + cell(ai.get("summary", ""))) if ai_ran
        else "**AI review:** skipped for this push (see above); the plain checks still ran.",
        "",
    ]
    if ai_verdict == "block" and not any(f.get("source") == "ai" and severity(f) in BLOCKING for f in findings):
        lines += ["The AI reviewer marked this push as blocked without a critical or high finding; "
                  "read its summary above.", ""]
    if findings:
        lines += ["| Severity | Found by | Where | Problem | Fix |", "|---|---|---|---|---|"]
        for f in findings:
            where = cell(f.get("file", "")) + (f":{line_of(f)}" if line_of(f) else "")
            problem = f"**{cell(f.get('title', ''))}** — {cell(f.get('detail', ''))}"
            lines.append(f"| {severity(f).upper()} | {SOURCE_NAME.get(f.get('source'), cell(f.get('source', '')))} "
                         f"| `{where}` | {problem} | {cell(f.get('fix', ''))} |")
        lines.append("")
    issue_lines = file_issues(findings)
    if issue_lines:
        lines += issue_lines + [""]
    if blocked:
        lines.append("Critical and high findings hold the deploy. Fix them and push again — "
                     "the next run re-checks everything since the last approved commit.")
    else:
        lines.append("Nothing critical or high. The deploy can go live.")
    write_summary(lines)
    sys.exit(1 if blocked else 0)


if __name__ == "__main__":
    main()
