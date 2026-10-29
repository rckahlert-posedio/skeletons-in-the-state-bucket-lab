# shellcheck shell=bash
# The lab's vocabulary. Source it from an experiment's run.sh:
#
#   . "$(dirname "$0")/../../lib/lab.sh"
#   lab_init
#
# Every experiment builds a fresh sandbox Git repository under .work/<experiment>/
# and commits into THAT repository as part of its fixture. Nothing touches the
# lab repository itself, and nothing touches any cloud: units are
# terraform_data resources whose create/destroy provisioners append to an event
# log, and state lives in a directory outside the sandbox checkout (keyed by
# unit id, not checkout path) so it behaves like a remote backend.
#
# Vocabulary (details next to each definition below):
#
#   setup      lab_init, lab_variants, lab_require_tools, lab_require_terraform,
#              lab_require_local_s3, lab_skip
#   units      mkunit, unit_slow_plan, unit_broken, unit_no_plan_mocks,
#              rm_units, touch_unit, touch_file, tombstone
#   git        commit, on_new_branch, switch_to, squash_merge, merge_commit
#   terragrunt tg_find, tg_plan, tg_apply, tg_apply_all, spectre_hunt, forget_events
#   terraform  tf_workspace, tf_declare, tf_undeclare, tf_tombstone,
#              tf_init, tf_plan, tf_apply, tf_validate, show_plan
#   checks     created, destroyed, not_destroyed, event_count_is, events_in_order,
#              found_in, not_found_in, log_has, log_lacks, log_count_is,
#              state_is, rc_is, elapsed, finished, timed_out, hunted_as,
#              in_state, not_in_state, flesh_present, flesh_absent
#   results    claim, observe, note, section, show_events, lab_finish
#
#   claim   "<text>" <check...>   documented behaviour; a failing claim is a SURPRISE
#                                 and makes the experiment exit non-zero
#   observe "<text>" <check...>   undocumented behaviour; recorded as YES/NO

set -eu

LAB_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LAB_SURPRISES=0

# Speed, part 1: Terraform phones home for update checks on every invocation
# (~3 s each, and a single experiment makes dozens of invocations).
export CHECKPOINT_DISABLE=1

# ============================================================================ setup

lab_init() {
  LAB_NAME=$(basename "$(cd "$(dirname "$0")" && pwd)")${LAB_VARIANT:+/${LAB_VARIANT}}
  WORK="${LAB_ROOT}/.work/${LAB_NAME}"
  rm -rf "${WORK}"
  mkdir -p "${WORK}/repo" "${WORK}/state" "${WORK}/logs"
  lab_toolbox
  REPO="${WORK}/repo"
  EVENTS="${WORK}/events.log";         : > "${EVENTS}"
  RESULTS="${WORK}/results.txt";       : > "${RESULTS}"
  TOMBSTONES="${WORK}/tombstones.txt"; : > "${TOMBSTONES}"

  git -C "${REPO}" init -q -b main
  git -C "${REPO}" config user.email lab@example.invalid
  git -C "${REPO}" config user.name lab
  git -C "${REPO}" config commit.gpgsign false
  printf '.terragrunt-cache/\n.terraform/\n.terraform.lock.hcl\nbackend.tf\n' > "${REPO}/.gitignore"

  write_root_hcl "${BACKEND_STYLE:-remote_state}"

  {
    echo "experiment: ${LAB_NAME}"
    echo "terragrunt: $(terragrunt --version 2>/dev/null | awk '{print $NF}')"
    echo "${LAB_TF:-terraform}:  $("${LAB_TF:-terraform}" version 2>/dev/null | head -1 | awk '{print $2}')"
    case "${BACKEND_STYLE:-remote_state}" in
      s3_*) echo "backend:    ${BACKEND_STYLE} (${LAB_S3_ENDPOINT}/${LAB_S3_BUCKET})" ;;
      *)    echo "backend:    ${BACKEND_STYLE:-remote_state} (local, outside checkout)" ;;
    esac
    echo "tofu:       ${LAB_TOFU}$([ "${LAB_TOFU}" = broken ] && echo ' (fail-fast stand-in on PATH)')"
  } | tee -a "${RESULTS}"
}

