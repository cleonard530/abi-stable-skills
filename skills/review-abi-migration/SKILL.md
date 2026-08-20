---
name: review-abi-migration
description: Review a PR, diff, or commit that migrates a PyTorch C++/CUDA extension to the LibTorch stable ABI. Use for `torch::stable` rewrites, `STABLE_TORCH_LIBRARY` conversions, `TORCH_TARGET_VERSION` or build-target changes, and dependency pins that claim ABI stability. Prioritize behavior equivalence, minimal diffs, and migration-rule compliance.
allowed-tools: Read, Bash, Grep, Glob
---

# Review a Stable-ABI Migration

Treat the migration as a mechanical translation, not a refactor. Every changed
line should be required by the ABI. Isolate and disclose any unavoidable behavior
fix or compatibility shim, with targeted evidence.

Consult only the sibling skill matching the PR step:
[pybind](../pybind-to-torch-library/SKILL.md),
[Meta](../migrate-meta-fns-to-python/SKILL.md),
[Autograd](../migrate-autograd-fns-to-python/SKILL.md),
[target scaffolding](../scaffold-stable-target/SKILL.md), or
[stable API rewrites](../migrate-to-stable-apis/SKILL.md). Read
[references/review-checklist.md](references/review-checklist.md) for mechanical
checks and edge cases.

## Review priorities

1. **No behavior change.** Preserve computation, device/stream, shapes, strides,
   dtypes, checks and messages, registrations, and the Python API.
2. **Minimal diff.** Flag unrelated cleanup, signature churn, new guards, renames,
   formatting, or refactors.
3. **Rule compliance.** Enforce the stable-API, registration, build, and packaging
   rules from the sibling skills.

Correctness wins over minimality: an honest mutation schema or necessary stable
shim is preferable to a smaller but incorrect diff.

## Scope the review

Read the PR description, commit list, diff, and the author's audit/test evidence.
Prefer a local checkout so whole files and base revisions are available.

```bash
git diff <base>...<head> --stat
git diff --find-renames <base>...<head>
gh pr view <N>
gh pr checks <N>
```

Establish the exact review range:

- Start with the hosting metadata rather than inferring the range from commit
  messages. Prefer `gh pr diff <N>`, or read the configured base and head with
  `gh pr view <N> --json baseRefName,baseRefOid,headRefName,headRefOid` and review
  `git diff <baseRefOid>...<headRefOid>`.
- For a stacked PR whose configured base is the parent branch, that range is the
  PR-local range. If the PR claims to be stacked but its configured base does not
  identify the parent, resolve the parent PR/head from stack metadata or the PR
  description and compute the range from the parent/head merge base. Verify the
  relationship in git before excluding commits. If the parent cannot be established,
  ask the author for the parent PR or base SHA; do not guess from commit messages.
- For rebases or force-pushes, compare the previously reviewed head with the new
  head and focus on conflict resolutions and new commits.
- When GitHub shows delete/add for a move, use rename detection or compare blobs.
- If generated files changed, inspect the generator or template too.
- For a dependency pin, review the upstream old-to-new commit range and any local
  hand-picked source list; the one-line pin change is not the real diff.

Record the migration mode and target matrix: physical extensions, registered
`torch.ops` namespaces, source lists, source layout, backend/ISA,
`TORCH_TARGET_VERSION`, and Python loaders. Treat build-target ownership and
physical directory layout as separate decisions: a parallel stable extension can
compile migrated files from their original directories. Each migrated
registration/kernel translation unit needs one intended owner per supported build
branch. Shared helper-only sources require an explicit reason to compile in
multiple targets.

Derive the source-layout policy from the migration plan or an explicit project
decision. Do not require a `stable/` directory, and do not treat one as proof of
ABI compliance. If the project chose a physical stable directory, verify the moves
and all affected paths; if it chose in-place migration, verify source-list ownership
instead. When the policy is missing, ask the author which layout is intended rather
than reporting a code finding. Any generic layout shown by a sibling skill is a
default implementation pattern, not a review requirement.

Treat a chunk much larger than roughly 1,000 diff lines as a process concern unless
one unavoidable file accounts for the size.

## Review workflow

### 1. Reconstruct the old behavior

