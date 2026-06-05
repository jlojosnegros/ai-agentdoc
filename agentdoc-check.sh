#!/usr/bin/env bash
# agentdoc-check.sh — CI utility for agentdoc documentation health
#
# Install: copy to scripts/agentdoc-check.sh in your repo, chmod +x
#
# Usage:
#   ./scripts/agentdoc-check.sh status              # Print health dashboard
#   ./scripts/agentdoc-check.sh check               # Exit 1 if thresholds not met
#   ./scripts/agentdoc-check.sh check --maintain    # Auto-maintain then check
#   ./scripts/agentdoc-check.sh maintain            # Run /agentdoc maintain via Claude Code
#
# Environment variables (all optional):
#   AGENTDOC_FRESHNESS_THRESHOLD   Minimum freshness score (default: 80)
#   AGENTDOC_COMPLETENESS_THRESHOLD Minimum completeness score (default: 70)
#   AGENTDOC_HUMAN_INPUT_THRESHOLD  Minimum human_input score (default: 0)
#   AGENTDOC_OVERLAY_PATH          Path to overlay file (default: docs/agent-overlay.md)
#   AGENTDOC_CLAIMS_PATH           Path to claims file (default: docs/.agentdoc/claims.yml)
#   AGENTDOC_STATUS_PATH           Path to status JSON (default: docs/.agentdoc/status.json)
#   CLAUDE_CODE_BIN                Path to claude binary (default: claude)
#   AGENTDOC_FAIL_ON_MISSING       Exit 1 if overlay missing (default: true)

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

OVERLAY="${AGENTDOC_OVERLAY_PATH:-docs/agent-overlay.md}"
CLAIMS="${AGENTDOC_CLAIMS_PATH:-docs/.agentdoc/claims.yml}"
STATUS_FILE="${AGENTDOC_STATUS_PATH:-docs/.agentdoc/status.json}"
FRESHNESS_THRESHOLD="${AGENTDOC_FRESHNESS_THRESHOLD:-80}"
COMPLETENESS_THRESHOLD="${AGENTDOC_COMPLETENESS_THRESHOLD:-70}"
HUMAN_INPUT_THRESHOLD="${AGENTDOC_HUMAN_INPUT_THRESHOLD:-0}"
FAIL_ON_MISSING="${AGENTDOC_FAIL_ON_MISSING:-true}"
CLAUDE_BIN="${CLAUDE_CODE_BIN:-claude}"

COMMAND="${1:-check}"
MAINTAIN_FLAG=false
if [[ "${2:-}" == "--maintain" ]]; then
  MAINTAIN_FLAG=true
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log()    { echo -e "${CYAN}[agentdoc]${RESET} $*"; }
ok()     { echo -e "${GREEN}[agentdoc] ✓${RESET} $*"; }
warn()   { echo -e "${YELLOW}[agentdoc] ⚠${RESET} $*"; }
error()  { echo -e "${RED}[agentdoc] ✗${RESET} $*" >&2; }
die()    { error "$*"; exit 1; }

# Check that we are in a git repo
require_git() {
  git rev-parse --git-dir >/dev/null 2>&1 || die "Not in a git repository."
}

# Check for overlay file
require_overlay() {
  if [[ ! -f "$OVERLAY" ]]; then
    if [[ "$FAIL_ON_MISSING" == "true" ]]; then
      die "Overlay not found: $OVERLAY — run /agentdoc init first."
    else
      warn "Overlay not found: $OVERLAY — skipping checks."
      exit 0
    fi
  fi
}

# ---------------------------------------------------------------------------
# YAML frontmatter parsing (pure bash + awk, no external YAML dependency)
# Extracts the agentdoc: block from the frontmatter of $OVERLAY.
# ---------------------------------------------------------------------------