# Speed, part 2: on startup Terragrunt probes for OpenTofu (`tofu -version`)
# before falling back to terraform, even when TG_TF_PATH is set. If `tofu` on the
# PATH is a version-manager shim with no OpenTofu installed (tenv, asdf, mise),
# that probe fails slowly — several seconds per invocation. Only in that case
# does a `tofu` stand-in that fails instantly go first on the PATH. A missing
# `tofu` (the probe fails fast anyway) and a working OpenTofu are left alone.
# The check costs one `tofu -version`, so its verdict is cached in .work/,
# keyed by which `tofu` it found (`make clean` forgets it).
LAB_TOOLS="terragrunt git jq timeout"
lab_toolbox() {
  for _tool in ${LAB_TOOLS} "${LAB_TF:-terraform}"; do
    command -v "${_tool}" >/dev/null || { echo "lab: required tool not found: ${_tool}" >&2; exit 2; }
  done
  export TG_TF_PATH="${LAB_TF:-terraform}"
  LAB_TOFU=$(tofu_status)   # decided once, before the PATH changes below
  [ "${LAB_TOFU}" = broken ] || return 0
  mkdir -p "${WORK}/bin"
  printf '#!/bin/sh\n# lab stand-in for a broken tofu shim: fail fast (see lib/lab.sh)\nexit 127\n' > "${WORK}/bin/tofu"
  chmod +x "${WORK}/bin/tofu"
  export PATH="${WORK}/bin:${PATH}"
}

# tofu_status  — prints absent | working | broken (cached per `tofu` path)
tofu_status() {
  _tofu=$(command -v tofu) || { echo absent; return; }
  _cache="${LAB_ROOT}/.work/tofu-status"
  if [ -f "${_cache}" ] && [ "$(head -1 "${_cache}")" = "${_tofu}" ]; then
    sed -n 2p "${_cache}"; return
  fi
  if timeout 30 "${_tofu}" -version >/dev/null 2>&1; then _status=working; else _status=broken; fi
  mkdir -p "${LAB_ROOT}/.work"
  printf '%s\n%s\n' "${_tofu}" "${_status}" > "${_cache}"
  echo "${_status}"
}

# lab_variants <VAR> <value>...  — run this experiment once per value, with <VAR>
# set to it, each in its own .work/<experiment>/<value>/. Call before lab_init.
lab_variants() {
  [ -z "${LAB_VARIANT:-}" ] || return 0
  _var=$1; shift
  _rc=0
  for _value in "$@"; do
    env LAB_VARIANT="${_value}" "${_var}=${_value}" "$0" || _rc=1
  done
  exit ${_rc}
}

# root.hcl in one of two styles. Both put state at ${WORK}/state/<unit-id>.tfstate.
#   remote_state : Terragrunt `remote_state` block with backend "local"
#   generate     : a `generate "backend"` block writing backend.tf by hand
write_root_hcl() {
  case "$1" in
    remote_state)
      cat > "${REPO}/root.hcl" <<EOF
locals { id = replace(path_relative_to_include(), "/", "_") }
remote_state {
  backend  = "local"
  generate = { path = "backend.tf", if_exists = "overwrite_terragrunt" }
  config   = { path = "${WORK}/state/\${local.id}.tfstate" }
}
EOF
      ;;
    generate)
      cat > "${REPO}/root.hcl" <<EOF
locals { id = replace(path_relative_to_include(), "/", "_") }
generate "backend" {
  path      = "backend.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOT
terraform {
  backend "local" { path = "${WORK}/state/\${local.id}.tfstate" }
}
EOT
}
EOF
      ;;
    s3_remote_state)
      cat > "${REPO}/root.hcl" <<EOF