Read each pre-migration file in full, then read the PR commits in order. Do not infer
old behavior only from removed diff lines. Look for pre-existing checks, defaults,
comments, device guards, stream selection, registration location, and header-level
overrides.

### 2. Map the blast radius

Changed shared headers are the highest-risk surface. Find all includers and identify
which remain in legacy targets. A header move or rewrite can silently change
un-migrated kernels.

Follow project-header includes transitively. A successful stable build only checks
compiled and instantiated paths; dormant inline functions or templates can still
contain unstable code.

Scrutinize hand-written replacements for ATen vector/math code for:

- scalar fallbacks replacing vectorized operations;
- missing methods, dtypes, or overloads;
- changed BF16 rounding or NaN behavior;
- performance or numerical evidence collected on the wrong architecture.

### 3. Check behavior equivalence

Compare old and new code hunk by hunk. Prioritize:

- identical `TORCH_CHECK` conditions and messages;
- stream device derived from an operated-on tensor, with guard scope and placement
  preserved;
- identical tensor shapes, strides, dtype, layout, and device after creation or
  transpose-based rewrites;
- correct `const_data_ptr` versus `mutable_data_ptr` based on actual kernel writes;
- preserved `from_blob` ownership, deleter, and pinning semantics;
- exact scalar-type and method-to-free-function mappings;
- honest mutation/alias schemas and unchanged defaults;
- complete, non-duplicated schemas and impls under the original namespace and
  dispatch keys;
- unchanged Python wrappers, import paths, fake/autograd behavior, and load order;
- preserved CUDA/ROCm portability and API availability at each target's actual
  PyTorch version.

Do not confuse the physical `.so` name with the operator namespace. A stable binary
may have a new filename while still registering the original `_C`, `_moe_C`, or
project namespace.

### 4. Enforce minimality

Classify each hunk as required, permissible, or gratuitous. Flag:

- `const`, reference, argument-order, or default-value churn not required by the
  dispatcher;
- switch-to-if rewrites, renames, formatting, comment loss, or one-use helpers;
- new guards, stricter checks, stream changes, performance fixes, or bug fixes that
  were not present before;
- dead legacy registration, declarations, sources, or Python imports left behind.

If an intentional behavior correction must remain, require it to be explicit in the
PR description and covered by a targeted test.

Do not demand or reject physical file moves based on reviewer preference. Flag a
layout change only when it contradicts the recorded migration plan, causes concrete
build/packaging/include problems, obscures target ownership, or adds unrelated
churn.

### 5. Run the mechanical checklist

Apply [references/review-checklist.md](references/review-checklist.md) to the stable
translation units and build configuration. It covers banned APIs/includes,
registration inventory, source ownership, CMake pitfalls, shared-header checks,
`from_blob`, dependency pins, and evidence requirements.

### 6. Assess the author's evidence

This is a reading review: do not build, audit, or test unless the user separately
asks for execution.

Check that the author provides:

- clean `torch-abi-audit` results for every produced stable artifact/variant;
- cross-version proof: build against one PyTorch version, test against another
  without rebuilding;
- tests that exercise the migrated ops through the stable owner, not a legacy
  binary sharing the namespace;
- coverage on the changed backend/architecture;
- base-commit evidence for failures claimed to be pre-existing.

Missing evidence is a request to the author, not automatically a code finding.
Contradictory evidence is a finding.

## Output

Report findings by severity, anchored to `file:line`:

- **Blocker:** observable behavior/API change, wrong device/stream/layout/dtype,
  broken registration/namespace, unstable audit symbol, or incorrect target
  ownership.
- **Should fix:** stable-ABI/build rule violation without a demonstrated runtime
  failure, or missing evidence for a risky path.
- **Nit:** gratuitous diff that should be reverted or split into a follow-up.

For each finding, name the concrete failing input, backend, architecture, or build
configuration. Close with a verdict on behavior equivalence, minimality, rule
compliance, and evidence. State that it was a reading review.

## Reviewer constraints

- Report findings; do not rewrite the PR unless explicitly asked.
- Do not demand cleanup of pre-existing issues unrelated to the migration.
- Verify API-availability claims against the target's actual PyTorch version.
- Confirm old behavior at the base revision before calling a difference a regression.
- Do not treat green CI as proof against a visible device, stride, lifetime, or
  registration bug.
