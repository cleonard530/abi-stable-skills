#!/usr/bin/env bash
# Mechanical first pass via stable-abi-transform. Exits 0 and skips when the tool
# is unavailable so migrate-to-stable-apis can fall back to manual rewrites.
#
# Pass root translation units (.cu/.cpp). The tool rewrites each root and any
# project headers they #include (under project_root in the generated config).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SKILL_DIR/../../.." && pwd)"
DEFAULT_TOOL="$REPO_ROOT/pytorch-stable-abi-transform/build/stable-abi-transform"
GEN_CONFIG="$SCRIPT_DIR/gen_stable_abi_config.sh"
RESOLVE="$SCRIPT_DIR/resolve_paths.sh"

usage() {
    cat <<'EOF'
Usage: run_transform.sh [options] <root-file> [<root-file> ...]

Options:
  --project-root PATH   Extension root (default: parent of --csrc-root)
  --csrc-root PATH      csrc directory (default: inferred from first root file)
  --config PATH         Use this YAML instead of generating a fresh one
  --tool PATH           stable-abi-transform binary
  --dry-run             Preview diff without writing
  --include-path PATH   Extra include path for generated config (repeatable)

Unless --config is passed, a fresh .stable-abi.yaml is generated each run via
stable-abi-transform --init-config (see pytorch-stable-abi-transform user guide).

Exits 0 with "SKIP:" message when the tool is missing.
EOF
}

PROJECT_ROOT=""
CSRC_ROOT=""
CONFIG=""
CONFIG_WAS_GENERATED=0
TOOL="$DEFAULT_TOOL"
DRY_RUN=0
EXTRA_INCLUDES=()
ROOTS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project-root) PROJECT_ROOT="$2"; shift 2 ;;
        --csrc-root) CSRC_ROOT="$2"; shift 2 ;;
        --config) CONFIG="$2"; shift 2 ;;
        --tool) TOOL="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
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
    echo "SKIP: stable-abi-transform not found at $TOOL"
    echo "      Build: cmake -GNinja -B $REPO_ROOT/pytorch-stable-abi-transform/build \\"
    echo "             -S $REPO_ROOT/pytorch-stable-abi-transform && \\"
    echo "             ninja -C $REPO_ROOT/pytorch-stable-abi-transform/build"
    echo "      Continuing with manual rewrites only."
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
        --mode rewrite
        --tool "$TOOL"
    )
    for path in "${EXTRA_INCLUDES[@]}"; do
        GEN_ARGS+=(--include-path "$path")
    done
    "$GEN_CONFIG" "${GEN_ARGS[@]}"
fi

echo ">>> stable-abi-transform will rewrite ${#TARGETS[@]} root file(s)"
printf '    %s\n' "${TARGETS[@]#$CSRC_ROOT/}"

ARGS=(--config="$CONFIG" --mode=rewrite)
if [[ "$DRY_RUN" -eq 1 ]]; then
    ARGS+=(--dry-run)
fi
ARGS+=("${TARGETS[@]}")

echo ">>> Running: $TOOL ${ARGS[*]}"
cd "$PROJECT_ROOT"
"$TOOL" "${ARGS[@]}"
STATUS=$?

if [[ "$CONFIG_WAS_GENERATED" -eq 1 ]]; then
    rm -f "$CONFIG"
fi

exit "$STATUS"