# Returns the value of a scalar field from the agentdoc block.
# Usage: frontmatter_get "freshness"
frontmatter_get() {
  local field="$1"
  awk "
    /^---$/ { if (in_front) { exit } else { in_front=1; next } }
    in_front && /^agentdoc:/ { in_agentdoc=1; next }
    in_agentdoc && /^[^ ]/ { in_agentdoc=0 }
    in_agentdoc && /^  ${field}:/ {
      split(\$0, a, \":\")
      gsub(/[ \\t\"]+/, \"\", a[2])
      print a[2]
      exit
    }
  " "$OVERLAY"
}

# Returns all values of a list field from the agentdoc block.
# Usage: frontmatter_list "watch_paths"
frontmatter_list() {
  local field="$1"
  awk "
    /^---$/ { if (in_front) { exit } else { in_front=1; next } }
    in_front && /^agentdoc:/ { in_agentdoc=1; next }
    in_agentdoc && /^[^ ]/ { in_agentdoc=0 }
    in_agentdoc && /^  ${field}:/ { in_list=1; next }
    in_list && /^    - / {
      val=\$0
      gsub(/^    - [ \\t]*\"?/, \"\", val)
      gsub(/\"?[ \\t]*$/, \"\", val)
      print val
    }
    in_list && !/^    / { exit }
  " "$OVERLAY"
}

# Returns all values of a list field (stale_sections) as newline-separated.
frontmatter_stale_sections() {
  frontmatter_list "stale_sections"
}

# ---------------------------------------------------------------------------
# Freshness computation
# ---------------------------------------------------------------------------

# Given a git hash and a list of paths, computes:
#   changed_count, unchanged_count, freshness_score (0-100)
compute_freshness() {
  local scan_hash="$1"
  shift
  local watch_paths=("$@")
  local changed=0
  local unchanged=0

  for path in "${watch_paths[@]}"; do
    # Count commits on this path since scan_hash
    local n
    n=$(git log --oneline "${scan_hash}..HEAD" -- "$path" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$n" -gt 0 ]]; then
      ((changed++)) || true
    else
      ((unchanged++)) || true
    fi
  done

  local total=$(( changed + unchanged ))
  local score=100
  if [[ "$total" -gt 0 ]]; then
    score=$(( 100 * unchanged / total ))
  fi

  echo "$changed $unchanged $score"
}

# ---------------------------------------------------------------------------
# Claims parsing (YAML, counts only)
# ---------------------------------------------------------------------------

count_claims() {
  if [[ ! -f "$CLAIMS" ]]; then
    echo "0 0 0 0"
    return
  fi
  local total inferred stated stale
  total=$(grep -c '^\s*- id:' "$CLAIMS" 2>/dev/null || echo 0)
  inferred=$(grep -c "origin: inferred" "$CLAIMS" 2>/dev/null || echo 0)
  stated=$(grep -c "origin: stated" "$CLAIMS" 2>/dev/null || echo 0)
  stale=$(grep -c "stale: true" "$CLAIMS" 2>/dev/null || echo 0)
  echo "$total $inferred $stated $stale"
}

# ---------------------------------------------------------------------------
# Write status.json
# ---------------------------------------------------------------------------

write_status_json() {
  local scan="$1" freshness="$2" human_input="$3" completeness="$4"
  local stale_sections_json="$5"
  local claims_total="$6" claims_inferred="$7" claims_stated="$8" claims_stale="$9"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")

  local freshness_pass="false" completeness_pass="false" human_input_pass="false"
  [[ "$freshness"   -ge "$FRESHNESS_THRESHOLD"   ]] && freshness_pass="true"
  [[ "$completeness" -ge "$COMPLETENESS_THRESHOLD" ]] && completeness_pass="true"
  [[ "$human_input"  -ge "$HUMAN_INPUT_THRESHOLD"  ]] && human_input_pass="true"

  local overall="false"
  [[ "$freshness_pass" == "true" && "$completeness_pass" == "true" && "$human_input_pass" == "true" ]] \
    && overall="true"

  mkdir -p "$(dirname "$STATUS_FILE")"
  cat > "$STATUS_FILE" <<EOF
{
  "scan": "${scan}",
  "generated_at": "${ts}",
  "overlay": {
    "freshness": ${freshness},
    "human_input": ${human_input},
    "completeness": ${completeness},
    "stale_sections": ${stale_sections_json}
  },
  "claims": {
    "total": ${claims_total},
    "inferred": ${claims_inferred},
    "stated": ${claims_stated},
    "stale": ${claims_stale}
  },
  "ci_gates": {
    "freshness_threshold": ${FRESHNESS_THRESHOLD},
    "completeness_threshold": ${COMPLETENESS_THRESHOLD},
    "human_input_threshold": ${HUMAN_INPUT_THRESHOLD},
    "freshness_pass": ${freshness_pass},
    "completeness_pass": ${completeness_pass},
    "human_input_pass": ${human_input_pass},
    "overall_pass": ${overall}
  }
}
EOF
}

# ---------------------------------------------------------------------------
# Main logic: gather all data
# ---------------------------------------------------------------------------

gather() {
  require_git
  require_overlay

  SCAN=$(frontmatter_get "scan")
  HUMAN_INPUT=$(frontmatter_get "human_input")
  COMPLETENESS=$(frontmatter_get "completeness")

  # Validate scan hash exists in git history
  if ! git cat-file -e "${SCAN}^{commit}" 2>/dev/null; then
    warn "scan hash '$SCAN' not found in git history — freshness cannot be computed."
    FRESHNESS=0
    CHANGED=0
    UNCHANGED=0
  else
    mapfile -t WATCH_PATHS < <(frontmatter_list "watch_paths")
    if [[ "${#WATCH_PATHS[@]}" -eq 0 ]]; then
      warn "No watch_paths found in overlay frontmatter."
      FRESHNESS=100
      CHANGED=0
      UNCHANGED=0
    else
      read -r CHANGED UNCHANGED FRESHNESS < <(compute_freshness "$SCAN" "${WATCH_PATHS[@]}")
    fi
  fi

  mapfile -t STALE_SECTIONS < <(frontmatter_stale_sections)
  read -r CLAIMS_TOTAL CLAIMS_INFERRED CLAIMS_STATED CLAIMS_STALE < <(count_claims)

  # Build stale_sections JSON array
  STALE_JSON="[]"
  if [[ "${#STALE_SECTIONS[@]}" -gt 0 ]]; then
    STALE_JSON="["
    for s in "${STALE_SECTIONS[@]}"; do
      STALE_JSON+="\"$s\","
    done
    STALE_JSON="${STALE_JSON%,}]"
  fi
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_status() {
  gather
  echo ""
  echo -e "${BOLD}AGENTDOC STATUS${RESET}"
  echo "────────────────────────────────────────────────────"

  score_color() {
    local v="$1" threshold="$2"
    if   [[ "$v" -ge "$threshold" ]]; then echo -e "${GREEN}${v}/100${RESET}"
    elif [[ "$v" -ge $(( threshold - 20 )) ]]; then echo -e "${YELLOW}${v}/100${RESET}"
    else echo -e "${RED}${v}/100${RESET}"; fi
  }

  echo -e "Freshness:    $(score_color "$FRESHNESS" "$FRESHNESS_THRESHOLD")   [scan: ${SCAN:0:8} | changed: $CHANGED, unchanged: $UNCHANGED]"
  echo -e "Human input:  $(score_color "$HUMAN_INPUT" "$HUMAN_INPUT_THRESHOLD")"
  echo -e "Completeness: $(score_color "$COMPLETENESS" "$COMPLETENESS_THRESHOLD")"
  echo ""

  if [[ "${#WATCH_PATHS[@]:-0}" -gt 0 ]]; then
    echo "Watch paths:"
    for path in "${WATCH_PATHS[@]}"; do
      local n
      n=$(git log --oneline "${SCAN}..HEAD" -- "$path" 2>/dev/null | wc -l | tr -d ' ')
      if [[ "$n" -gt 0 ]]; then
        echo -e "  ${RED}✗${RESET} $path  ($n commit(s) since scan)"
      else
        echo -e "  ${GREEN}✓${RESET} $path"
      fi
    done
    echo ""
  fi

  echo -e "Claims: ${CLAIMS_TOTAL} total, ${CLAIMS_INFERRED} inferred, ${CLAIMS_STATED} stated, ${CLAIMS_STALE} stale"
  echo ""

  if [[ "${#STALE_SECTIONS[@]}" -gt 0 ]]; then
    echo "Stale sections (need human review):"
    for s in "${STALE_SECTIONS[@]}"; do
      echo -e "  ${YELLOW}⚠${RESET} $s"
    done
  else
    echo -e "Stale sections: ${GREEN}none${RESET}"
  fi

  echo ""
  echo "CI gates (thresholds: freshness≥${FRESHNESS_THRESHOLD}, completeness≥${COMPLETENESS_THRESHOLD}, human_input≥${HUMAN_INPUT_THRESHOLD}):"
  local overall_pass=true
  for gate in "freshness:$FRESHNESS:$FRESHNESS_THRESHOLD" \
              "completeness:$COMPLETENESS:$COMPLETENESS_THRESHOLD" \
              "human_input:$HUMAN_INPUT:$HUMAN_INPUT_THRESHOLD"; do
    local name score threshold
    IFS=: read -r name score threshold <<< "$gate"
    if [[ "$score" -ge "$threshold" ]]; then
      ok "$name: $score >= $threshold"
    else
      error "$name: $score < $threshold"
      overall_pass=false
    fi
  done

  echo "────────────────────────────────────────────────────"

  write_status_json "$SCAN" "$FRESHNESS" "$HUMAN_INPUT" "$COMPLETENESS" \
    "$STALE_JSON" "$CLAIMS_TOTAL" "$CLAIMS_INFERRED" "$CLAIMS_STATED" "$CLAIMS_STALE"
  log "Status written to $STATUS_FILE"
}

cmd_check() {
  gather

  local fail=false

  if [[ "$FRESHNESS" -lt "$FRESHNESS_THRESHOLD" ]]; then
    if $MAINTAIN_FLAG; then
      warn "Freshness $FRESHNESS < $FRESHNESS_THRESHOLD — running maintain..."
      cmd_maintain
      # Re-gather after maintain
      gather
    fi
  fi

  # Final gate evaluation
  if [[ "$FRESHNESS" -lt "$FRESHNESS_THRESHOLD" ]]; then
    error "freshness: $FRESHNESS < threshold $FRESHNESS_THRESHOLD"
    fail=true
  else
    ok "freshness: $FRESHNESS >= $FRESHNESS_THRESHOLD"
  fi

  if [[ "$COMPLETENESS" -lt "$COMPLETENESS_THRESHOLD" ]]; then
    error "completeness: $COMPLETENESS < threshold $COMPLETENESS_THRESHOLD"
    fail=true
  else
    ok "completeness: $COMPLETENESS >= $COMPLETENESS_THRESHOLD"
  fi

  if [[ "$HUMAN_INPUT" -lt "$HUMAN_INPUT_THRESHOLD" ]]; then
    error "human_input: $HUMAN_INPUT < threshold $HUMAN_INPUT_THRESHOLD"
    fail=true
  else
    ok "human_input: $HUMAN_INPUT >= $HUMAN_INPUT_THRESHOLD"
  fi

  if [[ "${#STALE_SECTIONS[@]}" -gt 0 ]]; then
    warn "Stale sections require human review:"
    for s in "${STALE_SECTIONS[@]}"; do
      warn "  - $s"
    done
  fi

  write_status_json "$SCAN" "$FRESHNESS" "$HUMAN_INPUT" "$COMPLETENESS" \
    "$STALE_JSON" "$CLAIMS_TOTAL" "$CLAIMS_INFERRED" "$CLAIMS_STATED" "$CLAIMS_STALE"

  if $fail; then
    error "Documentation health check FAILED."
    error "Run '/agentdoc maintain' in Claude Code to fix drift, or '/agentdoc draft' for low completeness."
    exit 1
  else
    ok "Documentation health check PASSED."
  fi
}

cmd_maintain() {
  if ! command -v "$CLAUDE_BIN" &>/dev/null; then
    die "Claude Code binary not found at '$CLAUDE_BIN'. Set CLAUDE_CODE_BIN env var."
  fi
  log "Running /agentdoc maintain via Claude Code..."
  "$CLAUDE_BIN" --print "/agentdoc maintain"
  log "Maintain complete."
}

# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

case "$COMMAND" in
  status)   cmd_status ;;
  check)    cmd_check ;;
  maintain) cmd_maintain ;;
  *)
    echo "Usage: $0 {status|check|maintain} [--maintain]"
    echo ""
    echo "  status              Print documentation health dashboard"
    echo "  check               Exit 1 if health thresholds not met"
    echo "  check --maintain    Auto-run maintain if stale, then check"
    echo "  maintain            Run /agentdoc maintain via Claude Code"
    echo ""
    echo "Environment variables:"
    echo "  AGENTDOC_FRESHNESS_THRESHOLD    (default: 80)"
    echo "  AGENTDOC_COMPLETENESS_THRESHOLD (default: 70)"
    echo "  AGENTDOC_HUMAN_INPUT_THRESHOLD  (default: 0)"
    echo "  AGENTDOC_OVERLAY_PATH           (default: docs/agent-overlay.md)"
    echo "  CLAUDE_CODE_BIN                 (default: claude)"
    exit 1
    ;;
esac