locals { id = replace(path_relative_to_include(), "/", "_") }
remote_state {
  backend  = "s3"
  generate = { path = "backend.tf", if_exists = "overwrite_terragrunt" }
  config = {
$(_s3_backend_settings)
    # Terragrunt-only: don't try to create, harden or update the bucket
    skip_bucket_versioning             = true
    skip_bucket_ssencryption           = true
    skip_bucket_root_access            = true
    skip_bucket_enforced_tls           = true
    skip_bucket_public_access_blocking = true
    disable_bucket_update              = true
  }
}
EOF
      ;;
    s3_generate)
      cat > "${REPO}/root.hcl" <<EOF
locals { id = replace(path_relative_to_include(), "/", "_") }
generate "backend" {
  path      = "backend.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOT
terraform {
  backend "s3" {
$(_s3_backend_settings)
  }
}
EOT
}
EOF
      ;;
    *) echo "unknown backend style: $1" >&2; exit 2 ;;
  esac
}

# Backend settings for a local S3-compatible endpoint (see lab_require_local_s3).
# State key: <experiment>/<unit-id>.tfstate in ${LAB_S3_BUCKET}.
_s3_backend_settings() {
  cat <<EOF
    bucket                      = "${LAB_S3_BUCKET}"
    key                         = "${LAB_NAME}/\${local.id}.tfstate"
    region                      = "us-east-1"
    endpoints                   = { s3 = "${LAB_S3_ENDPOINT}" }
    use_path_style              = true
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
EOF
}

# ============================================================================ requirements

# lab_skip <reason>  — stop this experiment as SKIPPED (exit 77, the usual
# test-suite "skip" code), not as failed: a missing optional prerequisite is not
# a broken experiment.
lab_skip() {
  echo "SKIPPED $(basename "$(cd "$(dirname "$0")" && pwd)"): $*"
  exit 77
}

lab_require_tools() { # lab_require_tools <tool>...
  for _tool in "$@"; do
    command -v "${_tool}" >/dev/null || lab_skip "needs '${_tool}' on the PATH"
  done
}

# lab_require_terraform <major.minor>  — skip unless ${LAB_TF:-terraform} is at
# least that version (OpenTofu reports its own version the same way).
lab_require_terraform() {
  lab_require_tools "${LAB_TF:-terraform}"
  _have=$("${LAB_TF:-terraform}" version -json 2>/dev/null | jq -r '.terraform_version // empty')
  [ -n "${_have}" ] || lab_skip "cannot read the ${LAB_TF:-terraform} version"
  awk -v have="${_have}" -v want="$1" 'BEGIN {
    split(have, h, "."); split(want, w, ".")
    exit !(h[1] > w[1] || (h[1] == w[1] && h[2] >= w[2]))
  }' || lab_skip "needs ${LAB_TF:-terraform} >= $1 (found ${_have})"
}

# lab_require_local_s3  — a reachable S3-compatible endpoint on THIS machine, and
# an existing bucket in it, given as
#   LAB_S3_ENDPOINT   e.g. http://localhost:5000
#   LAB_S3_BUCKET     e.g. lab-state
# Refuses anything but localhost, so lab state can never land in a real cloud
# account by accident. Credentials are forced to dummy values and any AWS
# profile is ignored, for the same reason. See README for a server recipe.
lab_require_local_s3() {
  lab_require_tools curl
  [ -n "${LAB_S3_ENDPOINT:-}" ] || lab_skip "set LAB_S3_ENDPOINT to a local S3-compatible endpoint (see README)"
  [ -n "${LAB_S3_BUCKET:-}" ]   || lab_skip "set LAB_S3_BUCKET to an existing bucket at ${LAB_S3_ENDPOINT}"
  case "${LAB_S3_ENDPOINT}" in
    http://localhost:*|http://127.0.0.1:*) ;;
    *) lab_skip "LAB_S3_ENDPOINT must be http://localhost:<port> (got ${LAB_S3_ENDPOINT})" ;;
  esac
  curl -s -o /dev/null --max-time 5 "${LAB_S3_ENDPOINT}" || lab_skip "nothing answers at ${LAB_S3_ENDPOINT}"
  unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_SESSION_TOKEN
  export AWS_ACCESS_KEY_ID="${LAB_S3_ACCESS_KEY:-lab}" AWS_SECRET_ACCESS_KEY="${LAB_S3_SECRET_KEY:-lab}"
  export AWS_REGION=us-east-1 AWS_EC2_METADATA_DISABLED=true
}

