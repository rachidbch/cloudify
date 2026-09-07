# Plan: Fix dependency var forwarding + restore guards + hermes-model

## Fix A — Recursive dependency var forwarding with first-write-wins

**File**: `lib/remote.sh` — `_cloudify_pkg_remote_vars()`

### Algorithm

1. **Always-forward vars** (`remote-vars.yaml`) loaded first — highest priority
2. **Named packages** processed **right-to-left** (last CLI arg wins)
3. For each package, **recursive** walk of `pkg_depends` lines;
   **parent before deps** (installed package claims vars before its dependencies)
4. **First-write-wins via temp file**: once a var is claimed, descendants can't override
5. **Cycle guard** via local associative array

### Priority order (highest → lowest)

```
remote-vars.yaml > rightmost-pkg > ... > leftmost-pkg > deps > deps-of-deps > ...
```

### Implementation sketch

```bash
function _cloudify_pkg_remote_vars() {
    local args=($@)
    local config_dir="${CLOUDIFY_CREDENTIALS_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/cloudify}"
    local in_install=false

    TMPFILE=$(mktemp /tmp/cloudify-pkg-vars-XXXXXX)
    trap "rm -f $TMPFILE" RETURN

    # -- Always-forward vars (highest priority) --
    local always_file="$config_dir/remote-vars.yaml"
    _cloudify_load_yaml_vars "$always_file"
    if [[ -f "$always_file" ]]; then
        while IFS= read -r line; do
            [[ "$line" =~ ^[A-Z_][A-Z0-9_]*: ]] || continue
            echo "${line%%:*}" >> "$TMPFILE"
        done < "$always_file"
    fi

    # -- Detect install command --
    for arg in "${args[@]}"; do
        [[ "$arg" == "install" || "$arg" == "--install" ]] && { in_install=true; break; }
    done

    if $in_install; then
        # Collect named packages (args after "install" that aren't flags)
        local -a pkgs=()
        local saw_install=false
        for arg in "${args[@]}"; do
            if [[ "$arg" == "install" || "$arg" == "--install" ]]; then
                saw_install=true; continue
            fi
            $saw_install && [[ "$arg" != -* ]] && pkgs+=("$arg")
        done

        # _try_claim: load yaml, export vars not already in TMPFILE
        _try_claim() {
            local yaml="$1"
            [[ -f "$yaml" ]] || return 0
            while IFS= read -r line; do
                [[ "$line" =~ ^[A-Z_][A-Z0-9_]*: ]] || continue
                local key="${line%%:*}"
                grep -q "^${key}$" "$TMPFILE" 2>/dev/null && continue  # already claimed
                echo "$key" >> "$TMPFILE"
                local value="${line#*:}"
                value="${value## }"; value="${value%% }"
                value="${value#\"}"; value="${value%\"}"
                value="${value#\'}"; value="${value%\'}"
                export "$key"="$value"
            done < "$yaml"
        }

        # Recursive walk with cycle guard
        declare -A _visited_pkgs
        _recurse_pkg_vars() {
            local pkg="$1"
            [[ -n "${_visited_pkgs[$pkg]:-}" ]] && return 0
            _visited_pkgs[$pkg]=1

            _try_claim "$config_dir/pkgs/${pkg}.yaml"       # parent first

            local recipe deps
            recipe=$(cloudify_package_recipe_path "$pkg" 2>/dev/null) || return 0
            deps=$(grep '^[[:space:]]*pkg_depends ' "$recipe" 2>/dev/null \
                | sed 's/.*pkg_depends //' | tr ' ' '\n')
            for dep in $deps; do
                [[ -n "$dep" ]] && _recurse_pkg_vars "$dep"
            done
        }

        # Right-to-left: last CLI arg = highest priority
        for ((i = ${#pkgs[@]} - 1; i >= 0; i--)); do
            _recurse_pkg_vars "${pkgs[i]}"
        done
    fi

    sort -u "$TMPFILE" 2>/dev/null
}
```

### Trace: `cloudify --on host install hermes-openwebui` (fresh)

