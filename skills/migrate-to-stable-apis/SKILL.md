---
name: migrate-to-stable-apis
description: Rewrite unstable PyTorch C++/CUDA API calls to their `torch::stable` / `torch::headeronly` / `aoti_torch` equivalents and swap registration macros to `STABLE_TORCH_LIBRARY_*` with `TORCH_BOX`. Optionally runs `stable-abi-transform` first for the mechanical pass (~86% of edits), then manual cleanup for flags, `TORCH_BOX`, build wiring, and verify. Falls back to the same manual-only workflow when the tool is unavailable. Runs in two modes: **incremental** (file-by-file, after `scaffold-stable-target` set up a parallel target — each file's path flips from legacy `sources=` to stable `sources=` as it migrates) or **one-shot** (no parallel target — adds `TORCH_TARGET_VERSION` to the existing `ext_modules` entry and rewrites every in-scope file in one pass). Use after `pybind-to-torch-library`, `migrate-meta-fns-to-python`, and `migrate-autograd-fns-to-python` have run.
allowed-tools: Read, Bash, Edit, Write, Glob, Grep
---

# Migrate to Stable APIs

This is the bulk-rewrite step. By the time this skill runs, the project should:

- Use `TORCH_LIBRARY` / `TORCH_LIBRARY_IMPL` for op registration (pybind removed).
- Have any C++ Meta impls moved to Python `register_fake`.
- Have any C++ Autograd impls moved to Python `register_autograd`.

The plan's `dispatch_order` (set by `assess-abi-migration` Step 7) determines which mode this skill runs in.

## Two modes

**Incremental** (when `scaffold-stable-target` ran). A second `ext_modules` entry (stable, with `TORCH_TARGET_VERSION` flags) already exists alongside the legacy one. Both share the same `csrc/`. Files stay where they are on disk; each file is in exactly one entry's `sources=` at any time. Migrating a file = rewrite it in place + remove its path from the legacy `sources=` and add it to the stable `sources=`. Both `.so`'s load at import time and register into the same `torch.ops.<lib_namespace>` namespace (the dispatcher is fine with this because each op is compiled into only one `.so`). The legacy target keeps serving un-migrated ops throughout.

**One-shot** (when `scaffold-stable-target` was skipped). There is no parallel target. This skill adds `TORCH_TARGET_VERSION` (and optionally `Py_LIMITED_API`) to the existing `ext_modules` entry, then rewrites every in-scope file's APIs + registration macros, then compile-verifies each file against stable headers. No `sources=` flipping (there's nothing to flip between). The wheel built after this skill is the final stable wheel.

The rewrite work (steps 1–3 below) is identical in both modes. Step 4 (build target wiring) differs.

## Prerequisites

- PyTorch 2.10+, the same version as the desired build version (verify: `python3 -c "import torch; print(torch.__version__)"`).
- The full reference docs in this skill's `references/`:
  - [api-mapping.md](references/api-mapping.md) — old API → stable replacement table.
  - [migration-example.md](references/migration-example.md) — concrete before/after.
  - [common-issues.md](references/common-issues.md) — known build/runtime pitfalls.
  - [stack-and-boxing.md](references/stack-and-boxing.md) — `TORCH_BOX` internals, `StableIValue` conversions, `torch_call_dispatcher`. Only needed for advanced cases.

## Inputs

- `plan_path`: path to the migration plan JSON, OR ask the user for the following:
- Mode: derived from whether `scaffold-stable-target` appears in the plan's `dispatch_order`.
- File list: the plan's `unstable-api` concern entries (incremental mode can also cross-check against the legacy `ext_modules` entry's `sources=`).
- `lib_namespace`: the existing registration namespace (e.g., `extension_cpp`). Stays the same throughout the migration — do **not** suffix it with `_stable`.
- `project_root` / `csrc_root`: from the migration plan JSON (required for helper scripts).

## Optional tooling: stable-abi-transform

When `stable-abi-transform` is available, run it **before** the manual rewrite steps. When it is not, skip straight to manual steps — behavior is identical to a migration without the tool.

### Detection and config

