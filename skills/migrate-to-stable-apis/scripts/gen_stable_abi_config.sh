#!/usr/bin/env bash
# Generate a fresh .stable-abi.yaml for stable-abi-transform from --init-config.
# Called by run_transform.sh / verify_closure.sh on every invocation unless
# the caller passes an explicit --config path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SKILL_DIR/../../.." && pwd)"
DEFAULT_TOOL="$REPO_ROOT/pytorch-stable-abi-transform/build/stable-abi-transform"

usage() {
    cat <<'EOF'
Usage: gen_stable_abi_config.sh --output PATH [options]

Required:
  --output PATH         Write the generated YAML here (created fresh each run)

Options:
  --project-root PATH   Extension / repo root (default: parent of --csrc-root)
  --csrc-root PATH      Directory containing .cpp/.cu sources (default: <project-root>/csrc)
  --mode MODE           audit | rewrite | verify | plan (default: rewrite)
  --tool PATH           stable-abi-transform binary

Extra include paths (repeatable; auto-detected paths are always added):
  --include-path PATH
EOF
}

PROJECT_ROOT=""
CSRC_ROOT=""
OUTPUT=""
MODE="rewrite"
TOOL="$DEFAULT_TOOL"
EXTRA_INCLUDES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project-root) PROJECT_ROOT="$2"; shift 2 ;;
        --csrc-root) CSRC_ROOT="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --mode) MODE="$2"; shift 2 ;;
        --tool) TOOL="$2"; shift 2 ;;
        --include-path) EXTRA_INCLUDES+=("$2"); shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [[ -z "$OUTPUT" ]]; then
    echo "error: --output is required" >&2
    usage >&2
    exit 1
fi

if [[ ! -x "$TOOL" ]]; then
    echo "error: stable-abi-transform not found at $TOOL" >&2
    exit 1
fi

if [[ -z "$CSRC_ROOT" ]]; then
    if [[ -n "$PROJECT_ROOT" && -d "$PROJECT_ROOT/csrc" ]]; then
        CSRC_ROOT="$PROJECT_ROOT/csrc"
    else
        echo "error: --csrc-root is required when project layout is not <root>/csrc" >&2
        exit 1
    fi
fi
CSRC_ROOT="$(cd "$CSRC_ROOT" && pwd)"

if [[ -z "$PROJECT_ROOT" ]]; then
    PROJECT_ROOT="$(cd "$CSRC_ROOT/.." && pwd)"
fi
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"

declare -A SEEN=()
INCLUDE_PATHS=()

add_include() {
    local path="$1"
    if [[ -z "$path" || ! -d "$path" ]]; then
        return
    fi
    path="$(cd "$path" && pwd)"
    if [[ -z "${SEEN[$path]:-}" ]]; then
        SEEN[$path]=1
        INCLUDE_PATHS+=("$path")
    fi
}

add_include "$CSRC_ROOT"
add_include "$CSRC_ROOT/include"
add_include "$PROJECT_ROOT"

for candidate in \
    "$CSRC_ROOT/../third_party/cutlass/include" \
    "$CSRC_ROOT/../third_party/cutlass/tools/util/include" \
    "$PROJECT_ROOT/third_party/cutlass/include" \
    "$PROJECT_ROOT/third_party/cutlass/tools/util/include"; do
    if [[ -f "$candidate/cutlass/cutlass.h" ]]; then
        add_include "$candidate"
    fi
done

if [[ -n "${CUDA_HOME:-}" && -d "${CUDA_HOME}/include" ]]; then
    add_include "${CUDA_HOME}/include"
elif [[ -d /usr/local/cuda/include ]]; then
    add_include /usr/local/cuda/include
fi

for path in "${EXTRA_INCLUDES[@]}"; do
    add_include "$path"
done

mkdir -p "$(dirname "$OUTPUT")"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

_detect_py() {
    if [[ -n "${VIRTUAL_ENV:-}" && -x "${VIRTUAL_ENV}/bin/python" ]]; then
        echo "${VIRTUAL_ENV}/bin/python"
    elif [[ -x "$REPO_ROOT/.venv/bin/python" ]]; then
        echo "$REPO_ROOT/.venv/bin/python"
    else
        echo "python3"
    fi
}

if [[ -z "${PYTORCH_ROOT:-}" ]]; then
    PY=$(_detect_py)
    PYTORCH_ROOT=$("$PY" -c "import os, torch; print(os.path.join(torch.__path__[0], 'include'))" 2>/dev/null) || true
fi

if [[ -z "${PYTORCH_ROOT:-}" ]] || [[ ! -d "$PYTORCH_ROOT/torch/csrc/stable" ]]; then
    echo "error: could not detect pytorch_root; install torch >= 2.6 or set PYTORCH_ROOT to torch/include." >&2
    exit 1
fi
PYTORCH_ROOT="$(cd "$PYTORCH_ROOT" && pwd)"

# Rewrite/audit parse legacy sources that may transitively include
# torch/csrc/python_headers.h → Python.h (e.g. via torch/extension.h or
# PYBIND11_MODULE blocks). Add the active interpreter's include dir so clang
# can parse before applying transforms.
PY=$(_detect_py)
PYTHON_INCLUDE=$("$PY" -c "import sysconfig; print(sysconfig.get_path('include'))" 2>/dev/null) || true
add_include "$PYTHON_INCLUDE"

"$TOOL" --init-config > "$TMP"

python3 - "$TMP" "$OUTPUT" "$CSRC_ROOT" "$MODE" "$PYTORCH_ROOT" "${INCLUDE_PATHS[@]}" <<'PY'
import re
import sys
from pathlib import Path

template_path, output_path, project_root, mode, pytorch_root = sys.argv[1:6]
include_paths = [Path(p).resolve() for p in sys.argv[6:]]

text = Path(template_path).read_text()
text = re.sub(r"^mode:.*$", f"mode: {mode}", text, flags=re.MULTILINE)
text = re.sub(
    r"^pytorch_root:.*$",
    f"pytorch_root: {pytorch_root}",
    text,
    flags=re.MULTILINE,
)
text = re.sub(
    r"^project_root:.*$",
    f"project_root: {Path(project_root).resolve()}",
    text,
    flags=re.MULTILINE,
)

if include_paths:
    lines = ["include_paths:"]
    lines.extend(f"  - {p}" for p in include_paths)
    extra = ["extra_includes:"]
    extra.extend(f"  - {p}" for p in include_paths)
    block = "\n".join(lines + [""] + extra)
    text = re.sub(
        r"# include_paths:\n(?:#   - .*\n)*\n# Additional include paths for verification.*\n# extra_includes:\n#   - .*\n",
        block + "\n",
        text,
        count=1,
    )

Path(output_path).write_text(text)
PY

echo ">>> Wrote fresh stable-abi config: $OUTPUT"
echo "    project_root=$CSRC_ROOT mode=$MODE pytorch_root=$PYTORCH_ROOT"
if [[ ${#INCLUDE_PATHS[@]} -gt 0 ]]; then
    printf '    include_paths:\n'
    printf '      %s\n' "${INCLUDE_PATHS[@]}"
fi
