# agentdoc

A Claude Code skill that generates and maintains AI-agent-oriented documentation for any repository.

Combines the context-management structure of `CLAUDE.md + agent-overlay.md` with automatic
drift detection, freshness scoring, and protection for human-written sections.

---

## What it generates

```
repo/
├── CLAUDE.md                      # Lightweight entry point — auto-loaded by Claude Code
├── docs/
│   ├── agent-overlay.md           # Deep reference with drift-detection frontmatter
│   └── .agentdoc/
│       ├── claims.yml             # Verifiable claims registry (commit this)
│       └── status.json            # CI health snapshot (gitignore this)
└── scripts/
    └── agentdoc-check.sh          # CI utility — no Claude Code required for checks
```

`CLAUDE.md` stays under 120 lines and is loaded on every agent interaction.
`docs/agent-overlay.md` is loaded on demand when the agent needs to modify code.
The split keeps the always-on context small while allowing full architectural depth.

---

## Installation

### Automated installation (recommended)

Use `install.sh` to set everything up in one step.

```bash
# Global — skill available in all repos
./install.sh --mode global

# Local — skill available only in one repo
./install.sh --mode local --root /absolute/path/to/repo

# Local + CI utility (also installs agentdoc-check.sh and updates .gitignore)
./install.sh --mode local --root /absolute/path/to/repo --ci-install
```

The script shows a summary of files to create or modify and asks for confirmation
before making any changes. Run `./install.sh --help` for the full option reference.

**What `--ci-install` does additionally:**
- Copies `agentdoc-check.sh` to `<root>/scripts/` and makes it executable
- Appends `docs/.agentdoc/status.json` to `<root>/.gitignore` (if `.gitignore` exists)
- Prints the location of the GitHub Actions and GitLab CI example files

### Manual installation

**Skill (Claude Code):**

```bash
# Global — available in all repos
cp skill.md ~/.claude/skills/agentdoc.md

# Per-repo — available only in this repo
mkdir -p .claude/skills/
cp skill.md .claude/skills/agentdoc.md
```

**CI utility:**

```bash
mkdir -p scripts/
cp agentdoc-check.sh scripts/
chmod +x scripts/agentdoc-check.sh
git add scripts/agentdoc-check.sh
```

**`.gitignore` entry** (add manually or let `--ci-install` handle it):

```
# agentdoc CI artifact (regenerated on every run)
docs/.agentdoc/status.json
```

---

## Quick start

```bash
# 1. Open a Claude Code session in your repo
claude

# 2. Auto-detect phase and run
/agentdoc

# 3. Or run a specific phase
/agentdoc init              # Single overlay (default)
/agentdoc init --mode multi # Multiple overlays, one per subsystem
/agentdoc migrate           # Adopt an existing overlay (no content changes)
/agentdoc draft             # Fill overlay(s) by reading source code
/agentdoc maintain          # Detect and repair drift after code changes
/agentdoc status            # Print health dashboard without modifying anything

# 4. Check health from the shell
./scripts/agentdoc-check.sh status
```

---

## Migrating an existing overlay

If your repo already has a `docs/agent-overlay.md` written manually or by another tool
(codebase-scribe, a custom prompt, etc.), run `/agentdoc migrate` instead of `/agentdoc init`.

The migrate phase **never modifies content**. It only adds the `agentdoc:` frontmatter block.

```bash
claude
/agentdoc migrate
```

**What it does interactively:**

1. Reads all `##` headings in the existing overlay and classifies each as
   *inferred* (safe to auto-update) or *protected* (human-written, never touched).
   You confirm or correct the classification before anything is written.

2. Proposes `watch_paths` based on source file references found in the overlay.
   You confirm, add, or remove entries.

3. Assesses `completeness` from the existing content.

4. Adds the `agentdoc:` block to the frontmatter — either prepending a new `---` block
   or inserting the key into an existing one. All section content is left untouched.

5. Initialises `docs/.agentdoc/claims.yml` (empty — claims are not extracted during migrate).

**After migration:**

```bash
# 1. Review the frontmatter — set human_input to reflect existing tribal knowledge
# 2. Check health
./scripts/agentdoc-check.sh status

# 3. Detect any drift since the overlay was written
/agentdoc maintain

# 4. (Optional) Extract claims from the existing content
/agentdoc draft
# draft only fills sections marked '_[To be filled...]_' — existing content is preserved.
```

**What agentdoc auto-detects:**
If you run `/agentdoc` without arguments on a repo that has an overlay without the
`agentdoc:` block, migration is triggered automatically — you will never accidentally
land in draft phase and overwrite existing content.

---

## Multi-overlay mode

Use this when the repo has clearly separated subsystems that need independent drift
tracking. Examples: a node proxy with distinct proxy, TLS, xDS, and observability
domains; a monorepo with multiple workspace members; a platform with separate control
plane and data plane.

### Starting in multi-overlay mode