```bash
TOOL="<repo>/pytorch-stable-abi-transform/build/stable-abi-transform"
```

Build the tool if missing (see below). **Do not reuse a stale `.stable-abi.yaml` from another project** (e.g. the sample under `pytorch-stable-abi-transform/build/`).

**Generate a fresh config on every transform/verify run.** The helper scripts call `gen_stable_abi_config.sh`, which runs `stable-abi-transform --init-config` (see `pytorch-stable-abi-transform/docs/user-guide.md`), then patches `project_root`, `mode`, `include_paths`, and `extra_includes` for the current migration scope. The YAML is written to a temp file and deleted after the run.

Pass `--config PATH` only when you intentionally want a hand-edited config (e.g. debugging a single file). Otherwise let the scripts generate one.

Auto-detected `include_paths` cover: `csrc/`, `csrc/include/`, the repo root, vendored CUTLASS if present, and CUDA headers. Add project-specific paths with `--include-path` (repeatable) on `run_transform.sh` / `verify_closure.sh`.

Use the helper scripts (they exit 0 with `SKIP:` only when the **tool binary** is missing):

| Script | Purpose |
|--------|---------|
| `scripts/gen_stable_abi_config.sh` | Fresh `.stable-abi.yaml` from `--init-config` + project paths |
| `scripts/run_transform.sh` | `--mode=rewrite` on root translation unit(s) |
| `scripts/verify_closure.sh` | `--mode=verify` on the same root(s) |

Build the tool if missing:

```bash
cmake -GNinja -B <repo>/pytorch-stable-abi-transform/build \
  -S <repo>/pytorch-stable-abi-transform
ninja -C <repo>/pytorch-stable-abi-transform/build
```

### Work split (transform vs manual)

| Owner | Typical work |
|-------|----------------|
| **`stable-abi-transform`** | Include swaps; `at::`/`c10::` → stable types; `TORCH_CHECK` → `STD_TORCH_CHECK`; `data_ptr` → `const_data_ptr`/`mutable_data_ptr`; method→free-fn; CUDA guard/stream; `TORCH_LIBRARY` → `STABLE_TORCH_LIBRARY` *macro text*; `AT_DISPATCH_*` → `THO_DISPATCH_*` |
| **Manual (steps 1–3 below)** | `[FLAG]` resolution; `TensorOptions` decomposition; stable project dispatch macros; `TORCH_BOX(&fn)` on impls; `torch_bindings.cpp` / `ops.h`; CMake / `setup.py` wiring; shared infra headers; undo bad transform edits (e.g. stable includes inside `#ifndef TORCH_TARGET_VERSION`, or rewriting headers that never used torch APIs) |

The tool rewrites each root translation unit and any project headers they `#include` (under `project_root` in the generated config). It does **not** wire the build, move schema defs, or add boxing — that is always manual.

**When transform helps:** host-side `.cu`/`.cpp` with many `at::` calls (~15–30% of agent time saved on first pass).

**When to skip transform:** device-only headers with no unstable torch APIs; pure CUDA kernel bodies; iterations 2+ of a retry loop; after transform broke a dual-path `#ifndef TORCH_TARGET_VERSION` block — fix manually instead.

**When to re-run transform:** fresh file on first pass only; or after large manual edits reintroduced unstable patterns the tool knows (use `--dry-run` first).

## Workflow

**Incremental mode**: plan chunk order first (step 0 below), then process one chunk at a time. After each chunk is fully migrated and compile-verify passes, commit and advance. Within a chunk, work file-by-file so failures stay localized; the chunk boundary is what gets committed.

**One-shot mode**: rewrite every in-scope file in one pass (steps A–3 below), then do step 4 once for the whole extension, then compile-verify once. The whole migration lands as a single change. Skip step 0.

### 0. (Incremental mode) Plan chunk order before any rewrites

Before touching any files, plan how the migration will land. The wrong order forces follow-up chunks to wait on dependencies; the right order unblocks parallel work.

**Strategy**

