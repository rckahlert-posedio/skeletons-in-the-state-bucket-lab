# Results

Observed with **terragrunt v1.1.3**, **terraform v1.14.8**, macOS (arm64),
2026-10-21. Re-run with `make` to check another version.

## Side finding — why Terragrunt felt slow

Not part of the deletion story, but it cost a 12-minute run before it was found:
Terragrunt probes `tofu -version` at startup even when `TG_TF_PATH` points at
terraform, and a version-manager `tofu` shim without OpenTofu installed makes that
probe take ~4–5 s. Terraform's checkpoint update check adds ~3 s per invocation.
See README, "How long it takes".

## e01 — a removed unit, with and without `--filter-allow-destroy`

- `find --filter '[A...B]'` lists the removed unit.
- **`plan` without the flag does not plan the destroy.** It only warns that the
  unit "will be excluded during applies unless --filter-allow-destroy is used".
  Contrary to a common reading of the docs, a reviewer needs the flag at *plan*
  time too, or the review shows nothing.
- `plan` with the flag shows `1 to destroy`. `apply` without the flag leaves the
  unit and its state alone; `apply` with the flag destroys it and empties its state.

## e02 — a removed dependency chain

- Removed units are destroyed in **reverse dependency order** (dependents first),
  and dependency outputs are read for real from the old worktree, no mocks.

## e03 — removed and surviving units in one run (terragrunt#6860)

- With healthy removed units, a mixed run (`...[A...B]... | ./**`) finishes.
- **With one removed unit that fails to evaluate, the run hangs**: the surviving
  units never start and the process never exits (killed after 5× the healthy
  case's duration — 30 s on the reference machine). Reproduces
  #6860 on v1.1.3 (the issue was filed against v1.1.4; fix PR #6861 open).

## e04 — which Git range sees a deletion

- **Spectres:** a deletion is visible only to ranges that span the deletion commit.
  If that run doesn't destroy (failed, skipped, flag forgotten), the next run's
  range (`[C1...C2]`) no longer sees it and the state keeps its resources.
- Squash merge and merge commit both keep the deletion inside the main-branch
  range `[before...after]`. A per-commit range on the branch after the deletion
  does not.
- **`[A...B]` is a plain tree diff, not Git's merge-base ("three-dot") semantics.**
  With main having deleted a unit and a stale branch still containing it,
  `[main...branch]` selects the unit as changed.
- **Zombies:** after main destroyed the unit, applying the stale branch with
  `[main...branch]` recreated it. (Any apply of that branch would; the point is the
  range selects it rather than protecting it.) MR pipelines that diff against the
  merge-base would not select it.

## e05 — `remote_state` vs `generate "backend"`

- Both styles behave identically: real outputs, correct destroy order.
- Both trigger the "do not have a remote_state configuration" warning because the
  lab uses the `local` backend. **Open:** whether `generate "backend"` with a real
  remote backend (gcs/s3) triggers it needs a real-remote tier (e.g. S3 on MinIO).

## e06 — spectre hunt

- Classifying state files as alive / tombstone / buried / SPECTRE against
  `terragrunt find` works as a level-triggered safety net.
- A spectre can be laid to rest with a range that still contains its deletion,
  narrowed to the unit: `--filter '[A...HEAD] | ./unit' --filter-allow-destroy`.
  The intersection is Terragrunt's native way to target one removed unit.

## e07 — the `removed` block (plain Terraform)

One configuration, several environments (separate state files), each resource's
"flesh" a file that only provisioners create or remove.

- **S1, retire (`destroy = true`):** plans `will be destroyed`, drops the address
  from state, and removes the flesh — **if the destroy provisioner is in the
  `removed` block**. A resource block's destroy-time provisioner is deleted with
  the block and never runs (documented); with a bare tombstone the flesh is left
  behind (observed).
- **S2, forget (`destroy = false`):** plans "will no longer be managed by
  Terraform, but will not be destroyed", drops the address, flesh untouched.
- **S3, the laggard:** prod applies a retain tombstone; the tombstone is then
  cleaned out of the config before staging applies it. Staging plans `will be
  destroyed` and drops the address: the retain intent is lost for every
  environment that hadn't applied it yet. **The destroy-time side effect does not
  run**, because no config is left to carry it (observed). A real provider-managed
  resource would still be destroyed through its provider; what is lost is
  anything that relied on a destroy provisioner.
- **S4, resurrection:** a config that declares the resource again plans `will be
  created` in an environment that retired it, and recreates it. In an environment
  that only *forgot* it (S2), the same config also plans a create — beside the
  resource that still exists (observed).
- **S5, tombstone beside a live block:** `terraform validate` **accepts** it
  (observed); `terraform plan` rejects it with "Error: Removed resource still
  exists".

## b01 — real S3 backend (moto server mode, localhost)

- With a real remote backend, **only the hand-written `generate "backend"` style
  triggers Terragrunt's "do not have a remote_state configuration" warning**; the
  `remote_state` style does not. (e05's local backend triggered it for both.)
- Behaviour is otherwise identical: removed units read their removed
  dependencies' real outputs (mocks were disallowed for plan, and the plan
  succeeded), and are destroyed dependents-first.
- So for setups that configure a remote backend via `generate "backend"`, the
  warning is noise as long as state is addressed independently of the checkout
  path — which is what the warning is really worried about. State verified in the
  bucket, none on local disk.
- Tested against S3 only; a GCS backend configured via `generate` is expected to
  behave the same but was not tested.