```bash
claude
/agentdoc init --mode multi
```

The skill analyzes the repo and **proposes** a subsystem list. You provide the **final** list.
Nothing is created until you confirm.

Example interaction:

```
I detected the following candidate subsystems (suggestion only — you decide):

  1. proxy-data-plane  → src/proxy/, src/copy.rs, src/socket.rs
  2. tls-and-crypto    → src/tls/
  3. xds-and-state     → src/state/, src/xds/
  4. observability     → src/metrics/, src/admin/
  5. build-and-testing → Cargo.toml, tests/, Justfile

Please provide your final subsystem list (one per line):
  name: source/paths
```

### What gets created

```
docs/
├── agent-overlay.md              # Hub — index + cross-cutting conventions
├── agent-overlay-proxy.md        # Spoke — proxy data plane
├── agent-overlay-tls.md          # Spoke — TLS/crypto
├── [... one per subsystem ...]
├── STATUS.md                     # Aggregate health dashboard
└── .agentdoc/
    ├── claims-proxy.yml
    ├── claims-tls.yml
    └── [... one per subsystem ...]
```

### Validation before any write

The skill validates all inputs before creating any file:

- Subsystem names: lowercase letters, digits, hyphens; must start with a letter
- No duplicate names
- All source paths must exist in the repo
- No conflicts with existing files

**If any check fails, all errors are reported at once and no file is created.**

### Reactive split (from single to multi)

If you start in single mode and the overlay grows beyond 350 lines during draft,
the skill stops and proposes splitting:

```
The overlay has 387 lines, approaching the 400-line limit.
Potential subsystems I can identify: [list]

Options:
  [s] split — Convert to multi-overlay mode. You provide the final list.
  [k] keep  — Write the single overlay as-is.
```

If you choose split, the same validation and confirmation flow as `--mode multi` applies.
The already-filled content is distributed into spokes — no re-reading of source files needed.

### STATUS.md

In multi-overlay mode, `/agentdoc status` regenerates `docs/STATUS.md` with the
current scores of every spoke:

```markdown
# agentdoc Status

| Subsystem | Freshness | Human Input | Completeness | Stale Sections |
|---|---|---|---|---|
| proxy-data-plane | 94/100 | 20/100 | 90/100 | none |
| tls-and-crypto | 100/100 | 0/100 | 80/100 | none |
| xds-and-state | 75/100 | 30/100 | 95/100 | ## Key Patterns |
```

The CI gate applies the freshness threshold to **each spoke individually** —
one stale spoke fails the gate.

### CI with multi-overlay

`agentdoc-check.sh` detects multi-overlay mode automatically from the hub frontmatter
and checks all spokes. No configuration change needed.

---

## How it works

### Five phases

| Phase | When | What it does |
|---|---|---|
| **init** | No overlay exists | Scans repo, creates `CLAUDE.md` + overlay stub(s). `--mode multi` creates hub + spoke structure |
| **migrate** | Overlay exists, no `agentdoc:` frontmatter | Adds frontmatter interactively — never modifies content |
| **draft** | Overlay(s) with `completeness < 50` | Fills inferred sections, extracts claims. Detects if single overlay is too large and offers reactive split |
| **maintain** | Overlay(s) complete, code changed | Detects drift, auto-fixes mechanical drift, flags semantic drift. Processes each spoke independently in multi mode |
| **status** | Any time | Single mode: health dashboard. Multi mode: per-spoke table + aggregate scores, regenerates `STATUS.md` |

Phase is auto-detected when you run `/agentdoc` without arguments.

### Drift detection

Each `docs/agent-overlay.md` carries a `agentdoc:` YAML frontmatter block:

```yaml
---
agentdoc:
  scan: "c0eb538903d7019b3401d4c399e9641f0e0c4eff"   # HEAD at last run
  freshness: 94        # % of watch_paths unchanged since scan
  human_input: 20      # % of content backed by humans — set manually
  completeness: 90     # % of architectural surface documented
  inferred_sections:   # sections the maintain phase can auto-update
    - id: module-map
      heading: "## Module Map"
    - id: key-patterns
      heading: "## Key Patterns & Conventions"
  watch_paths:         # files monitored for drift
    - "src/server.rs"
    - "src/ports/"
    - "Cargo.toml"
  stale_sections: []   # sections with active review-needed comments
---
```

**Freshness** is computed deterministically:

```
freshness = round(100 × unchanged_watch_paths / total_watch_paths)
```

where "unchanged" means `git log $scan..HEAD -- $path` returns no commits.

### Human section protection

Sections listed in `inferred_sections` can be auto-regenerated.
Sections **not** listed are treated as human-authored and are **never modified** by any
automated phase. If the code they describe changes, the maintain phase adds a
`<!-- agentdoc:review-needed: <reason> -->` comment above the heading and stops.

