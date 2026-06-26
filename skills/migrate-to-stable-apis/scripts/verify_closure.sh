#!/usr/bin/env bash
# Compile-verify root translation units against stable headers only. Skips when
# unavailable. Clang follows #includes from each root, so headers need not be
# listed separately.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SKILL_DIR/../../.." && pwd)"
DEFAULT_TOOL="$REPO_ROOT/pytorch-stable-abi-transform/build/stable-abi-transform"
GEN_CONFIG="$SCRIPT_DIR/gen_stable_abi_config.sh"
RESOLVE="$SCRIPT_DIR/resolve_paths.sh"

usage() {
    cat <<'EOF'
Usage: verify_closure.sh [options] <root-file> [<root-file> ...]

Options:
  --project-root PATH   Extension root (default: parent of --csrc-root)
  --csrc-root PATH      csrc directory (default: inferred from first root file)
  --config PATH         Use this YAML instead of generating a fresh one
  --tool PATH           stable-abi-transform binary
  --include-path PATH   Extra include path for generated config (repeatable)

Unless --config is passed, a fresh .stable-abi.yaml is generated each run.

Exits 0 with "SKIP:" when the tool is missing.
EOF
}

PROJECT_ROOT=""
CSRC_ROOT=""
CONFIG=""
CONFIG_WAS_GENERATED=0
TOOL="$DEFAULT_TOOL"
EXTRA_INCLUDES=()
ROOTS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project-root) PROJECT_ROOT="$2"; shift 2 ;;
        --csrc-root) CSRC_ROOT="$2"; shift 2 ;;
        --config) CONFIG="$2"; shift 2 ;;
        --tool) TOOL="$2"; shift 2 ;;
        --include-path) EXTRA_INCLUDES+=("$2"); shift 2 ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
        *) ROOTS+=("$1"); shift ;;
    esac
done
ROOTS+=("$@")

if [[ ${#ROOTS[@]} -eq 0 ]]; then
    usage >&2
    exit 1
fi

if [[ ! -x "$TOOL" ]]; then
    echo "SKIP: stable-abi-transform not available; compile-verify skipped."
    exit 0
fi

# shellcheck source=resolve_paths.sh
source "$RESOLVE"
resolve_migration_paths "${ROOTS[0]}"

TARGETS=()
declare -A SEEN=()
for root in "${ROOTS[@]}"; do
    resolved="$(resolve_root_file "$root")"
    if [[ -z "${SEEN[$resolved]:-}" ]]; then
        SEEN[$resolved]=1
        TARGETS+=("$resolved")
    fi
done

if [[ -z "$CONFIG" ]]; then
    CONFIG="$(mktemp /tmp/stable-abi-XXXXXX.yaml)"
    CONFIG_WAS_GENERATED=1
    GEN_ARGS=(
        --output "$CONFIG"
        --project-root "$PROJECT_ROOT"
        --csrc-root "$CSRC_ROOT"
        --mode verify
        --tool "$TOOL"
    )
    for path in "${EXTRA_INCLUDES[@]}"; do
        GEN_ARGS+=(--include-path "$path")
    done
    "$GEN_CONFIG" "${GEN_ARGS[@]}"
fi

echo ">>> compile-verify ${#TARGETS[@]} root file(s)"
printf '    %s\n' "${TARGETS[@]#$CSRC_ROOT/}"
"$TOOL" --config="$CONFIG" --mode=verify "${TARGETS[@]}"
STATUS=$?

if [[ "$CONFIG_WAS_GENERATED" -eq 1 ]]; then
    rm -f "$CONFIG"
fi

exit "$STATUS"