```
Packages: [hermes-openwebui]
Right-to-left: hermes-openwebui

_recurse(hermes-openwebui):
  _try_claim(pkgs/hermes-openwebui.yaml):
    CLOUDIFY_HERMES_API_URL  → not in tmp → export + record ✓
    CLOUDIFY_HERMES_API_KEY  → not in tmp → export + record ✓
  grep recipe: pkg_depends hermes, pkg_depends open-webui
  → _recurse(open-webui):                                    # alphabetical order
      _try_claim(pkgs/open-webui.yaml):
        WEBUI_ADMIN_EMAIL     → not in tmp → export + record ✓
        WEBUI_ADMIN_PASSWORD  → not in tmp → export + record ✓
      grep recipe: pkg_depends docker, pkg_depends jq
      → _recurse(docker): no yaml
      → _recurse(jq): no yaml
  → _recurse(hermes): no yaml

Vars forwarded: CLOUDIFY_HERMES_API_URL, CLOUDIFY_HERMES_API_KEY,
                WEBUI_ADMIN_EMAIL, WEBUI_ADMIN_PASSWORD ✓
```

### Trace: `cloudify --on host install hermes-model hermes-openwebui`

```
Packages: [hermes-model, hermes-openwebui]
Right-to-left: hermes-openwebui first, then hermes-model

_recurse(hermes-openwebui):                                # rightmost, highest priority
  claims: CLOUDIFY_HERMES_API_URL, CLOUDIFY_HERMES_API_KEY
  → _recurse(open-webui):
      claims: WEBUI_ADMIN_EMAIL, WEBUI_ADMIN_PASSWORD

_recurse(hermes-model):
  _try_claim(pkgs/hermes-model.yaml):
    HERMES_MODEL_PROVIDER  → not in tmp → export + record ✓
    HERMES_MODEL_NAME      → not in tmp → export + record ✓
    HERMES_MODEL_API_KEY   → not in tmp → export + record ✓
  → _recurse(hermes): no yaml

All 6 vars forwarded ✓
```

### Trace: Override scenario — pkgA yaml declares same var as dep's yaml

```
pkgA.yaml:  FOO: "from-A"
pkgB.yaml:  FOO: "from-B"   (pkgB is a dependency of pkgA)

_recurse(pkgA):
  _try_claim(pkgA.yaml):
    FOO → not in tmp → export FOO="from-A" + record ✓
  → _recurse(pkgB):
      _try_claim(pkgB.yaml):
        FOO → ALREADY in tmp (pkgA claimed it) → SKIP ✓
        Result: FOO="from-A" (parent wins)
```

### Trace: Dual-install override — two CLI packages declare same var

```
pkgA.yaml:  BAR: "from-A"
pkgB.yaml:  BAR: "from-B"

CLI: install pkgA pkgB

Right-to-left: pkgB first (rightmost, higher priority)
  _recurse(pkgB): BAR="from-B" claimed ✓

_recurse(pkgA):
  BAR → ALREADY in tmp (pkgB claimed it) → SKIP ✓
  Result: BAR="from-B" (rightmost CLI arg wins) ✓
```

### Edge case: circular dependency

```
pkgA → depends on pkgB → depends on pkgA

_recurse(pkgA):
  visited[pkgA]=1
  → _recurse(pkgB):
      visited[pkgB]=1
      → _recurse(pkgA):
          visited[pkgA] already set → return 0 ✓  (no infinite loop)
```

### Edge case: pkg_depends with variables

```bash
# Hypothetical: pkg_depends "$DYNAMIC_PKG"
```

The `grep 'pkg_depends '` won't match this line (no literal package name after).
The dependency is silently skipped. This is acceptable — none of our recipes
use dynamic package names in pkg_depends, and the pattern would be unusual for
a package manager.

---

## Fix B — Restore standard install guards

### B1: `pkg/open-webui/init.sh`

Insert after variable defaults, before CLEAR_DATA block:

