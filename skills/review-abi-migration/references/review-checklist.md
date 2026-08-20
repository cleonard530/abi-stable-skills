# Stable-ABI Migration Review Checklist

Mechanical checks for a migration PR. Run them before the line-by-line read.

Sections: [includes](#1-banned-includes-in-stable-translation-units),
[APIs](#2-banned--missing-apis), [registration](#3-registration-macros),
[Python](#4-python-surface), [build](#5-build-config),
[headers](#6-shared-header-blast-radius), [behavior](#7-behavior-equivalence-spot-checks),
[minimality](#8-diff-minimality-greps), [pins](#9-dependency-pins-and-external-projects),
[evidence](#10-the-authors-verification-evidence-read--do-not-run).

Throughout: `$STABLE` = the set of files compiled with `TORCH_TARGET_VERSION`
(the stable `ext_modules` entry's `sources=` in incremental mode; all in-scope
files in one-shot mode). Rules apply **only** to those files — un-migrated files
in the legacy target are allowed to keep using `at::`/`c10::`.

## 1. Banned includes in stable translation units

Only these header roots are allowed:
`torch/csrc/stable/`, `torch/headeronly/`, and the C shims under
`torch/csrc/inductor/aoti_torch/c/`.

```bash
grep -nE '#include *[<"](ATen/|c10/|torch/extension\.h|torch/library\.h|torch/autograd\.h|torch/torch\.h|pybind11/|pt_stable_utils\.h)' $STABLE
```

Any hit is a blocker — it will fail to compile under `TORCH_TARGET_VERSION`, and
if it *did* compile, the flag isn't actually set on that target.

Also follow project-header includes transitively. A direct include can look clean
while pulling in `torch/all.h` through a shared helper. Do not assume a clean build
proves every inline/template path in a header is stable: unused code may not be
instantiated yet.

## 2. Banned / missing APIs

```bash
# Unstable types and namespaces that should be gone
grep -nE '\b(at|c10)::' $STABLE
grep -nE '\btorch::Tensor\b|\bat::Tensor\b' $STABLE
grep -n 'using namespace at;' $STABLE          # plain `Tensor` may still be at::Tensor

# Doesn't exist — must be create-transposed + torch::stable::transpose
grep -n 'new_empty_strided\|empty_strided' $STABLE

# Must be the STD_ forms
grep -nE '\bTORCH_CHECK\b' $STABLE                     # → STD_TORCH_CHECK
grep -n 'C10_CUDA_KERNEL_LAUNCH_CHECK' $STABLE         # → STD_CUDA_KERNEL_LAUNCH_CHECK

# Legacy CUDA plumbing
grep -n 'CUDAGuard\|getCurrentCUDAStream\|getCurrentDeviceProperties' $STABLE

# Shims must be included, never forward-declared
grep -n 'aoti_torch_get_current_cuda_stream' $STABLE   # check for a bare declaration

# Lifetime/pinning-sensitive rewrites require manual comparison with base
grep -n 'from_blob\|is_pinned\|cudaHostGetDevicePointer\|torch_call_dispatcher' $STABLE
```

Classify `at::`/`c10::` hits:

- **Blocker:** real unstable use such as `at::Tensor`, `at::vec`, `c10::cuda`,
  `c10::IValue`, or `at::TensorOptions`.
- **Nit:** header-only BC aliases such as `c10::Half`, `c10::BFloat16`,
  `c10::complex`, or `c10::ArrayRef`; prefer the `torch::headeronly::` spelling.

A renamed file gets no exemption: classify unchanged lines too. Use the posted
audit to corroborate aliases (`unstable=0` despite a `c10::` spelling).

Scalar-type spot check — the headeronly enum, not the `torch::k*` aliases:

```bash
grep -nE 'torch::kFloat|torch::kHalf|torch::kBFloat16|at::k[A-Z]' $STABLE
```

## 3. Registration macros

```bash
grep -nE '\bTORCH_LIBRARY(_IMPL|_FRAGMENT)?\(' $STABLE   # should all be STABLE_*
grep -n 'TORCH_SELECTIVE_NAME\|TORCH_FN' $STABLE          # both banned in stable blocks
grep -n 'm\.impl(' $STABLE                                 # every one wraps fn in TORCH_BOX
grep -nE 'StableIValue|\bto<|\bfrom<' $STABLE              # inspect manual stack code
```

Manual `StableIValue` conversion inside a registration wrapper should be replaced by
`TORCH_BOX`. The same conversion primitives are legitimate around
`torch_call_dispatcher` when a direct stable C++ API does not exist; review those for
stack arity, schema, output slot, and error-code handling instead of flagging them
automatically.

Namespace must be unchanged from the legacy `TORCH_LIBRARY`:

```bash
git grep -h -o 'TORCH_LIBRARY[A-Z_]*([a-zA-Z0-9_]*' <base> -- '*.cpp' '*.cu'
grep -rho 'STABLE_TORCH_LIBRARY[A-Z_]*([a-zA-Z0-9_]*' $STABLE
```

The namespace names must match exactly — no `_stable` suffix and no migration from
one existing namespace to another (for example `_moe_C::op` → `_C::op`) just because
the physical extension filename changed.

Op coverage must match repo-wide, not merely within one registration file:

```bash
git show <base>:<file> | grep -o 'm\.impl("[^"]*"' | sort > /tmp/before.txt
grep -o 'm\.impl("[^"]*"' <file>          | sort > /tmp/after.txt
diff /tmp/before.txt /tmp/after.txt
```

Group the inventory by namespace and dispatch key. Look for duplicate schemas/impls
copied from an earlier migration chunk, declarations with no implementation, and ops
that disappeared only on CPU/ROCm.

## 4. Python surface

```bash
# Dummy _C module defined from C++ — banned
grep -rn 'PYBIND11_MODULE\|PyModule_Create\|PyInit_' $STABLE

# Side-effect _C imports break after pybind removal
grep -rn 'import .*\._C\b' <package>/

# Direct _C usage on public paths (needs a shim or user sign-off)
grep -rn 'from .*\._C import\|\._C\.\w' <package>/ | grep -v '# noqa\|F401'

# Registrations must still run at import time
grep -rn 'register_fake\|register_autograd\|load_library' <package>/
```

Check that `load_library` runs **before** the module doing `register_fake` /
`register_autograd` is imported.

Create an explicit mapping of physical extension → registered namespace(s) → Python
loader. A new stable `.so` must be packaged and loaded even when its operators retain
an older namespace whose legacy `.so` was never imported directly.

## 5. Build config

```bash
grep -rn 'TORCH_TARGET_VERSION\|Py_LIMITED_API\|py_limited_api\|USE_CUDA\|USE_ROCM' \
  setup.py CMakeLists.txt cmake/ 2>/dev/null
```

- `TORCH_TARGET_VERSION` present on every compiler language used by the stable target
  (`cxx`, `nvcc`, HIP, or CPU-only as applicable),
  and value in range `2.9 ≤ v ≤ build-time libtorch`. Hex form
  `0xMMmm000000000000` (e.g. `0x020b000000000000` = 2.11).
- Incremental mode: `TORCH_TARGET_VERSION` / `Py_LIMITED_API` must be on the
  **stable target only** — never on the legacy entry.
- `-DUSE_CUDA` on both `cxx` and `nvcc` if any AOTI CUDA shim is used.
- `Py_LIMITED_API` (if enabled) paired with `py_limited_api=True` on the
  Extension **and** `options={"bdist_wheel": {"py_limited_api": "cpXY"}}`.
- Check the target version separately for CUDA, ROCm, CPU, and auxiliary extensions.
  A stable API available to a 2.11 CUDA target may not exist for a 2.10 ROCm target.

Incremental mode `sources=` bookkeeping — every migrated path left the legacy
list and joined the stable list, exactly once:

```bash
git diff <base>...<head> -- setup.py    # each removed path should appear as an addition
```

The build target, not the source directory name, is the ABI boundary. Do not
require migrated files to move into a `stable/` directory: their paths may stay in
place while source-list ownership moves from the legacy target to the stable
target. Conversely, if the project's recorded plan requires a physical stable
directory, verify the rename plus all include, generator, packaging, and build-list
path updates. A directory move by itself is not evidence of ABI compliance.

For CMake projects, make the same check for every conditional branch and ISA/backend
variant. Pay special attention to:

- `set(VAR ...)` replacing a prior `list(APPEND VAR ...)` and discarding sources.
- A renamed source variable that is never appended to the target.
- `set_gencode_flags_for_srcs` running before the final source list exists or running
  twice with conflicting architectures.
- A migrated registration/kernel source compiled into both legacy and stable targets,
  or into neither. Shared helper-only sources require explicit dual-target intent.
- Generated sources changed without updating the generator/template.
- Raw HIP calls linked against a different `libamdhip64` than PyTorch's bundled copy.

## 6. Shared-header blast radius

Changed headers are the highest-yield place to look. Find every un-migrated file
whose behavior this PR silently changes:

```bash
# Headers touched by the PR
git diff <base>...<head> --name-only -- '*.h' '*.hpp' '*.cuh'

# For each one: all includers, then subtract the stable sources= list
grep -rn '#include.*<basename>' csrc/ --include='*.cpp' --include='*.cu' --include='*.hpp'
```

Any includer **not** in the stable target is collateral — name it in the review.

```bash
# Vector/math backend swapped out from under shared code?
grep -rn 'at::vec\|Vectorized<\|Sleef' $CHANGED_HEADERS

# Scalar fallbacks in a hand-rolled replacement (numerics + throughput)
grep -nE 'map_scalar|for \(int i = 0; i < size|std::(exp|erf|tanh|sqrt|log)\b' $NEW_BACKEND_HEADER

# Methods/overloads the old backend had that the new one dropped
git show <base>:<old-header> | grep -oE '\b(sin|cos|tan|exp|log|erf|tanh|sqrt|abs)\w*' | sort -u > /tmp/old_ops
grep -oE '\b(sin|cos|tan|exp|log|erf|tanh|sqrt|abs)\w*' <new-header>          | sort -u > /tmp/new_ops
diff /tmp/old_ops /tmp/new_ops

# Macros the header used to define — do all consumers still resolve them?
git show <base>:<old-header> | grep -oE '^#define [A-Z_]+' | sort -u
```

If the PR's benchmarks cover a different architecture than the one whose backend
changed, say so explicitly — that's unmeasured, not measured-and-fine.

Moving a header into a stable directory is not itself proof that all of its contents
are stable. Grep the whole header and its project-header dependencies, including
dormant templates and inline functions that current consumers may not instantiate.

## 7. Behavior-equivalence spot checks

These aren't greppable to a verdict, but the greps narrow where to look.

```bash
# Check-count parity per file
for f in $STABLE; do
  echo "$f  before=$(git show <base>:$f 2>/dev/null | grep -c 'TORCH_CHECK')  after=$(grep -c 'STD_TORCH_CHECK' $f)"
done
```

Unequal counts → read that file's checks side by side.

```bash
# Stream device index must come from a tensor, not the ambient device
grep -n -A2 'aoti_torch_get_current_cuda_stream' $STABLE | grep -n 'getCurrentDeviceIndex'
```

Any hit is a multi-GPU correctness blocker.

```bash
# Every stable-created tensor's dtype is explicit — compare against the old options
grep -n 'new_empty\|new_zeros\|empty_like' $STABLE

# Ownership/lifetime-sensitive views
grep -n 'from_blob\|cudaHostAlloc\|cudaFreeHost\|is_pinned' $STABLE
```

For each `from_blob`, classify ownership:

- Borrowed view: no deleter; external storage must outlive the view.
- Newly allocated pinned buffer: deleter must free it exactly once.
- Base-tensor lifetime capture: only when the old API required the returned view to
  retain the base; unnecessary captures can cause unbounded memory retention.

For missing stable methods such as `is_pinned`, prefer a dispatcher call that
preserves semantics over inferring the answer from a lower-level API error.

## 8. Diff-minimality greps

```bash
# switch → if/else rewrites (banned)
git diff <base>...<head> | grep -nE '^-.*\bswitch *\(|^\+.*\bif *\(.*== *torch::headeronly::ScalarType'

# const / ref churn on signatures
git diff <base>...<head> | grep -nE '^[-+].*(const +[A-Za-z:]+ *&|\bconst\b)'

# pure-formatting hunks: lines whose only change is whitespace
git diff <base>...<head> -w --stat        # compare against the non -w stat
```

If `git diff -w --stat` is much smaller than `git diff --stat`, a chunk of the
diff is whitespace-only churn.

For stacked PRs, reuse the metadata-backed range established during review scoping.
If the configured base does not identify the claimed parent and no parent PR/head
can be resolved from stack metadata or the PR description, ask the author for the
parent PR or base SHA rather than inferring it from commit messages. For force-pushed
PRs, compare the old reviewed head to the new head. Use `--find-renames` when GitHub
renders moves as delete/add.

## 9. Dependency pins and external projects

If the local diff changes a tag, SHA, submodule, or hand-picked upstream source list:

```bash
git diff <old-upstream>...<new-upstream> --stat
git diff --find-renames <old-upstream>...<new-upstream>
```

- Review the upstream range, including unrelated commits pulled in by the pin.
- Compare upstream registrations/bindings with the local source list; a new referenced
  function can force an extra source, while a minimal-build option may avoid it.
- Require audit/test evidence for the final locally built artifact, on every relevant
  architecture. A pin-only PR is not mechanically safe merely because its local diff
  is one line.

## 10. The author's verification evidence (read — do not run)

Do not build, do not run `torch-abi-audit`, do not run tests. Read what the author
reported in the PR description / commit message / CI and check it for these:

- [ ] `torch-abi-audit` output included and clean for every produced stable `.so`
      (including ISA/backend variants and auxiliary extensions).
- [ ] Audit claim consistent with your grep results from §1–2. If your greps found
      `at::` in a stable TU but the PR says the audit was clean, one of the two is
      stale — flag the contradiction rather than picking a side.
- [ ] Tests reported as run, and they actually exercise the ops in *this* chunk
      (cross-check the op names from §3 against the named tests).
- [ ] In incremental mode, evidence shows those tests routed to the stable owner,
      not a legacy binary registering the same `torch.ops` namespace.
- [ ] Tests/benchmarks cover the changed backend or architecture; x86 evidence does
      not validate NEON, and CUDA evidence does not validate ROCm.
- [ ] Any "pre-existing failure" claim is matched on the base commit under the same
      configuration.
- [ ] Cross-version claim present: built against torch X.Y, re-tested against X.Z
      **without rebuilding**. This is the promise the migration exists to keep; its
      absence is worth asking about even when everything else looks right.
- [ ] Autograd moved to Python → a `backward()` / `torch.autograd.grad` test named.
- [ ] Meta moved to Python → a `torch.compile`, fake-tensor, or `device='meta'`
      test named.

Missing evidence is a request to the author, not automatically a code finding.
