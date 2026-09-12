#!/usr/bin/env bash
# schemas/v1/validate.sh
#
# Local authority for the schema_version 1 artifacts:
#   1. validate every fixture against its schema with jq alone;
#   2. assert every invalid fixture fails before any mutation could happen;
#   3. run the inventory-only migration report over the committed legacy
#      fixtures and prove it prints names and paths but no value.
# It writes nothing, uses no container, and needs no network.
#
# Report mode prints the same inventory for a real Cloudify configuration and
# ivps node root. It reads only field names, whitelisted metadata, and paths.
set -Eeuo pipefail
shopt -s nullglob

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
checker="$here/lib/schema-check.jq"
artifacts=(deployment-manifest package-state run event)

# Placeholder values committed in migration-fixtures/. The report must never
# print any of them; the default mode fails when one appears.
leak_tokens=(
    'PLACEHOLDER_LITERAL_SECRET'
    'PLACEHOLDER_LINE_ONE'
    'PLACEHOLDER_LINE_TWO'
    'PLACEHOLDER_SNAPSHOT_OUTPUT_LINE'
    'PLACEHOLDER_SECOND_LINE'
    'PLACEHOLDER_NOT_A_REAL_SECRET'
    'UExBQ0VIT0xERVJf'
    'UExBQ0VIT0xERVJfU05BUFNIT1Rf'
    '@vault:kv'
    '@@literal-at-sign'
    'cloudai:cloudify'
    'demo.example.com'
    'rdp://'
)

fail=0

usage() {
    cat >&2 <<'EOF'
usage: validate.sh                     validate every schema fixture
       validate.sh report [options]    inventory-only migration report
report options:
  --config-dir DIR   Cloudify config root (default: $CLOUDIFY_CREDENTIALS_DIR, else $XDG_CONFIG_HOME/cloudify, else ~/.config/cloudify)
  --nodes-dir DIR    ivps nodes root (default: $IVPS_CONFIG_DIR/nodes, else $XDG_CONFIG_HOME/ivps/nodes, else ~/.config/ivps/nodes)
EOF
}

usage_die() {
    usage
    exit 2
}