# ============================================================================ units

# mkunit <name> [dependency...]  — a unit at <name>/ (may be nested, e.g. a/b)
# depending on the listed paths, given RELATIVE to the unit (e.g. ../parent).
# Relative, not absolute: removed units run from a temporary worktree, and an
# absolute path would point back into the main checkout.
mkunit() {
  _name=$1; shift
  _dir="${REPO}/${_name}"
  mkdir -p "${_dir}"
  {
    echo 'include "root" { path = find_in_parent_folders("root.hcl") }'
    _inputs=""
    for _dep in "$@"; do
      _key=$(basename "${_dep}")
      echo "dependency \"${_key}\" {"
      echo "  config_path = \"${_dep}\""
      echo "  mock_outputs = { name = \"MOCK\" }"
      echo "}"
      _inputs="${_inputs} dependency.${_key}.outputs.name,"
    done
    echo "inputs = { parents = [${_inputs%,} ] }"
  } > "${_dir}/terragrunt.hcl"
  cat > "${_dir}/main.tf" <<EOF
variable "parents" { type = list(string) }
resource "terraform_data" "x" {
  input = { name = "${_name}", parents = var.parents }
  provisioner "local-exec" {
    command = "echo \"\$(date +%H:%M:%S) CREATE \${self.input.name} parents=\${join(",", self.input.parents)}\" >> ${EVENTS}"
  }
  provisioner "local-exec" {
    when    = destroy
    command = "echo \"\$(date +%H:%M:%S) DESTROY \${self.input.name}\" >> ${EVENTS}"
  }
}
output "name" { value = "${_name}" }
EOF
}

# unit_slow_plan <unit> <seconds>  — the unit's plan sleeps first (a before_hook),
# so other units are still queued while it runs.
unit_slow_plan() {
  cat >> "${REPO}/$1/terragrunt.hcl" <<EOF
terraform {
  before_hook "slow" {
    commands = ["plan"]
    execute  = ["sleep", "$2"]
  }
}
EOF
}

# unit_broken <unit>  — the unit's terragrunt.hcl references a variable that does
# not exist, so evaluating it fails ("Unknown variable").
unit_broken() {
  _edit_hcl "$1" 's/^inputs = {/inputs = { broken = does_not_exist.value,/'
}

# unit_no_plan_mocks <unit>  — the unit's dependencies may only be mocked for
# `validate`, so a plan that cannot read real outputs FAILS instead of mocking.
unit_no_plan_mocks() {
  _edit_hcl "$1" 's/^  mock_outputs = .*/&\n  mock_outputs_allowed_terraform_commands = ["validate"]/'
}

_edit_hcl() { sed -i.bak "$2" "${REPO}/$1/terragrunt.hcl" && rm -f "${REPO}/$1/terragrunt.hcl.bak"; }

rm_units()   { git -C "${REPO}" rm -rq "$@"; }                    # rm_units <unit>...
touch_unit() { echo "# touched" >> "${REPO}/$1/terragrunt.hcl"; }  # a change that alters nothing
touch_file() { echo "# touched" >> "${REPO}/$1"; }                 # same, for a non-unit file
tombstone()  { echo "$1" >> "${TOMBSTONES}"; }                     # record <unit> as retiring

# ============================================================================ git