```bash
# --- Install guard ---
if command -v docker >/dev/null 2>&1 && [[ -f "${OWUI_DIR}/docker-compose.yml" ]] && \
   [[ -z "${CLOUDIFY_FORCE:-}" ]] && [[ -z "${CLOUDIFY_CLEAR_DATA:-}" ]]; then
    log_info "Open WebUI already installed. Skipping (use --clear-data to reinstall)."
    return 0
fi
```

Detection: `command -v docker` AND compose file exists.

### B2: `pkg/hermes-openwebui/init.sh`

Insert at top of file, before remote/local case split:

```bash
# --- Install guard ---
if [[ -f /opt/open-webui/docker-compose.yml ]] && \
   [[ -z "${CLOUDIFY_FORCE:-}" ]] && [[ -z "${CLOUDIFY_CLEAR_DATA:-}" ]]; then
    log_info "Hermes-Open WebUI already wired. Skipping (use --clear-data to reinstall)."
    return 0
fi
```

Hardcoded path — both remote and local cases produce this file.

### Key traces

| Scenario | Behavior |
|----------|----------|
| Fresh install | Guard check fails (compose absent) → proceeds ✓ |
| Re-run same config | Guard returns 0 → skips, no work ✓ |
| `--force install open-webui` | FORCE set → guard skipped → regenerates compose ✓ |
| `install hermes-openwebui` (dep pull of open-webui) | Depth>0, FORCE unset → open-webui guard skips ✓ (by design) |
| `--force install hermes-openwebui` (dep pull of open-webui) | Depth>0 unsets FORCE → open-webui guard still skips ✓ (by design) |

To change open-webui config: `cloudify --on host --force install open-webui` directly.

---

## Fix C — Create hermes-model package

### New file: `pkg/hermes-model/init.sh`

```bash
#!/usr/bin/env bash
# hermes-model — Configure the LLM model/provider for a Hermes instance
#
# Config (~/.config/cloudify/pkgs/hermes-model.yaml):
#   HERMES_MODEL_PROVIDER: "deepseek"
#   HERMES_MODEL_NAME:     "deepseek/deepseek-v4-pro"
#   HERMES_MODEL_API_KEY:  "sk-..."

HERMES_CONFIG="$HOME/.hermes/config.yaml"
HERMES_ENV="$HOME/.hermes/.env"

HERMES_MODEL_PROVIDER="${HERMES_MODEL_PROVIDER:-}"
HERMES_MODEL_NAME="${HERMES_MODEL_NAME:-}"
HERMES_MODEL_API_KEY="${HERMES_MODEL_API_KEY:-}"

pkg_depends hermes

# --- Validate ---
[[ -z "$HERMES_MODEL_PROVIDER" ]] && \
    die "HERMES_MODEL_PROVIDER required. Set in ~/.config/cloudify/pkgs/hermes-model.yaml"

# --- Provider → API key env var mapping ---
case "$HERMES_MODEL_PROVIDER" in
    deepseek)   API_KEY_VAR="DEEPSEEK_API_KEY" ;;
    openrouter) API_KEY_VAR="OPENROUTER_API_KEY" ;;
    novita)     API_KEY_VAR="NOVITA_API_KEY" ;;
    google)     API_KEY_VAR="GOOGLE_API_KEY" ;;
    custom)     API_KEY_VAR="CUSTOM_API_KEY" ;;
    *)          die "Unknown provider: $HERMES_MODEL_PROVIDER" ;;
esac

# --- Smart guard: skip if already configured ---
if [[ -f "$HERMES_CONFIG" ]]; then
    local cur_provider cur_model
    cur_provider=$(grep "^provider:" "$HERMES_CONFIG" 2>/dev/null | awk '{print $2}')
    cur_model=$(grep "^model:" "$HERMES_CONFIG" 2>/dev/null | awk '{print $2}')
    if [[ "$cur_provider" == "$HERMES_MODEL_PROVIDER" ]] && \
       [[ "$cur_model" == "$HERMES_MODEL_NAME" ]]; then
        log_info "Hermes already set to ${HERMES_MODEL_PROVIDER}/${HERMES_MODEL_NAME}. Skipping."
        return 0
    fi
fi

# --- Apply config ---
mkdir -p "$(dirname "$HERMES_CONFIG")"
cat > "$HERMES_CONFIG" << EOF
model: ${HERMES_MODEL_NAME}
provider: ${HERMES_MODEL_PROVIDER}
EOF

if [[ -n "$HERMES_MODEL_API_KEY" ]]; then
    if grep -q "^${API_KEY_VAR}=" "$HERMES_ENV" 2>/dev/null; then
        sed -i "s|^${API_KEY_VAR}=.*|${API_KEY_VAR}=${HERMES_MODEL_API_KEY}|" "$HERMES_ENV"
    else
        echo "${API_KEY_VAR}=${HERMES_MODEL_API_KEY}" >> "$HERMES_ENV"
    fi
fi

# --- Restart gateway ---
if systemctl --user is-active hermes-gateway >/dev/null 2>&1; then
    systemctl --user restart hermes-gateway
    sleep 2
    systemctl --user is-active hermes-gateway >/dev/null 2>&1 && \
        log_info "Gateway restarted." || \
        log_warn "Gateway failed to restart. Check: journalctl --user -u hermes-gateway -n 20"
fi

msg "${GREEN}Hermes model: ${HERMES_MODEL_PROVIDER}/${HERMES_MODEL_NAME}${RESET}"
```