1. **Identify shared dependencies.** Grep the in-scope files for:
   - Shared helper headers (`utils.h`, `dispatch_utils.h`, `<project>_ops.h`, etc.) that multiple `.cpp`/`.cu` files include.
   - Common helper functions / inline templates defined in those headers.
   - `TORCH_LIBRARY` schema definitions (the `m.def(...)` blocks, which usually live in one `torch_bindings.cpp`-style file) — `TORCH_LIBRARY_IMPL` impls depend on the schemas being registered first.

   These are the **foundation files**: anything that other in-scope files transitively depend on.

2. **Group files into chunks.** Sensible grouping criteria, in priority order:
   - **Foundation first — bundled with at least one real consumer.** The first chunk contains the shared headers + the schema definition file **plus at least one migrated kernel that actually uses them**. Don't land foundation as a standalone chunk: a PR that adds stable helpers nobody calls reads as dead code to reviewers and doesn't prove the helpers actually work end-to-end. Pick a small, representative kernel from the same family as the helpers (e.g., the simplest op in `csrc/attention/` if you're migrating attention helpers) and migrate it in the same chunk. Once this lands, downstream chunks can be developed in parallel by different contributors.
   - **Same directory / same kernel family.** Files in `csrc/quantization/`, `csrc/attention/`, etc. usually share helpers and review context. Keeping a chunk within one subdirectory makes the diff easier to review.
   - **Same coverage gaps.** Files that all need the same workaround (e.g., the `empty_strided` rewrite from [common-issues.md](references/common-issues.md)) chunk well together — the reviewer sees the workaround once.

3. **Cap chunk size at ~1000 lines of diff.** This is a soft ceiling. Reviewers stall on bigger diffs; CI cycles get longer; bisecting a regression gets harder. Estimate per file roughly: each migrated file ≈ original LOC × 1.5 (includes + API swaps add lines). If a single file blows past 1k by itself, that's fine — it's one file, the diff is unavoidable — but don't combine it with others.

4. **Order the chunks so downstream work isn't blocked.** Foundation chunk #1. Then chunks that touch independent areas can be ordered by complexity (simple first to build confidence) or by who's working on them (if multiple contributors). A chunk that depends on another chunk's helper-migration must come after.

**Output of this step**

A short ordered list of chunks, each with:
- A 1-line title (e.g., `chunk-01: shared headers + torch_bindings + first attention kernel`).
- The list of files it touches. **Chunk 1 must include at least one real kernel migration** that exercises the foundation, not just the foundation files alone.
- Estimated diff size (rough).
- Which upstream chunks (by number) it depends on, if any.

Surface this list to the user before starting any rewrites:

> "Planned `<N>` chunks for this migration. Chunk 1 (`<title>`) lands the shared helpers — review and merge it first so chunks 2–`<N>` can be worked in parallel. Estimated diff sizes: …. OK to proceed?"

After the user approves, save the chunk plan to the migration plan JSON under a `chunks` field so the orchestrator can resume mid-migration without re-planning.

The per-chunk loop is steps A–6 below — apply them to every file in the chunk, then compile-verify + commit + advance to the next chunk.

Track **iteration** per chunk (start at 1). Cap at **5 iterations** across the A→6 loop. On iteration 2+, **skip step A** unless large manual edits reintroduced unstable patterns.

### A. Mechanical rewrite (stable-abi-transform, optional)

**Only on iteration 1** of each chunk (or each root file in a single-file migration).

1. Resolve scope: the chunk's root translation units (`.cu`/`.cpp` entry points). Pass each root to the scripts below — Clang follows `#include` from each root, so headers do not need to be listed separately.
2. Preview (recommended). The script generates a **fresh** `.stable-abi.yaml` via `stable-abi-transform --init-config` (temp file, deleted after the run). Pass `--csrc-root` when sources are not under `<project_root>/csrc`. Add external headers (CUTLASS, etc.) with `--include-path` (repeatable):

   ```bash
   .cursor/skills/migrate-to-stable-apis/scripts/run_transform.sh \
     --dry-run \
     --project-root <project_root> \
     --csrc-root <csrc_root> \
     [--include-path <cutlass_include>] \
     <root-file>
   ```

3. Run the rewrite:

   ```bash
   .cursor/skills/migrate-to-stable-apis/scripts/run_transform.sh \
     --project-root <project_root> \
     --csrc-root <csrc_root> \
     [--include-path <cutlass_include>] \
     <root-file>
   ```

   If the script prints `SKIP:`, the tool binary is missing — build it (below) or continue with manual rewrites.

4. If the tool exits non-zero, fix config/parse issues before continuing. Resolve any `[FLAG]` items using `references/api-mapping.md`, `references/common-issues.md`, and `pytorch-stable-abi-transform/docs/claude-skill.md`.

   **Parse error `Python.h` file not found:** rewrite-phase only — see [common-issues.md § Python.h](references/common-issues.md). Ensure Python dev headers are installed; `gen_stable_abi_config.sh` adds them automatically. If pybind is `#ifdef`-disabled in your build, mirror that `-D` in `compiler_flags` via a hand-edited `--config`.

**Do not** re-run transform on later iterations unless you deliberately reintroduced unstable patterns.

### 1. Update includes (manual cleanup)

Remove legacy includes and replace with the stable subset.

```cpp
// REMOVE:
// #include <torch/extension.h>
// #include <ATen/ATen.h>
// #include <ATen/cuda/CUDAContext.h>
// #include <c10/cuda/CUDAGuard.h>
// #include <torch/library.h>

// ADD (include only what you need):
#include <torch/csrc/stable/tensor.h>
#include <torch/csrc/stable/library.h>
#include <torch/csrc/stable/ops.h>
#include <torch/csrc/stable/accelerator.h>

#include <torch/headeronly/core/ScalarType.h>
#include <torch/headeronly/util/Exception.h>
#include <torch/headeronly/util/shim_utils.h>

// For CUDA stream access:
#include <torch/csrc/inductor/aoti_torch/c/shim.h>  // or torch/csrc/stable/c/shim.h on newer versions
#include <cuda_runtime.h>
```

Allowed header roots (anything outside these will fail to compile under `TORCH_TARGET_VERSION`):

- `torch/csrc/stable/`
- `torch/headeronly/`
- `torch/csrc/inductor/aoti_torch/`

### 2. Apply API replacements (manual cleanup)

Walk each file and apply anything `stable-abi-transform` missed — or everything, if step A was skipped. Use [references/api-mapping.md](references/api-mapping.md). The most frequent ones:

| Old | Stable |
|---|---|
| `at::Tensor` / `torch::Tensor` | `torch::stable::Tensor` |
| `TORCH_CHECK(...)` | `STD_TORCH_CHECK(...)` (arguments unchanged) |
| `at::empty({...}, options)` | `torch::stable::new_empty(ref, {sizes}, dtype)` |
| `at::zeros({...}, options)` | `torch::stable::new_zeros(ref, {sizes}, dtype)` |
| `at::empty_like(t)` | `torch::stable::empty_like(t)` |
| `t.contiguous()` | `torch::stable::contiguous(t)` |
| `t.data_ptr<T>()` (read) | `t.const_data_ptr<T>()` |
| `t.data_ptr<T>()` (write) | `t.mutable_data_ptr<T>()` |
| `t.sizes()` / `t.strides()` | `t.size(i)` / `t.stride(i)` (per-element) |
| `at::kFloat` | `torch::headeronly::ScalarType::Float` |
| `at::kCUDA` | `torch::headeronly::kCUDA` |
| `tensor.device() == kCUDA` | `tensor.device().type() == torch::headeronly::kCUDA` |
| `at::pad(x, ...)` / `x.pad(...)` | `torch::stable::pad(x, ...)` (always free-function form; Tensor methods → ATen variant) |
| `c10::cuda::CUDAGuard guard(t.device())` | `torch::stable::accelerator::DeviceGuard guard(t.get_device_index())` |
| `at::cuda::getCurrentCUDAStream()` | `aoti_torch_get_current_cuda_stream(t.get_device_index(), &stream_ptr)` (see common-issues) |
| `C10_CUDA_KERNEL_LAUNCH_CHECK()` | `STD_CUDA_KERNEL_LAUNCH_CHECK()` |

See [api-mapping.md](references/api-mapping.md) for the full table, including strided tensor creation, layout checks, and scalar type enums.

### 3. Swap registration macros to STABLE_* (manual cleanup)

The transform rewrites `TORCH_LIBRARY` → `STABLE_TORCH_LIBRARY` macro **text** but does **not** add `TORCH_BOX`. After this step, op registrations move from `TORCH_LIBRARY` (set up by `pybind-to-torch-library`) to the stable form:

```cpp
// Before:
TORCH_LIBRARY(mylib, m) {
    m.def("mymuladd(Tensor a, Tensor b, float c) -> Tensor");
}
TORCH_LIBRARY_IMPL(mylib, CUDA, m) {
    m.impl("mymuladd", &mymuladd_cuda);
}

// After:
STABLE_TORCH_LIBRARY(mylib, m) {
    m.def("mymuladd(Tensor a, Tensor b, float c) -> Tensor");
}
STABLE_TORCH_LIBRARY_IMPL(mylib, CUDA, m) {
    m.impl("mymuladd", TORCH_BOX(&mymuladd_cuda));
}
```

Rules:

- `TORCH_LIBRARY` → `STABLE_TORCH_LIBRARY` (schema definitions).
- `TORCH_LIBRARY_FRAGMENT` → `STABLE_TORCH_LIBRARY_FRAGMENT`.
- `TORCH_LIBRARY_IMPL` → `STABLE_TORCH_LIBRARY_IMPL`.
- Wrap each kernel function pointer in `TORCH_BOX(&fn)` inside `m.impl(...)`.
- Do **not** wrap the op name in `TORCH_SELECTIVE_NAME`.
- Do **not** wrap the function pointer in `TORCH_FN`.
- Do **not** manually write boxed kernels — `TORCH_BOX` generates the boxed wrapper that adapts `(stack, num_args, num_outputs)` to your typed function signature using `to<T>` / `from<T>` over `StableIValue`.

**Keep the library namespace the same.** `STABLE_TORCH_LIBRARY(<lib_namespace>, m)` uses exactly the namespace the legacy `TORCH_LIBRARY(<lib_namespace>, m)` used — do NOT add a `_stable` suffix. Both `.so`'s register into the same `torch.ops.<lib_namespace>` namespace; the dispatcher accepts this because each file (and therefore each op) is compiled into only one `.so` at a time. Python callers continue to use `torch.ops.<lib_namespace>.<op>(...)` unchanged throughout the migration.

### 4. Wire up the stable build flags

**Incremental mode.** In `setup.py`:
- Remove the file's path from the legacy `ext_modules` entry's `sources=`.
- Add the same path string to the stable `ext_modules` entry's `sources=`.

The file does not move on disk. Both entries reference the same `csrc/` directory; this edit just changes which target compiles it. Build flags are already set on the stable target by `scaffold-stable-target` (`TORCH_TARGET_VERSION`, plus `Py_LIMITED_API` if enabled there). Do not touch the legacy target's flags.

**One-shot mode.** Once on the first file (or in a single setup.py edit covering the whole migration), add `TORCH_TARGET_VERSION` to the existing `ext_modules` entry's `extra_compile_args`:

```python
extra_compile_args={
    "cxx": [
        "-DTORCH_TARGET_VERSION=0x020b000000000000",
        # Optional — uncomment to also collapse the per-Python-version build matrix.
        # "-DPy_LIMITED_API=0x03090000",
    ],
    "nvcc": [
        "-DTORCH_TARGET_VERSION=0x020b000000000000",
        "-DUSE_CUDA",
    ],
},
# py_limited_api=True,   # Pair with -DPy_LIMITED_API if enabling.
```

Pick the hex from the plan's `target_torch_version` (`0xMMmm_0000_0000_0000` — e.g., `0x020b000000000000` for 2.11). Offer the `Py_LIMITED_API` opt-in here the same way `scaffold-stable-target` does in the incremental case — it's not required for the LibTorch ABI migration but is cheap to enable now.

`TORCH_TARGET_VERSION` serves two purposes:

1. **Bans unstable headers.** Any `#include <ATen/...>`, `<c10/...>`, `<torch/extension.h>`, etc. in a translation unit compiled with this flag fails with:
   > "This file should not be included when either `TORCH_STABLE_ONLY` or `TORCH_TARGET_VERSION` is defined."
   This is your compile-time guarantee that the binary is ABI-stable.
2. **Selects the minimum runtime PyTorch version.** Shims in `shim.h` are guarded by `#if TORCH_FEATURE_VERSION >= TORCH_VERSION_X_Y_Z`. APIs added after the target version are unavailable. The compiled binary will load against any PyTorch ≥ the target version.

Constraint: `2.9 ≤ TORCH_TARGET_VERSION ≤ <libtorch version at build time>`. Choose the lowest version the project is willing to support; lower = wider compatibility, higher = more APIs.

### 5. Compile-verify against stable headers

After steps 1–4, compile the migrated file(s) against libtorch stable headers only — the same check `stable-abi-transform` performs in verify mode. This is the **only** build step during migration; do not run a full extension or wheel build here.

```bash
.cursor/skills/migrate-to-stable-apis/scripts/verify_closure.sh \
  --project-root <project_root> \
  --csrc-root <csrc_root> \
  [--include-path <cutlass_include>] \
  <root-file>
```

If the script prints `SKIP:`, the tool binary is missing — build it (see above) or review manually. If verify fails, fix with ABI-only changes and re-run verify before advancing.

Most failures fall into two buckets:

- **"Header not allowed" errors** — a legacy include slipped through the rewrite. Find and replace it. If the file genuinely needs an API with no stable equivalent, see [references/common-issues.md](references/common-issues.md) for workarounds, or stop and flag a blocker.
- **Substitution misses** — an unstable API call or `TORCH_LIBRARY_IMPL` macro wasn't replaced. Apply the mapping.

Common pitfalls are documented in [references/common-issues.md](references/common-issues.md): missing `-DUSE_CUDA`, undeclared `aoti_torch_get_current_cuda_stream`, layout check rewrites, and the `empty_strided` workaround.

### 6. Advance or retry

- If step 5 succeeds → advance (below) or finish.
- If errors remain and iteration **< 5**: increment iteration, **skip step A**, repeat from step 1 using new verify output.
- If iteration **≥ 5** or the **same error persists twice** in a row → stop and report: root file(s), last compile error, what was tried per iteration, and concrete next steps.

When finishing a chunk or file, include a short **work split** line, e.g.:

> **Work split:** transform N edits; manual: [bindings, CMake, `TORCH_BOX`, flags, reverted transform mistakes]; verify: iteration K.

**Incremental mode.** Pick the next chunk of files from the legacy `ext_modules` entry's `sources=` in `setup.py` and repeat from step A (iteration 1). Stop when the legacy entry's `sources=` is empty, then hand off to [scaffold-stable-target's Completion section](../scaffold-stable-target/SKILL.md#completion-run-by-migrate-to-stable-apis-after-the-last-file-migrates) for final cleanup (removing the legacy entry, optionally renaming the stable extension back to `_C`).

**One-shot mode.** When all in-scope files are rewritten and compile-verify passes — the migration is done. No further cleanup; the single existing `ext_modules` entry is now the stable wheel.

## Critical rules

These are mistakes that AI-assisted migrations commonly make — follow strictly:

1. **Keep the `torch.ops` namespace identical to the legacy one.** `STABLE_TORCH_LIBRARY(<lib_namespace>, m)` uses the same `<lib_namespace>` the legacy `TORCH_LIBRARY(<lib_namespace>, m)` used — never suffix it with `_stable`. Python callers (`torch.ops.<lib_namespace>.<op>`) and Python-side registrations (`@torch.library.register_fake("<lib_namespace>::<op>")`) reference this name and must keep working unchanged.
2. **Do NOT use `torch::stable::new_empty_strided`** — it does not exist. To create a strided tensor, create a contiguous tensor with transposed dimensions and call `torch::stable::transpose()`. See [common-issues.md § Strided Tensors](references/common-issues.md).
3. **Do NOT define a dummy `_C` module** accessible from Python. Operators reach Python through `torch.ops.<libname>.<op>`.
4. **Do NOT forward-declare `aoti_torch_get_current_cuda_stream`** — include it from `torch/csrc/inductor/aoti_torch/c/shim.h`.
5. **Do NOT hand-write boxed kernels** — use `TORCH_BOX(&fn)` in `m.impl()`.
6. **Do NOT change switch statements into if/else** as part of the migration. The stable ABI works fine with switch statements; rewriting just adds review noise.
7. **When replacing `TORCH_CHECK` with `STD_TORCH_CHECK`, change only the macro name** — leave the condition and message arguments untouched.
8. **For `DeviceGuard`**, pass `t.get_device_index()` (an integer), **not** `t.device()`. Do not cast to `char` or narrow type. DeviceGuard is RAII — don't move its declaration into an inner scope.
9. **For CUDA streams**, derive the device index from a tensor (`t.get_device_index()`), **not** from `torch::stable::accelerator::getCurrentDeviceIndex()`. Multi-GPU scenarios silently produce the wrong stream otherwise.
10. **Scalar type enums use the headeronly form** — `torch::headeronly::ScalarType::Float` (not `torch::kFloat32`), `::Half` (not `torch::kFloat16`), `::BFloat16`, `::Float8_e4m3fn`, etc.

## Verification

During migration, run `verify_closure.sh` after each chunk (step 5). That syntax-checks each root translation unit against libtorch stable headers via `stable-abi-transform --mode=verify` (compile-based; this tool build has no `--verify-method` flag). Headers are checked through normal `#include` expansion — pass every root `.cu`/`.cpp` in the chunk, not individual headers.

After the full migration is complete, the orchestrator (or the user) runs the project's full extension build and test suite separately — that is outside this skill's per-chunk loop.

To prove ABI stability empirically after a full wheel build:

```bash
# Build against torch X.Y
pip install torch==X.Y
<project build command>

# Then install a different torch minor and re-test without rebuilding the extension
pip install torch==X.Z
<project test command>
```

If the second test run passes, the migration is verified.

## Real-world references

- **Official tutorial:** [Custom C++ and CUDA Operators](https://docs.pytorch.org/tutorials/advanced/cpp_custom_ops.html) — walks through the same migration end-to-end on a toy `mymuladd` op, with side-by-side ABI-stable vs non-stable tabs.
- **API-rewrite reference:** [`pytorch/extension-cpp`](https://github.com/pytorch/extension-cpp) — contains `extension_cpp/` (legacy) and `extension_cpp_stable/` (stable) implementations of the same op. Useful as a side-by-side diff for the API changes themselves. Note its parallel-directory layout is for didactic clarity; this skill's migration model keeps both targets in one `csrc/`.
- **Shared-namespace pattern:** [sglang's sgl-kernel](https://github.com/sgl-project/sglang/tree/main/sgl-kernel) — Python callers use `torch.ops.sgl_kernel.<op>` regardless of which `.so` implements the op. The `.so` filename is implementation detail.
- **Real-world migration:** FlashAttention 3's [`flash_api.cpp`](https://github.com/Dao-AILab/flash-attention/blob/main/hopper/flash_api.cpp) (legacy) vs [`flash_api_stable.cpp`](https://github.com/Dao-AILab/flash-attention/blob/main/hopper/flash_api_stable.cpp) (stable). The diff is a concrete production-scale example of the API rewrite.
- **Other adoptions:** xformers, torchaudio, torchao, vLLM (in progress), torchvision (in progress).

## Handoff

This is typically the last step in the migration. After the last file is migrated:

- The plan's `dispatch_order` is fully `completed`.
- **Incremental mode:** the legacy `ext_modules` entry's `sources=` is empty. Return to [scaffold-stable-target § Completion](../scaffold-stable-target/SKILL.md#completion-run-by-migrate-to-stable-apis-after-the-last-file-migrates) to remove the legacy entry from `setup.py` and (optionally) rename the stable extension back to `_C`.
- **One-shot mode:** the single existing `ext_modules` entry now compiles under stable flags. No further cleanup needed.
- The orchestrator's final summary should note: target PyTorch version pinned, single-wheel goal achieved.