commit() { # commit <message>  — prints the new SHA
  git -C "${REPO}" add -A
  git -C "${REPO}" commit -q -m "$1"
  git -C "${REPO}" rev-parse HEAD
}
on_new_branch() { git -C "${REPO}" checkout -q -b "$1" ${2:+"$2"}; }  # on_new_branch <name> [from]
switch_to()     { git -C "${REPO}" checkout -q "$1"; }
squash_merge()  { # squash_merge <branch> <message>  — prints the new SHA
  git -C "${REPO}" merge -q --squash "$1" >/dev/null
  commit "$2"
}
merge_commit()  { # merge_commit <branch> <message>  — prints the new SHA
  git -C "${REPO}" merge -q --no-ff -m "$2" "$1"
  git -C "${REPO}" rev-parse HEAD
}

# ============================================================================ terragrunt

# tg <logname> <terragrunt args...>  — run terragrunt in the sandbox, colourless,
# full output to logs/<logname>.log. Never fails the experiment; exit code is
# kept in logs/<logname>.rc. Killed after ${TG_TIMEOUT:-600}s (rc 124) so a hang
# becomes an observable result instead of a stuck experiment.
tg() {
  _log="${WORK}/logs/$1.log"; shift
  _t0=${SECONDS}
  set +e
  (cd "${REPO}" && TG_NO_COLOR=true TG_NON_INTERACTIVE=true timeout "${TG_TIMEOUT:-600}" terragrunt "$@") > "${_log}" 2>&1
  echo $? > "${_log%.log}.rc"
  set -e
  echo $((SECONDS - _t0)) > "${_log%.log}.secs"
  echo "  ran: terragrunt $* -> rc=$(cat "${_log%.log}.rc") in $(cat "${_log%.log}.secs")s (logs/$(basename "${_log}"))"
}

# tg_find  <logname> <filter>
# tg_plan  <logname> <filter> [terragrunt flags...]   e.g. --filter-allow-destroy
# tg_apply <logname> <filter> [terragrunt flags...]
# tg_apply_all <logname>                              every unit, no filter
tg_find()      { tg "$1" find --filter "$2"; }
tg_plan()      { _l=$1 _f=$2; shift 2; tg "${_l}" run --all --filter "${_f}" "$@" -- plan -no-color; }
tg_apply()     { _l=$1 _f=$2; shift 2; tg "${_l}" run --all --filter "${_f}" "$@" -- apply -auto-approve -no-color; }
tg_apply_all() { tg "$1" run --all -- apply -auto-approve -no-color; }

# spectre_hunt <logname>  — run lib/spectre-hunt.sh against the sandbox's state and
# tombstones; output in logs/<logname>.log (also printed), exit code kept.
spectre_hunt() {
  set +e
  "${LAB_ROOT}/lib/spectre-hunt.sh" "${REPO}" "${WORK}/state" "${TOMBSTONES}" > "${WORK}/logs/$1.log" 2>&1
  echo $? > "${WORK}/logs/$1.rc"
  set -e
  sed 's/^/  /' "${WORK}/logs/$1.log"
}

forget_events() { : > "${EVENTS}"; }   # start the event log afresh

# ============================================================================ terraform

# For experiments about Terraform itself (no Terragrunt, no Git). One config
# directory, ${WORK}/tf, shared by several named "environments"; each has its own
# state file, ${WORK}/state/<env>.tfstate, and its own "flesh" directory,
# ${WORK}/flesh/<env>/, holding one file per resource while that resource lives.
# Only provisioners create or remove the flesh, and each also writes an event
# line ("CREATE <env>/<name>"), so show_events tells the story afterwards.

tf_workspace() {
  TF_CFG="${WORK}/tf"
  mkdir -p "${TF_CFG}" "${WORK}/flesh"
  cat > "${TF_CFG}/header.tf" <<'EOF'
terraform {
  required_version = ">= 1.7"
}

variable "flesh" {
  type = string
}
EOF
}

