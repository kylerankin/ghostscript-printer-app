# AGENTS.md

## Agent skills

### Issue tracker

Issues and PRDs live as GitHub Issues on this repository. See
`docs/agents/issue-tracker.md`.

### Triage labels

Canonical triage labels are used unchanged. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` at the repo root, created lazily by domain modeling. See `docs/agents/domain.md`.

### OCI container build

Before changing the BuildStream/FSDK graph or CUPS integration, read `docs/skills/fsdk-cups-patching.md`.

### Branches and releases

Target `testing` for fsdk-containers updates and development PRs; promote verified commits to `stable` with `promote-stable.yml`. Pull requests run `just validate`; the merge queue runs the full OCI appliance gate before a change lands on `testing`, and the promotion workflow runs it again before fast-forwarding `stable`. Only version tags on `stable` publish immutable OCI releases. Keep `main` while existing feature branches or workflows still reference it.