### User config: `~/.config/cloudify/pkgs/hermes-model.yaml` (user creates)

```yaml
HERMES_MODEL_PROVIDER: "deepseek"
HERMES_MODEL_NAME: "deepseek/deepseek-v4-pro"
HERMES_MODEL_API_KEY: "sk-..."
```

### Smart guard traces

| Scenario | Guard check | Result |
|----------|-------------|--------|
| Fresh install (keylessai on hermes) | provider=custom ≠ deepseek | Proceed ✓ |
| Re-run same config | provider+model match | Skip ✓ |
| Change model (v4-pro→v4-flash) | model differs | Proceed ✓ |
| Switch provider (deepseek→openrouter) | provider differs | Proceed ✓ |
| Pulled as dependency (same config) | match | Skip ✓ |

No `--force` needed for model changes — the smart guard handles it.

### Supported providers + their API key env vars

| `HERMES_MODEL_PROVIDER` | Env var | Hermes native? |
|--------------------------|---------|----------------|
| `deepseek` | `DEEPSEEK_API_KEY` | ✓ |
| `openrouter` | `OPENROUTER_API_KEY` | ✓ |
| `novita` | `NOVITA_API_KEY` | ✓ |
| `google` | `GOOGLE_API_KEY` | ✓ |
| `custom` | `CUSTOM_API_KEY` | ✓ (base_url in config) |

---

## Verification

### 1. Unit tests
```bash
task test-unit
```

### 2. Var forwarding test (the bug we're fixing)
```bash
cloudify --on <test> install hermes-openwebui
ssh root@<test> 'grep WEBUI_ADMIN /opt/open-webui/docker-compose.yml'
# Must show rachidbch@gmail.com, NOT changeme@example.com
```

### 3. Guard idempotency
```bash
cloudify --on <test> install hermes-openwebui  # "already wired. Skipping"
cloudify --on <test> install open-webui        # "already installed. Skipping"
```

### 4. Force reinstall
```bash
cloudify --on <test> --force install open-webui
# Should regenerate compose, restart docker
```

### 5. hermes-model
```bash
cloudify --on <test> install hermes-model
ssh root@<test> 'cat /root/.hermes/config.yaml'
# provider: deepseek, model: deepseek/deepseek-v4-pro

cloudify --on <test> install hermes-model  # "already set... Skipping"
```

---

## File change summary

| File | Action |
|------|--------|
| `lib/remote.sh` | Rewrite `_cloudify_pkg_remote_vars()` — recursive first-write-wins |
| `pkg/open-webui/init.sh` | Restore standard install guard |
| `pkg/hermes-openwebui/init.sh` | Restore standard install guard |
| `pkg/hermes-model/init.sh` | **New** — recipe |
| `HISTORY.md` | Document all changes |
