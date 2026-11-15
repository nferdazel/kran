#!/usr/bin/env bash
# contract-check.sh — check repos against the Qouver CI/CD golden contract.
#
# Read-only: it never writes to a repo and never touches a host. Run it from a
# repo's CI (`./ops/scripts/contract-check.sh .`) to fail the build on drift, or
# point it at ~/Projects to see every project side by side.
#
# Language detection drives the stack-specific rules, so the same file serves a
# Nim monorepo, a Go service, a pnpm workspace and a static book site:
#
#   universal (any repo, any stack)
#     W1  at least one workflow under .github/workflows
#     W2  every job declares timeout-minutes (15)
#     W3  no github.event*/inputs interpolation inside a run: block (shell injection)
#     W4  a secret scan runs (gitleaks or trufflehog)
#     W5  .github/dependabot.yml covers actions + the repo's own ecosystem
#     D1  deploy script exists and is reachable from the documented path
#     D2  fail-closed ref guard, exact form: if [ "$REF" != "refs/heads/main" ]
#     D3  flock concurrency lock
#     D4  no commit-SHA image tag left behind (:local / :prev only)
#     D5  smoke check present
#     D6  rollback to :prev present
#
#   per stack (detected, not configured)
#     node  (pnpm-lock.yaml | package-lock.json)  dependency CVE scan: pnpm/npm
#                                                 audit, osv-scanner or trivy
#     go    (go.mod)                              govulncheck in CI
#     nim   (*.nimble | config.nims)              deps pinned by commit in
#                                                 *.nimble / nimble.paths; no CVE
#                                                 scanner exists, so the rule is
#                                                 "locked deps + gitleaks", not audit
#     static(quartz/_quarto.yml, no runtime deps) no dependency rule, gitleaks only
#
#   container / frontend (DEPLOY-FLOW.md §13.7)
#     C1  no paths:/paths-ignore: under on: (a filtered workflow creates no check-run)
#     C2  gate tolerates `skipped` only for image-api / image-web
#     C3  apps/web/ implies an image-web job and a quadlet on 127.0.0.1:<port>
#     C4  a changes job ships its path-filter test table
#     C5  one Dockerfile name: apps/<part>/Dockerfile, never Containerfile*
#     C6  buildx uses context: . with file: apps/<part>/Dockerfile
#     C7  a ghcr pull in a deploy script fails closed: only manifest-unknown is
#         "this side did not change"
#
# Usage: ./ops/scripts/contract-check.sh [repo-dir ...]
#        (default: every git repo directly under ~/Projects)
# Exit:  0 = contract met, 1 = violation, 2 = usage error.
set -uo pipefail

TIMEOUT_MIN=${TIMEOUT_MIN:-15}
REF_GUARD='if [ "$REF" != "refs/heads/main" ]; then'
ROOT="${1:-}"

GREEN=$'\033[32m'; RED=$'\033[31m'; YEL=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
[ -t 1 ] || { GREEN=''; RED=''; YEL=''; DIM=''; RST=''; }

FAILS=0; WARNS=0; REPOS=0; REPO_FAILS=0

ok()   { printf '  %sOK%s   %s\n' "$GREEN" "$RST" "$1"; }
bad()  { printf '  %sFAIL%s %s\n' "$RED" "$RST" "$1"; FAILS=$((FAILS+1)); REPO_FAILS=$((REPO_FAILS+1)); }
warn() { printf '  %sWARN%s %s\n' "$YEL" "$RST" "$1"; WARNS=$((WARNS+1)); }
note() { printf '  %s--%s   %s\n' "$DIM" "$RST" "$1"; }

usage() { sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 2; }
[ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] && usage