# tf_declare <name>  — a live resource block: terraform_data.<name>, whose
# create/destroy provisioners make/remove its flesh file.
tf_declare() {
  cat > "${TF_CFG}/$1.tf" <<EOF
resource "terraform_data" "$1" {
  triggers_replace = { dir = var.flesh }

  provisioner "local-exec" {
    command = "mkdir -p '\${var.flesh}' && touch '\${var.flesh}/$1' && echo \"\$(date +%H:%M:%S) CREATE \${basename(var.flesh)}/$1\" >> ${EVENTS}"
  }
$(_tf_destroy_provisioner "$1")
}
EOF
}

# tf_tombstone <name> retain|destroy|destroy_bare  — a removed block for
# terraform_data.<name>. "destroy" carries the destroy provisioner (a removed
# block can; the resource block's own provisioner is gone with that block);
# "destroy_bare" does not, so the flesh is left behind.
tf_tombstone() {
  case "$2" in
    retain)                _destroy=false ;;
    destroy|destroy_bare)  _destroy=true ;;
    *) echo "unknown tombstone kind: $2" >&2; exit 2 ;;
  esac
  cat > "${TF_CFG}/$1.removed.tf" <<EOF
removed {
  from = terraform_data.$1
  lifecycle {
    destroy = ${_destroy}
  }
$([ "$2" = destroy ] && _tf_destroy_provisioner "$1")
}
EOF
}

_tf_destroy_provisioner() {
  cat <<EOF

  provisioner "local-exec" {
    when    = destroy
    command = "rm -f '\${self.triggers_replace.dir}/$1' && echo \"\$(date +%H:%M:%S) DESTROY \${basename(self.triggers_replace.dir)}/$1\" >> ${EVENTS}"
  }
EOF
}

# tf_undeclare <name>  — drop both the resource block and any tombstone for it
tf_undeclare() { rm -f "${TF_CFG}/$1.tf" "${TF_CFG}/$1.removed.tf"; }

# tf <logname> <terraform args...>  — like tg: logged, exit code kept, never fails
tf() {
  _log="${WORK}/logs/$1.log"; shift
  _t0=${SECONDS}
  set +e
  TF_IN_AUTOMATION=1 timeout "${TG_TIMEOUT:-600}" "${LAB_TF:-terraform}" -chdir="${TF_CFG}" "$@" > "${_log}" 2>&1
  echo $? > "${_log%.log}.rc"
  set -e
  echo $((SECONDS - _t0)) > "${_log%.log}.secs"
  _args="$*"
  echo "  ran: ${LAB_TF:-terraform} ${_args//${WORK}\//} -> rc=$(cat "${_log%.log}.rc") in $(cat "${_log%.log}.secs")s (logs/$(basename "${_log}"))"
}

_tf_env_args() { echo "-state=${WORK}/state/$1.tfstate" "-var=flesh=${WORK}/flesh/$1"; }
tf_init()     { tf "$1" init -input=false -no-color; }
tf_plan()     { tf "$1" plan  -input=false -no-color $(_tf_env_args "$2"); }               # <logname> <env>
tf_apply()    { tf "$1" apply -input=false -no-color -auto-approve $(_tf_env_args "$2"); } # <logname> <env>
tf_validate() { tf "$1" validate -no-color; }

# show_plan <logname> <label>  — print (and record) the lines of a plan that matter
show_plan() {
  echo "  $2"
  { echo "PLAN    $2"
    grep -E 'will be|no longer|No changes|Plan:|Error' "${WORK}/logs/$1.log" | sed 's/^ *//; s/^/          /'
  } | tee -a "${RESULTS}" | tail -n +2
}

# ============================================================================ checks

