# Skeletons in the State Bucket — lab

Runnable experiments behind the blog post *Skeletons in the State Bucket: Identity
Is Permanent*. Each one checks a claim about how Terragrunt deletes
infrastructure when a unit's configuration disappears from Git.

Nothing here touches a cloud or needs credentials. Units are `terraform_data`
resources whose create/destroy provisioners append to an event log, so you can
read the order things were created and destroyed. State is kept outside the
checkout, keyed by unit id, so it behaves like a remote backend.

## Two kinds of experiments

| | Core — `experiments/` | Backend — `backend-experiments/` |
|---|---|---|
| Needs | the shell tools below | the same, **plus a local S3-compatible server** that you start |
| Network | none | none beyond `localhost` |
| Runs | `make` | `make backend` (never part of plain `make`) |
| If a prerequisite is missing | fails | **SKIPPED**, with the reason |

The core experiments are the promise of this lab: a few shell commands, no
services, no images, no accounts. The backend experiments answer the questions
that only a real remote backend can, and are strictly opt-in.

## Run

Requirements: `terragrunt` and `terraform` (versions in `.tool-versions`),
`git`, `jq`, `bash`, GNU `timeout`. To run against OpenTofu instead of
Terraform: `LAB_TF=tofu make`.

```sh
make            # all core experiments
make e04        # one experiment
make backend    # the backend experiments (see below)
make clean      # remove .work/
```

Each experiment builds a fresh sandbox Git repository under `.work/<experiment>/`
and commits into that sandbox as part of its fixture. Logs of every Terragrunt
call are in `.work/<experiment>/logs/`.

### How long it takes

A full `make` takes about **1–2 minutes**. Every Terragrunt call prints its
duration (`ran: ... in 6s`), so you can see progress and spot a slow step.

| Experiment | Typical | Why |
|---|---|---|
| e01, e02, e05, e06 | 3–6 s each | a handful of Terragrunt runs on tiny units |
| e07 | ~5 s | plain Terraform, about twenty quick runs |
| e04 | ~10 s | many Git scenarios, each with its own Terragrunt run |
| e03 | **~40 s** | **deliberately slow:** it reproduces a hang, and has to wait to call it one. Case A's duration sets the budget: case B is declared hung after 5× that, at least 20 s. Override with `E03_TIMEOUT=<seconds>`. |

**If it is much slower than this, it is probably not broken.** Two things the lab
already defends against, in case you run Terragrunt elsewhere:

- **Terraform's update check.** Every `terraform` invocation contacts HashiCorp's
  checkpoint service (~3 s each, dozens of invocations per experiment). The lab
  sets `CHECKPOINT_DISABLE=1`.
- **Terragrunt's OpenTofu probe.** On startup Terragrunt runs `tofu -version`
  before falling back to terraform, even with `TG_TF_PATH` set. If `tofu` on your
  PATH is a version-manager shim with no OpenTofu installed (tenv, asdf, mise),
  that probe can cost several seconds per call. In exactly that case the lab puts
  a fail-fast `tofu` stand-in first on the PATH. A working OpenTofu, or no `tofu`
  at all, is left alone. Deciding costs one `tofu -version` per lab run (cached
  in `.work/`), and each experiment's header says what it found
  (`tofu: absent | working | broken`).

Together these took a full run from ~12 minutes to ~70 seconds on the machine
the lab was written on. What remains machine-dependent: the very first run after
installing a binary can be slow while endpoint security scans it.

Output lines:

- `CLAIM PASS | SURPRISE` — documented behaviour. A surprise fails the run.
- `OBSERVE YES | NO` — undocumented behaviour, recorded either way.
- `NOTE` — context for interpreting the result.

## Backend experiments

These need a local S3-compatible endpoint and an existing bucket in it:

```sh
LAB_S3_ENDPOINT=http://localhost:1031 LAB_S3_BUCKET=lab-state make backend
```

Safety: the lab only accepts `http://localhost:<port>` or `http://127.0.0.1:<port>`,
forces dummy credentials (`lab`/`lab`, or `LAB_S3_ACCESS_KEY`/`LAB_S3_SECRET_KEY`)
and ignores any AWS profile, so lab state cannot land in a real cloud account by
accident. Without an endpoint, each backend experiment prints `SKIPPED` and why.

Any S3-compatible server works. One that needs no container is
[moto](https://github.com/getmoto/moto)'s server mode (Python), in three steps.

1. Install and launch the server (in the background; loopback only, in-memory):

   ```sh
   python3 -m venv .work/moto && .work/moto/bin/pip install 'moto[server]'
   .work/moto/bin/moto_server -H 127.0.0.1 -p 1031 &
   ```

2. Create the bucket. The server takes a few seconds to start, so retry until it
   answers (if this never ends, check the server's output from step 1):

   ```sh
   until curl -sf -o /dev/null -X PUT http://localhost:1031/lab-state; do sleep 1; done
   ```

3. Run the backend experiments:

   ```sh
   LAB_S3_ENDPOINT=http://localhost:1031 LAB_S3_BUCKET=lab-state make backend
   ```

The bucket lives only as long as the server: after restarting moto, repeat step 2.

We use port 1031 (Halloween, 10/31) because AirPlay Receiver may listen on
5000 — moto's default — and on 7000 on macOS. But seriously: Any free port works.
In `LAB_S3_ENDPOINT`, use `localhost`, not `127.0.0.1` (moto's advice for S3
clients); binding the server to `127.0.0.1` is fine.
A container-based server works just as well if you already run containers.

## Experiments

| # | Question |
|---|---|
| [e01](experiments/e01-removed-unit-plan-apply/run.sh) | A removed unit: what do `plan` and `apply` do, with and without `--filter-allow-destroy`? |
| [e02](experiments/e02-removed-chain-order/run.sh) | A whole dependency chain removed in one commit: in which order is it destroyed? |
| [e03](experiments/e03-mixed-directions-hang/run.sh) | Removed and surviving units in one run; reproduces terragrunt#6860 (hang) |
| [e04](experiments/e04-git-range-semantics/run.sh) | Which Git range sees a deletion: missed events (spectres), squash vs merge, tree-diff semantics and resurrection (zombies) |
| [e05](experiments/e05-backend-style/run.sh) | `remote_state` block vs `generate "backend"` for removed units |
| [e06](experiments/e06-spectre-hunt/run.sh) | Prototype sweep for state that no config and no tombstone accounts for ([`lib/spectre-hunt.sh`](lib/spectre-hunt.sh)) |
| [e07](experiments/e07-removed-block/run.sh) | Terraform's `removed` block (plain Terraform, >= 1.7): retiring vs forgetting, a laggard environment that loses the retain intent, resurrection from a stale config, and a tombstone beside a live block |

| # | Backend question |
|---|---|
| [b01](backend-experiments/b01-real-s3-backend/run.sh) | e05 against a real S3 backend: does `generate "backend"` trigger the "no remote_state configuration" warning where `remote_state` does not, and does either change how removed units read dependency outputs? |

Observed results per tool version: [results/RESULTS.md](results/RESULTS.md).

## Licence

[MIT](LICENSE) — copy, adapt and reuse freely, including the helpers in
`lib/lab.sh`; just keep the copyright and licence notice.