# ---------------------------------------------------------------- detection ---
stacks_of() {
  local d="$1" s=''
  { [ -f "$d/pnpm-lock.yaml" ] || [ -f "$d/package-lock.json" ] || [ -f "$d/yarn.lock" ]; } && s="$s node"
  { [ -f "$d/go.mod" ] || [ -n "$(find "$d" -maxdepth 4 -name go.mod -not -path '*/node_modules/*' -print -quit 2>/dev/null)" ]; } && s="$s go"
  { ls "$d"/*.nimble >/dev/null 2>&1 || [ -f "$d/config.nims" ] || [ -n "$(find "$d" -maxdepth 3 -name '*.nimble' -not -path '*/node_modules/*' -print -quit 2>/dev/null)" ]; } && s="$s nim"
  { [ -f "$d/_quarto.yml" ] || [ -d "$d/quartz" ]; } && s="$s static"
  printf '%s\n' "${s:-unknown}"
}

deploy_script() {
  local d="$1" c
  for c in ops/scripts/deploy-vps.sh ops/scripts/deploy-static.sh deploy/deploy-vps.sh \
           scripts/deploy-vps.sh ops/scripts/deploy.sh; do
    [ -f "$d/$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

# --------------------------------------------------------------- workflows ---
# Every job under `jobs:` must carry timeout-minutes. Job keys are the only
# 2-space-indented keys in that block; anything left at EOF is reported too.
check_timeouts() {
  local f="$1" missing
  missing=$(awk -v want="timeout-minutes" '
    /^jobs:[[:space:]]*$/ { injobs=1; next }
    injobs && /^[^[:space:]#]/ { if (job != "" && !seen) print job; injobs=0; job=""; seen=0 }
    injobs && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
      if (job != "" && !seen) print job
      job=$0; sub(/^  /,"",job); sub(/:.*/,"",job); seen=0; next
    }
    injobs && /^    timeout-minutes:[[:space:]]*[0-9]+/ { seen=1 }
    END { if (injobs && job != "" && !seen) print job }
  ' "$f")
  if [ -n "$missing" ]; then
    bad "$(basename "$f"): job tanpa timeout-minutes -> $(echo $missing | tr '\n' ' ')"
  elif grep -q "^    timeout-minutes: $TIMEOUT_MIN" "$f"; then
    ok "$(basename "$f"): timeout-minutes $TIMEOUT_MIN"
  else
    warn "$(basename "$f"): timeout ada tapi bukan $TIMEOUT_MIN menit"
  fi
}