Add your "What NOT to Do" section, ADR references, and tribal knowledge outside of
`inferred_sections`. They will survive every maintain run.

---

## CI integration

`agentdoc-check.sh` runs without Claude Code, making it fast and cheap for routine gates.

```bash
# Check documentation health (exit 1 if thresholds not met)
./scripts/agentdoc-check.sh check

# Print dashboard
./scripts/agentdoc-check.sh status

# Auto-repair drift via Claude Code, then check
./scripts/agentdoc-check.sh check --maintain
```

**Thresholds (all configurable via environment variables):**

| Variable | Default | Meaning |
|---|---|---|
| `AGENTDOC_FRESHNESS_THRESHOLD` | `80` | Minimum freshness score |
| `AGENTDOC_COMPLETENESS_THRESHOLD` | `70` | Minimum completeness score |
| `AGENTDOC_HUMAN_INPUT_THRESHOLD` | `0` | Minimum human_input score |
| `AGENTDOC_OVERLAY_PATH` | `docs/agent-overlay.md` | Path to overlay file |
| `CLAUDE_CODE_BIN` | `claude` | Path to Claude Code binary |

### GitHub Actions

Two jobs: `check` (MR gate, no Claude Code) and `maintain` (post-merge bot, opens a PR).

```yaml
# .github/workflows/agentdoc.yml
# See ci-examples/.github/workflows/agentdoc.yml for the full file.

- name: Check documentation health
  run: ./scripts/agentdoc-check.sh check
  env:
    AGENTDOC_FRESHNESS_THRESHOLD: 80
    AGENTDOC_HUMAN_INPUT_THRESHOLD: 20
```

> **Required:** `fetch-depth: 0` in `actions/checkout`. Without full history,
> `git log $scan..HEAD` cannot find the scan hash and freshness computation fails.

### GitLab CI

```yaml
# .gitlab-ci.yml — include or copy from ci-examples/.gitlab/agentdoc.yml

agentdoc:check:
  stage: test
  image: alpine/git:latest
  before_script:
    - apk add --no-cache bash
  script:
    - ./scripts/agentdoc-check.sh check
  variables:
    GIT_DEPTH: 0   # equivalent to fetch-depth: 0
  rules:
    - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
      changes:
        - src/**/*
        - docs/agent-overlay.md
```

Full workflow files including the auto-maintain bot job are in `ci-examples/`.

---

## Typical workflow

### First time

```bash
claude
/agentdoc init      # creates CLAUDE.md stub + overlay stub
# Review watch_paths in docs/agent-overlay.md, adjust if needed
/agentdoc draft     # fills the overlay
# Add "## What NOT to Do" section manually
# Set human_input score in frontmatter (e.g. 30)
./scripts/agentdoc-check.sh status
git add CLAUDE.md docs/ scripts/agentdoc-check.sh
git commit -s -m "docs: add agentdoc agentic documentation"
```

### After a code change

```bash
./scripts/agentdoc-check.sh status   # see what changed
claude
/agentdoc maintain                    # auto-repair mechanical drift, flag semantic drift
# Review sections with <!-- agentdoc:review-needed: --> comments
git add docs/agent-overlay.md docs/.agentdoc/claims.yml
git commit -s -m "docs: update overlay after src/ports/ changes"
```

---

## Claims file

`docs/.agentdoc/claims.yml` stores verifiable facts extracted from the codebase:

```yaml
claims:
  - id: arch-1
    type: pattern           # pattern|constraint|technology|data_flow|boundary|decision
    scope: overlay
    claim: "KonfluxServer holds one Option<Arc<dyn Port>> per integration domain"
    source: "src/server.rs"
    provenance:
      origin: inferred      # inferred (AI) | stated (human-validated)
      confidence: high      # high|medium|low
    stale: false
```

The maintain phase sets `stale: true` on claims whose source file changed, and auto-fixes
claims where the change was mechanical (renamed path, renamed type).

Commit `claims.yml` to git: it makes drift visible in PR reviews and survives session restarts.
Add `docs/.agentdoc/status.json` to `.gitignore`: it is regenerated on every CI run.

---

## Files in this directory

| File | Purpose |
|---|---|
| `skill.md` | The Claude Code skill — install to `~/.claude/skills/agentdoc.md` |
| `agentdoc-check.sh` | CI utility — install to `scripts/agentdoc-check.sh` |
| `agentdoc-design-guide.md` | Full design rationale: what, how, why for every decision |
| `ci-examples/.github/workflows/agentdoc.yml` | GitHub Actions workflow |
| `ci-examples/.gitlab/agentdoc.yml` | GitLab CI pipeline |

---

## Design rationale

See [`agentdoc-design-guide.md`](agentdoc-design-guide.md) for the full explanation of every
design decision, the theoretical backing (RAGAS, ETH Zurich study, WG Red Hat Agentic SDLC,
Anthropic Engineering Blog), known limitations, and how to defend this approach.
