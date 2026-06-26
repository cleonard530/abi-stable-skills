#!/usr/bin/env bash
# Resolve PROJECT_ROOT and CSRC_ROOT for migration helper scripts.
#
# Usage (from another script):
#   PROJECT_ROOT=""
#   CSRC_ROOT=""
#   # shellcheck source=resolve_paths.sh
#   source "$SCRIPT_DIR/resolve_paths.sh"
#   resolve_migration_paths "${ROOTS[0]}"
#
# PROJECT_ROOT defaults to the parent of CSRC_ROOT.
# CSRC_ROOT is taken from --csrc-root, or inferred by walking up from the
# first root file until a directory named "csrc" is found, or from
# <project-root>/csrc when --project-root is set.

_resolve_absolute_file() {
    local root="$1"
    if [[ -f "$root" ]]; then
        echo "$(cd "$(dirname "$root")" && pwd)/$(basename "$root")"
        return 0
    fi
    if [[ -f "$(pwd)/$root" ]]; then
        echo "$(cd "$(dirname "$(pwd)/$root")" && pwd)/$(basename "$root")"
        return 0
    fi
    echo "$root"
}

_infer_csrc_root_from_file() {
    local file="$1"
    local dir
    dir="$(dirname "$file")"
    while [[ "$dir" != "/" ]]; do
        if [[ "$(basename "$dir")" == "csrc" ]]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

resolve_migration_paths() {
    local first_root
    first_root="$(_resolve_absolute_file "$1")"

    if [[ -z "${CSRC_ROOT:-}" ]]; then
        if inferred="$(_infer_csrc_root_from_file "$first_root")"; then
            CSRC_ROOT="$inferred"
        elif [[ -n "${PROJECT_ROOT:-}" && -d "$PROJECT_ROOT/csrc" ]]; then
            CSRC_ROOT="$PROJECT_ROOT/csrc"
        else
            echo "error: cannot infer --csrc-root from $1; pass --csrc-root explicitly" >&2
            return 1
        fi
    fi
    CSRC_ROOT="$(cd "$CSRC_ROOT" && pwd)"

    if [[ -z "${PROJECT_ROOT:-}" ]]; then
        PROJECT_ROOT="$(cd "$CSRC_ROOT/.." && pwd)"
    else
        PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
    fi

    export PROJECT_ROOT CSRC_ROOT
}

# Resolve a root translation unit to an absolute path (requires CSRC_ROOT set).
resolve_root_file() {
    local root="$1"
    if [[ -f "$root" ]]; then
        echo "$(cd "$(dirname "$root")" && pwd)/$(basename "$root")"
        return 0
    fi
    if [[ -f "$CSRC_ROOT/$root" ]]; then
        echo "$(cd "$CSRC_ROOT" && pwd)/$root"
        return 0
    fi
    echo "error: cannot resolve root file: $root" >&2
    return 1
}