# A run: block (inline or scalar) must not interpolate a context expression.
check_injection() {
  local f="$1" hits
  hits=$(awk '
    { line=$0
      if (line ~ /^[[:space:]]*(-[[:space:]]*)?run:[[:space:]]*[^|>]/) {
        if (line ~ /\$\{\{[[:space:]]*(github\.event|github\.head_ref|inputs\.)/) print NR": "$0
        next
      }
      if (line ~ /^[[:space:]]*(-[[:space:]]*)?run:[[:space:]]*[|>]/) { inrun=1; ind=match(line,/[^ ]/)-1+2; next }
      if (inrun) {
        if (line ~ /^[[:space:]]*$/ ) next
        if (match(line,/[^ ]/)-1 < ind) { inrun=0; next }
        if (line ~ /\$\{\{[[:space:]]*(github\.event|github\.head_ref|inputs\.)/) print NR": "$0
      }
    }' "$f")
  [ -n "$hits" ] && bad "$(basename "$f"): context expression di dalam run -> $hits" ||
    note "$(basename "$f"): tidak ada interpolasi konteks di run"
}

# Repos that are deliberately out of the migration scope in DEPLOY-FLOW.md, with
# the rule ids they are exempt from. Everything else must satisfy the contract.
repo_exempt() {
  case "$(basename "$1")" in
    majadu)          echo "C3 C5" ;;  # §4: repo is 404 on GitHub, the container is being retired
    badminton-match) echo "C3" ;;     # §13.6: owner excluded its frontend from the container migration
  esac
}

badid() {
  local id="$1" exempt; shift
  exempt=" $(repo_exempt "$CUR_REPO") "
  case "$exempt" in
    *" $id "*) note "$id exempt for $(basename "$CUR_REPO"): $*" ;;
    *) bad "$*" ;;
  esac
}

# ------------------------------------------------- §13.7 additional rules ---
# 9  frontend container shape: apps/web/ implies an image-web job and a quadlet
#    publishing a loopback port
# 10 no `paths:` / `paths-ignore:` under `on:` (a filtered workflow creates no
#    check-run, and a deploy gate waiting for one hangs)
# 11 `skipped` tolerated only for the image jobs inside `gate`
# 12 a repo with a `changes` job ships the path-filter table that proves it
# 13 one Dockerfile name: apps/<part>/Dockerfile, never Containerfile*
# 14 buildx call uses context `.` and file apps/<part>/Dockerfile
# 15 a deploy script pulling from ghcr treats only manifest-unknown as "not built"
check_paths_filter() {
  local f="$1" hits
  hits=$(awk '
    /^on:[[:space:]]*$/ { inon=1; next }
    inon && /^[^[:space:]#]/ { inon=0 }
    inon && /^[[:space:]]*(paths|paths-ignore):/ { print NR": "$0 }
  ' "$f")
  [ -n "$hits" ] && bad "$(basename "$f"): paths filter under on: -> $hits" ||
    note "$(basename "$f"): no paths filter under on:"
}

check_gate_skips() {
  local f="$1" lines bad_lines
  lines=$(awk '
    /^  gate:[[:space:]]*$/ { ingate=1; next }
    ingate && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ { ingate=0 }
    ingate && /skipped/ { print NR": "$0 }
  ' "$f")
  [ -n "$lines" ] || return 0
  # only a `skipped` tied to a required job is a defect; a skipped image job or a
  # job that is itself PR-only (badminton's mutation) is legitimate
  bad_lines=$(printf '%s\n' "$lines" | sed 's/^[0-9]*:[[:space:]]*//' | grep -vE '^#' |
    grep -E 'R_(CHECK|TEST|CONTRACT|SECURITY|VERIFY)|needs\.(check|test|contract|security|verify)|"(check|test|contract|security|verify)"' || true)
  [ -n "$bad_lines" ] &&
    bad "$(basename "$f"): gate tolerates skipped for a required job -> $bad_lines"
}

check_dockerfile() {
  local d="$1" stray inapps
  stray=$(find "$d" \( -name node_modules -o -name .git \) -prune -o \
    -type f \( -name 'Containerfile*' -o -name '*.containerfile' \) -print 2>/dev/null | sed "s|^$d/||")
  [ -n "$stray" ] && badid C5 "container file naming: -> $(echo $stray | tr '\n' ' ')"
  inapps=$(find "$d" \( -name node_modules -o -name .git \) -prune -o \
    -type f -name 'Dockerfile*' -print 2>/dev/null | sed "s|^$d/||" | grep -vE '^apps/[A-Za-z0-9_.-]+/Dockerfile$' || true)
  [ -n "$inapps" ] && badid C5 "Dockerfile outside apps/<part>/ -> $(echo $inapps | tr '\n' ' ')"
  if [ -z "$stray" ] && [ -z "$inapps" ] &&
     [ -n "$(find "$d" \( -name node_modules -o -name .git \) -prune -o -type f -name Dockerfile -print -quit 2>/dev/null)" ]; then
    ok "container file naming: apps/<part>/Dockerfile only"
  fi
}

check_build_call() {
  local f="$1"
  grep -q 'docker/build-push-action' "$f" || return 0
  grep -qE '^[[:space:]]*context:[[:space:]]*\.$' "$f" ||
    bad "$(basename "$f"): buildx tanpa context: ."
  grep -qE '^[[:space:]]*file:[[:space:]]*apps/[A-Za-z0-9_.-]+/Dockerfile$' "$f" ||
    bad "$(basename "$f"): buildx tanpa file: apps/<part>/Dockerfile"
}

check_web_container() {
  local d="$1" wf="$2" quad
  [ -d "$d/apps/web" ] || return 0
  grep -lqE 'image-web:' $wf 2>/dev/null && ok "frontend: image-web job ada" ||
    badid C3 "frontend: apps/web/ ada tapi tanpa job image-web"
  quad=$(find "$d" \( -name node_modules -o -name .git \) -prune -o \
    -type f \( -name '*.container' -o -name '*.quadlet' \) -print 2>/dev/null)
  if [ -n "$quad" ] && grep -qE '^PublishPort=127\.0\.0\.1:[0-9]+:8080$' $quad 2>/dev/null; then
    ok "frontend: quadlet mem-publish port loopback"
  else
    warn "frontend: belum ada quadlet web dengan PublishPort 127.0.0.1:<port>:8080"
  fi
}

check_pull_fails_closed() {
  local d="$1" script="$2"
  grep -q 'ghcr.io' "$d/$script" 2>/dev/null || return 0
  grep -qE 'podman pull' "$d/$script" 2>/dev/null || return 0
  # a pull whose failure stops the deploy is already fail-closed
  if grep -qE '(if ! podman pull|podman pull.*\|\|[[:space:]]*(fail|die|exit))' "$d/$script"; then
    ok "pull: gagal pull = deploy gagal"
  elif grep -qE 'if podman pull' "$d/$script"; then
    grep -qiE 'manifest unknown|no such manifest|manifest for .* not found' "$d/$script" &&
      ok "pull: hanya manifest-unknown yang dianggap 'tidak berubah'" ||
      bad "pull: 'if podman pull' tanpa pembeda manifest-unknown (registry mati = deploy sukses)"
  else
    warn "pull: tidak ada guard eksplisit di sekitar podman pull"
  fi
}

check_path_filter_table() {
  local d="$1" wf="$2" test
  grep -lqE '^[[:space:]]+changes:' $wf 2>/dev/null || return 0
  test=$(find "$d" \( -name node_modules -o -name .git \) -prune -o \
    -type f \( -name 'path-filter-test.sh' -o -name '*path-filter*test*' \) -print -quit 2>/dev/null)
  [ -n "$test" ] && ok "changes: tabel path filter ada (${test#$d/})" ||
    bad "changes: job changes tanpa tabel uji path filter"
}

# -------------------------------------------------------------- per project ---
check_repo() {
  local d="$1" name stacks wf deploy
  CUR_REPO="$d"
  name=$(basename "$d")
  REPO_FAILS=0
  stacks=$(stacks_of "$d")
  printf '\n%s\n' "$name ($(echo $stacks | tr ' ' ','))"

  # W1 workflows
  wf=$(ls "$d"/.github/workflows/*.y*ml 2>/dev/null)
  if [ -z "$wf" ]; then
    bad "tidak ada .github/workflows/*.yml"
  else
    ok "$(echo "$wf" | wc -l | tr -d ' ') workflow"
    local f
    for f in $wf; do
      check_timeouts "$f"; check_injection "$f"; check_paths_filter "$f"
      check_gate_skips "$f"; check_build_call "$f"
    done
    check_web_container "$d" "$wf"
    check_path_filter_table "$d" "$wf"
  fi

  # container file naming is a repo-wide rule, independent of CI
  check_dockerfile "$d"

  # W4 secret scan
  if [ -n "$wf" ] && grep -liE 'gitleaks|trufflehog|secret-scan' $wf 2>/dev/null | grep -q .; then
    ok "secret scan ada di CI"
  else
    bad "tidak ada secret scan (gitleaks/trufflehog) di CI"
  fi

  # W5 dependabot
  local db="$d/.github/dependabot.yml"
  if [ ! -f "$db" ]; then
    bad "tidak ada .github/dependabot.yml"
  else
    grep -qE 'package-ecosystem:[[:space:]]*"?github-actions' "$db" &&
      ok "dependabot: github-actions" || bad "dependabot tanpa ekosistem github-actions"
    case "$stacks" in
      *node*) grep -qE 'package-ecosystem:[[:space:]]*"?npm' "$db" && ok "dependabot: npm" || bad "dependabot tanpa npm";;
      *go*)   grep -qE 'package-ecosystem:[[:space:]]*"?gomod' "$db" && ok "dependabot: gomod" || bad "dependabot tanpa gomod";;
    esac
  fi

  # dependency CVE scan, per stack (rules are independent: a monorepo can be
  # node and go at once, and each gets its own gate)
  case "$stacks" in
    *node*)
      if [ -n "$wf" ] && grep -liE 'pnpm audit|npm audit|osv-scanner|aquasecurity/trivy|snyk' $wf 2>/dev/null | grep -q .; then
        ok "node: dependency CVE scan (audit/osv/trivy) ada"
      else
        bad "node: tidak ada dependency CVE scan (pnpm audit / osv-scanner / trivy)"
      fi;;
  esac
  case "$stacks" in
    *go*)
      grep -rq 'govulncheck' "$d"/.github/workflows 2>/dev/null &&
        ok "go: govulncheck ada" || bad "go: tidak ada govulncheck (go.mod terdeteksi)"
      ;;
  esac
  case "$stacks" in
    *nim*)
      if grep -rqE '[0-9a-f]{7,40}' "$d"/*.nimble "$d"/config.nims 2>/dev/null; then
        ok "nim: dependency dipin (commit ref di .nimble/config.nims)"
      else
        warn "nim: tidak ada pin commit di .nimble/config.nims (pin manual)"
      fi
      note "nim: tidak ada scanner CVE untuk paket Nim; gitleaks + review pin yang berlaku";;
    *unknown*)
      warn "stack tidak dikenali, aturan dependency di-skip (tambah deteksi di stacks_of)";;
  esac

  # deploy contract
  if ! deploy=$(deploy_script "$d"); then
    note "tanpa deploy script (project statis / tidak di-deploy lewat VPS)"
  else
    printf '  %sdeploy: %s%s\n' "$DIM" "$deploy" "$RST"
    grep -qF -- "$REF_GUARD" "$d/$deploy" &&
      ok "ref guard fail-closed, bentuk persis" ||
      bad "ref guard tidak sesuai (harus: $REF_GUARD)"
    grep -qE 'flock[[:space:]]' "$d/$deploy" &&
      ok "flock lock ada" || bad "tidak ada flock"
    if grep -qE 'podman (tag|build)[^\n]*\$\{?(REVID|COMMIT_SHA|GITHUB_SHA|SHA|REV)\}?' "$d/$deploy"; then
      bad "ada tag image pakai commit SHA (harus :local / :prev saja)"
    else
      ok "tidak ada tag commit SHA"
    fi
    grep -qE ':local' "$d/$deploy" && grep -qE ':prev' "$d/$deploy" &&
      ok ":local dan :prev dipakai" || bad ":local/:prev tidak lengkap"
    grep -qiE 'smoke|health|readyz|wait_healthy' "$d/$deploy" && ok "smoke/health check ada" ||
      { case "$deploy" in *static*) warn "tanpa smoke eksplisit (deploy static)";; *) bad "tidak ada smoke/health check";; esac; }
    grep -qiE 'rollback|:prev' "$d/$deploy" && ok "jalur rollback ada" || bad "tidak ada rollback"
    check_pull_fails_closed "$d" "$deploy"
  fi

  REPOS=$((REPOS+1))
  [ "$REPO_FAILS" -eq 0 ] && printf '  %s=> PASS%s\n' "$GREEN" "$RST"
}

# -------------------------------------------------------------------- main ---
if [ -n "$ROOT" ]; then
  for r in "$@"; do
    [ -d "$r" ] || { echo "error: not a directory: $r" >&2; exit 2; }
    check_repo "$(cd "$r" && pwd)"
  done
else
  for r in "$HOME"/Projects/*/; do
    r=${r%/}
    [ -d "$r/.git" ] || continue
    check_repo "$r"
  done
fi

printf '\n%s repos, %s violasi, %s warning\n' "$REPOS" "$FAILS" "$WARNS"
[ "$FAILS" -eq 0 ]