# event log lines: "<time> <CREATE|DESTROY> <unit> [parents=...]"
_events_of()     { awk -v k="$1" '$2 == k { print $3 }' "${EVENTS}"; }
created()        { _events_of CREATE  | grep -qxF -- "$1"; }
destroyed()      { _events_of DESTROY | grep -qxF -- "$1"; }
not_destroyed()  { ! destroyed "$1"; }
event_count_is() { [ "$(_events_of "$1" | wc -l | tr -d ' ')" -eq "$2" ]; }  # <KIND> <n>
# events_in_order <CREATE|DESTROY> <unit>... — every unit has that event, and
# their first occurrences appear in the order given.
events_in_order() {
  _kind=$1; shift
  _prev=0
  for _unit in "$@"; do
    _line=$(awk -v k="${_kind}" -v u="${_unit}" '$2 == k && $3 == u { print NR; exit }' "${EVENTS}")
    [ -n "${_line}" ] && [ "${_line}" -gt "${_prev}" ] || return 1
    _prev=${_line}
  done
}

# found_in / not_found_in <logname> <unit> — is <unit> a line of a `find` log?
found_in()     { grep -qxF -- "$2" "${WORK}/logs/$1.log"; }
not_found_in() { ! found_in "$@"; }

log_has()      { grep -Eq -- "$2" "${WORK}/logs/$1.log"; }        # <logname> <regex>
log_lacks()    { ! log_has "$@"; }
log_count_is() { [ "$(grep -Ec -- "$2" "${WORK}/logs/$1.log")" -eq "$3" ]; }  # <logname> <regex> <n>

# state_is <unit> <n>  — the unit's state holds n resources (0 if no state file)
state_is() {
  _f="${WORK}/state/$(printf '%s' "$1" | tr '/' '_').tfstate"
  _n=0; [ -f "${_f}" ] && _n=$(jq '.resources | length' "${_f}")
  [ "${_n}" -eq "$2" ]
}

rc_is()     { [ "$(cat "${WORK}/logs/$1.rc")" = "$2" ]; }  # <logname> <exit code>
elapsed()   { cat "${WORK}/logs/$1.secs"; }                # seconds a tg call took
timed_out() { rc_is "$1" 124; }                            # killed by TG_TIMEOUT
finished()  { ! timed_out "$1"; }

hunted_as() { log_has "$1" "^$2 +$3 "; }   # hunted_as <logname> <alive|tombstone|buried|SPECTRE> <unit>

# in_state / not_in_state <env> <name>  — terraform_data.<name> in <env>'s state
in_state() {
  _f="${WORK}/state/$1.tfstate"
  [ -f "${_f}" ] && jq -e --arg n "$2" 'any(.resources[]; .type == "terraform_data" and .name == $n)' "${_f}" >/dev/null
}
not_in_state()  { ! in_state "$@"; }
# flesh_present / flesh_absent <env> <name>  — does the resource's flesh file exist?
flesh_present() { [ -e "${WORK}/flesh/$1/$2" ]; }
flesh_absent()  { ! flesh_present "$@"; }

# ============================================================================ results

claim() {
  _text=$1; shift
  if "$@"; then _r="CLAIM   PASS     ${_text}"
  else _r="CLAIM   SURPRISE ${_text}"; LAB_SURPRISES=$((LAB_SURPRISES + 1)); fi
  echo "${_r}" | tee -a "${RESULTS}"
}

observe() {
  _text=$1; shift
  if "$@"; then _r="OBSERVE YES      ${_text}"; else _r="OBSERVE NO       ${_text}"; fi
  echo "${_r}" | tee -a "${RESULTS}"
}

note() { echo "NOTE    $*" | tee -a "${RESULTS}"; }

section() { printf '\n== %s\n' "$*"; }

show_events() {
  section "event log"
  sed 's/^/  /' "${EVENTS}"
  { echo "events:"; sed 's/^/  /' "${EVENTS}"; } >> "${RESULTS}"
}

lab_finish() {
  section "summary (${RESULTS#"${LAB_ROOT}/"})"
  grep -E '^(CLAIM|OBSERVE|NOTE)' "${RESULTS}" | sed 's/^/  /'
  [ "${LAB_SURPRISES}" -eq 0 ] || { echo "  ${LAB_SURPRISES} surprise(s)"; exit 1; }
}
