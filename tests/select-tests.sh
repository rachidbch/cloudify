#!/usr/bin/env bash
# Test selection: an independent model decides which test files a change needs.
#
# Why a model and not the working agent: under mission pressure the working
# agent's reflex is to run everything ("safe") or to negotiate the rules away.
# Selection is therefore delegated to a fresh, tool-less model that sees only
# the change, the test inventory and the rules - never the mission, never the
# conversation. The working agent may ADD tests with a stated reason; it may
# never remove one the selector returned.
#
# Flow:
#   1. Changed paths: git diff against the green marker (results/acceptance/GREEN),
#      plus untracked files. No marker -> conservative fallback.
#   2. Deterministic candidate expansion: a lib module's tests are the files that
#      source it (grep for lib/<module>.sh) plus the file named after it; a router
#      change pulls every suite that invokes the router; schema/fixture changes
#      pull the schema suites. Over-inclusive by design.
#   3. The model refines: minimal set that can catch this change, "if in doubt
#      include", sanctuary files whose surface is touched are non-negotiable.
#   4. Parse + validate + cache by prompt hash. Any failure (no answer, bad
#      format, unknown path) falls back to the full candidate set - silence is
#      never an answer.
#
# Usage:
#   tests/select-tests.sh [--base <ref>] [--print] [--no-model]
#     --base <ref>   compare against <ref> instead of the green marker
#     --print        print the selection and exit (no task run)
#     --no-model     skip the model; print the deterministic candidate set
# Env:
#   CLOUDIFY_TEST_SELECTOR=codex|claude|gemini   (default: codex)
#   CLOUDIFY_TEST_SELECTOR_MODEL=<id>            (optional model override)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

base=""
print_only=0
use_model=1
while (( $# > 0 )); do
    case "$1" in
        --base) base="${2:-}"; shift 2 ;;
        --print) print_only=1; shift ;;
        --no-model) use_model=0; shift ;;
        -h|--help) sed -n '1,40p' "$0"; exit 0 ;;
        *) printf 'select-tests: unknown argument %s\n' "$1" >&2; exit 64 ;;
    esac
done