_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# _store_keys <file> - print the KEY of every `KEY: value` line, never a value.
_store_keys() {
    local file="$1" line key
    [[ -f "$file" ]] || return 0
    while IFS= read -r line; do
        [[ -n "$line" && "$line" != \#* && "$line" == *:* ]] || continue
        key=$(_trim "${line%%:*}")
        [[ -n "$key" ]] || continue
        printf '%s\n' "$key"
    done < "$file"
}

# _store_field <file> <key> - print the value of one whitelisted metadata key.
# Only record metadata keys (status, version, deployment, node, instance,
# package) may be read this way; var.* and value.* are never read.
_store_field() {
    local file="$1" want="$2" line key
    [[ -f "$file" ]] || return 0
    while IFS= read -r line; do
        [[ -n "$line" && "$line" != \#* && "$line" == *:* ]] || continue
        key=$(_trim "${line%%:*}")
        [[ "$key" == "$want" ]] || continue
        printf '%s' "$(_trim "${line#*:}")"
        return 0
    done < "$file"
    return 0
}

# _snapshot_report <run-name> <path> - names and paths only.
_snapshot_report() {
    local name="$1" path="$2" line key
    printf '  run %s path=%s runbook=%s\n' "$name" "$path" "$(_store_field "$path" runbook)"
    while IFS= read -r line; do
        [[ -n "$line" && "$line" == *:* ]] || continue
        key="${line%%:*}"
        case "$key" in
            target.*) printf '  run-target %s %s\n' "$name" "${key#target.}" ;;
            value.*) printf '  run-value %s %s\n' "$name" "${key#value.}" ;;
            output.*) printf '  run-output %s %s\n' "$name" "${key#output.}" ;;
            *) : ;;
        esac
    done < "$path"
}

# _record_report <path> <bucket> - one registry record, names and paths only.
_record_report() {
    local path="$1" bucket="$2" dir id pkg
    dir="${path%/config.yaml}"
    pkg="${dir##*/}"
    dir="${dir%/pkgs/*}"
    id="${dir##*/}"
    printf 'record path=%s bucket=%s deployment=%s node=%s instance=%s package=%s status=%s version=%s\n' \
        "$path" "$bucket" "$id" \
        "$(_store_field "$path" node)" "$(_store_field "$path" instance)" "$pkg" \
        "$(_store_field "$path" status)" "$(_store_field "$path" version)"
    local key
    while IFS= read -r key; do
        [[ "$key" == var.* ]] || continue
        printf '  record-var %s\n' "${key#var.}"
    done < <(_store_keys "$path")
}

# migration_report <config-dir> <nodes-dir> - inventory only.
migration_report() {
    local config_dir="$1" nodes_dir="$2"
    local deployments=0 runs=0 records=0
    local d id c f root path bucket key

    for d in "$config_dir"/deployments/*/; do
        [[ -d "$d" ]] || continue
        d="${d%/}"
        id="${d##*/}"
        deployments=$((deployments + 1))
        printf 'deployment %s dir=%s\n' "$id" "$d"
        c="$d/config.yaml"
        [[ -f "$c" ]] && printf '  inputs %s\n' "$c"
        while IFS= read -r key; do
            [[ -n "$key" ]] || continue
            printf '  input-key %s\n' "$key"
        done < <(_store_keys "$c")
        for f in "$d"/runs/*.yaml; do
            [[ -f "$f" ]] || continue
            runs=$((runs + 1))
            _snapshot_report "${f##*/}" "$f"
        done
    done

    for root in "$nodes_dir" "$config_dir/registry/hosts"; do
        [[ -d "$root" ]] || continue
        for path in "$root"/*/deployments/*/pkgs/*/config.yaml "$root"/*/*/deployments/*/pkgs/*/config.yaml; do
            [[ -f "$path" ]] || continue
            records=$((records + 1))
            if [[ "$path" == "$config_dir/registry/hosts/"* ]]; then
                bucket=external-host
            else
                case "${path#"$root"/}" in
                    */*/deployments/*) bucket=instance ;;
                    *) bucket=node ;;
                esac
            fi
            _record_report "$path" "$bucket"
        done
    done

    printf 'summary deployments=%d runs=%d records=%d\n' "$deployments" "$runs" "$records"
}

validate_fixtures() {
    local artifact schema f n_valid n_invalid=0
    local total_valid=0 total_invalid=0
    local valid invalid

    for artifact in "${artifacts[@]}"; do
        schema="$here/$artifact.schema.json"
        valid=("$here/fixtures/$artifact/valid"/*.json)
        invalid=("$here/fixtures/$artifact/invalid"/*.json)
        if [[ ! -f "$schema" ]]; then
            printf 'FAIL missing schema: %s\n' "$schema"
            fail=$((fail + 1))
            continue
        fi
        if (( ${#valid[@]} < 2 )) || (( ${#invalid[@]} < 2 )); then
            printf 'FAIL %s: needs at least two valid and two invalid fixtures\n' "$artifact"
            fail=$((fail + 1))
            continue
        fi
        n_valid=0
        n_invalid=0
        for f in "${valid[@]}"; do
            if jq -e --slurpfile schema "$schema" -f "$checker" "$f" >/dev/null 2>&1; then
                n_valid=$((n_valid + 1))
            else
                printf 'FAIL %s: valid fixture rejected: %s\n' "$artifact" "${f#"$here"/}"
                fail=$((fail + 1))
            fi
        done
        for f in "${invalid[@]}"; do
            if jq -e --slurpfile schema "$schema" -f "$checker" "$f" >/dev/null 2>&1; then
                printf 'FAIL %s: invalid fixture accepted: %s\n' "$artifact" "${f#"$here"/}"
                fail=$((fail + 1))
            else
                n_invalid=$((n_invalid + 1))
            fi
        done
        total_valid=$((total_valid + n_valid))
        total_invalid=$((total_invalid + n_invalid))
        printf '%s: %d valid accepted, %d invalid rejected\n' "$artifact" "$n_valid" "$n_invalid"
    done

    local out token deployments runs records
    out=$(migration_report "$here/migration-fixtures/config" "$here/migration-fixtures/ivps-nodes")
    for token in "${leak_tokens[@]}"; do
        if grep -qF -- "$token" <<<"$out"; then
            printf 'FAIL migration report printed a value (token: %s)\n' "$token"
            fail=$((fail + 1))
        fi
    done
    deployments=$(grep -c '^deployment ' <<<"$out" || true)
    runs=$(grep -c '^  run ' <<<"$out" || true)
    records=$(grep -c '^record ' <<<"$out" || true)
    if (( deployments != 1 || runs != 3 || records != 3 )); then
        printf 'FAIL migration report inventory: deployments=%s runs=%s records=%s (expected 1/3/3)\n' \
            "$deployments" "$runs" "$records"
        fail=$((fail + 1))
    fi
    printf 'migration report: %s deployment, %s run snapshots, %s registry records, no value printed\n' \
        "$deployments" "$runs" "$records"
    printf 'summary: %d valid accepted, %d invalid rejected, %d failures\n' \
        "$total_valid" "$total_invalid" "$fail"
    (( fail == 0 ))
}

report_mode() {
    shift
    local config_dir="${CLOUDIFY_CREDENTIALS_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/cloudify}"
    local nodes_dir="${IVPS_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/ivps}/nodes"
    while (( $# > 0 )); do
        case "$1" in
            --config-dir) config_dir="${2:-}"; shift 2 ;;
            --nodes-dir) nodes_dir="${2:-}"; shift 2 ;;
            -h | --help) usage; exit 0 ;;
            *) usage_die ;;
        esac
    done
    [[ -n "$config_dir" && -n "$nodes_dir" ]] || usage_die
    migration_report "$config_dir" "$nodes_dir"
}

case "${1:-validate}" in
    validate) validate_fixtures ;;
    report) report_mode "$@" ;;
    -h | --help) usage; exit 0 ;;
    *) usage_die ;;
esac