if [[ -z "$base" ]]; then
    if [[ -f results/acceptance/GREEN ]]; then
        base=$(cat results/acceptance/GREEN)
    else
        printf 'select-tests: no green marker (results/acceptance/GREEN); falling back to every test\n' >&2
        printf 'FALLBACK\n'
        ls tests/unit/*.bats 2>/dev/null
        exit 0
    fi
fi

changed=$( { git diff --name-only "$base" 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null; } | sort -u)
if [[ -z "$changed" ]]; then
    printf 'select-tests: nothing changed since %s\n' "$base"
    exit 0
fi

# --- deterministic candidate expansion (over-inclusive) -----------------------
declare -A cand=()
add() { for f in "$@"; do [[ -f "$f" ]] && cand["$f"]=1; done; }

for p in $changed; do
    case "$p" in
        lib/shadows/*.sh|lib/secrets/*.sh)
            while IFS= read -r f; do [[ -n "$f" ]] && cand["$f"]=1; done \
                < <(grep -l -E "shadows|secrets" tests/unit/*.bats 2>/dev/null)
            ;;
        lib/*.sh)
            m=$(basename "$p" .sh)
            add "tests/unit/$m.bats"
            while IFS= read -r f; do [[ -n "$f" ]] && cand["$f"]=1; done \
                < <(grep -l -F "$p" tests/unit/*.bats 2>/dev/null)
            ;;
        cloudify)
            add tests/unit/shell-router.bats tests/unit/utils.bats
            while IFS= read -r f; do [[ -n "$f" ]] && cand["$f"]=1; done \
                < <(grep -l -E '(^|[^a-z])cloudify ' tests/unit/*.bats 2>/dev/null)
            ;;
        schemas/*)
            add tests/unit/state.bats tests/unit/inventory.bats tests/unit/golden-fixtures.bats
            ;;
        pkg/*)
            pkgname=${p#pkg/}; pkgname=${pkgname%%/*}
            add "tests/integration/package-$pkgname.bats" tests/unit/package-api.bats tests/unit/packages.bats
            ;;
        tests/unit/*.bats)
            [[ -f "$p" ]] && cand["$p"]=1
            ;;
        runbooks/*)
            add tests/unit/runbooks.bats tests/unit/runbook-exec.bats tests/unit/runbook-replay.bats
            ;;
        Taskfile.yml|VERSION)
            add tests/unit/shell-router.bats
            ;;
    esac
done

for p in $changed; do
    case "$p" in
        pkg/*|lib/remote.sh)
            printf 'select-tests: NOTE - package/transport change: run tests/e2e explicitly (feature or milestone gate)\n' >&2
            ;;
    esac
done

mapfile -t candidates < <(printf '%s\n' "${!cand[@]}" | sort)
if (( ${#candidates[@]} == 0 )); then
    printf 'select-tests: no deterministic candidates; falling back to every test\n' >&2
    printf 'FALLBACK\n'
    ls tests/unit/*.bats tests/e2e/*.bats 2>/dev/null
    exit 0
fi

if (( ! use_model )); then
    printf 'CANDIDATES (deterministic)\n'
    printf '%s\n' ${candidates[@]+"${candidates[@]}"}
    exit 0
fi

# --- the prompt (neutral, no mission context) --------------------------------
sanctuary=""
[[ -f tests/SANCTUARY.md ]] && sanctuary=$(cat tests/SANCTUARY.md)
inventory=""
for f in "${candidates[@]}"; do
    names=$(grep -h '^@test' "$f" 2>/dev/null | sed 's/@test "//; s/" {$//' | head -40)
    inventory+="FILE $f"$'\n'"${names}"$'\n'
done

changed_list=${changed//$'\n'/ }
prompt=$(cat <<EOF
You select which regression tests a code change needs. You are a neutral
reviewer: you have no stake in the change and no mission to protect.

RULES
- Choose the MINIMAL set of test FILES that can catch a real regression in this diff.
- Include a file when the diff changes behavior it observes. Drop a file when it
  only shares an area with the change.
- If uncertain, include the file. Never drop a file because "probably fine".
- A file named in SANCTUARY below whose surface appears in the diff is mandatory.
- Output only file paths, one per line, then a final line "reason: <one sentence>".

CHANGED PATHS
$changed_list

DIFF (truncated)
$(git diff "$base" 2>/dev/null | head -c 60000)

SANCTUARY
${sanctuary:-none}

CANDIDATE TEST FILES (with their test names)
${inventory}
EOF
)

key=$(printf '%s' "$prompt" | sha256sum | cut -d' ' -f1)
cache_dir=results/test-select
mkdir -p "$cache_dir" 2>/dev/null
reply=""
if [[ -f "$cache_dir/$key" ]]; then
    reply=$(cat "$cache_dir/$key")
    printf 'select-tests: cached answer for this diff\n' >&2
else
    backend="${CLOUDIFY_TEST_SELECTOR:-codex}"
    case "$backend" in
        codex) reply=$(printf '%s' "$prompt" | codex exec - 2>/dev/null) ;;
        claude) reply=$(printf '%s' "$prompt" | claude -p --allowedTools "" 2>/dev/null) ;;
        gemini) reply=$(printf '%s' "$prompt" | gemini -p 2>/dev/null) ;;
        *) printf 'select-tests: unknown selector backend %s\n' "$backend" >&2; reply="" ;;
    esac
    if [[ -n "$reply" ]]; then
        printf '%s' "$reply" > "$cache_dir/$key"
    fi
fi

selected=()
while IFS= read -r line; do
    line=${line%% *}
    [[ "$line" == tests/*.bats && -f "$line" ]] || continue
    selected+=("$line")
done <<< "$reply"

if (( ${#selected[@]} == 0 )); then
    printf 'select-tests: the selector returned no usable file; falling back to the candidate set\n' >&2
    printf 'FALLBACK\n'
    printf '%s\n' ${candidates[@]+"${candidates[@]}"}
    exit 0
fi

# The selector may only narrow within the candidates; anything it adds would be
# unvetted for this diff, so an unknown path is an error, not a bonus.
for f in "${selected[@]}"; do
    if [[ -z "${cand[$f]:-}" ]]; then
        printf 'select-tests: selector named %s, which was not a candidate; falling back to the candidate set\n' "$f" >&2
        printf 'FALLBACK\n'
        printf '%s\n' ${candidates[@]+"${candidates[@]}"}
        exit 0
    fi
done

# Sanctuary enforcement: the model may not drop a load-bearing guard. If the
# diff touches a fragile surface, its guards are unioned back in, deterministically.
sanctuary_for_diff() {
    local p
    for p in $changed; do
        case "$p" in
            lib/vars.sh|lib/context.sh|lib/remote.sh)
                add2 tests/unit/context-raw-form.bats tests/unit/vars.bats \
                     tests/unit/context.bats tests/unit/context-wiring.bats \
                     tests/unit/golden-fixtures.bats tests/unit/remote-stdin.bats \
                     tests/unit/tmp-isolation.bats
                ;;
            lib/shadows/*.sh)
                add2 tests/unit/shadow.bats tests/unit/shadow-apt.bats tests/unit/git-shadow.bats
                ;;
            schemas/v1/*)
                add2 tests/unit/state.bats tests/unit/inventory.bats tests/unit/event.bats
                ;;
        esac
    done
    return 0
}
add2() {
    local f
    for f in "$@"; do
        [[ -f "$f" ]] || continue
        [[ " ${selected[*]} " == *" $f "* ]] || selected+=("$f")
    done
}
sanctuary_for_diff

grep '^reason:' <<< "$reply" | head -1 >&2 || true
printf '%s\n' "${selected[@]}"

if (( print_only )); then
    exit 0
fi

exec bash tests/remote-bats.sh selected "${selected[@]}"
