#!/usr/bin/env bash
# b01 — e05 again, against a real remote backend instead of the local one.
#
# e05 found that Terragrunt warns "do not have a remote_state configuration" for
# BOTH backend styles — but only because the lab's backend is `local`. This asks
# the question that matters for real setups: with an actual remote backend (S3
# here), does a hand-written `generate "backend"` block still trigger the warning
# where a `remote_state` block does not? And does either change how removed units
# read their dependencies' outputs from the old worktree?
#
# Requires a local S3-compatible endpoint and bucket: LAB_S3_ENDPOINT,
# LAB_S3_BUCKET (see README, "Backend experiments"). Skipped otherwise.
. "$(dirname "$0")/../../lib/lab.sh"
lab_require_local_s3
lab_variants BACKEND_STYLE s3_remote_state s3_generate
lab_init

section "C0: create product/space <- product/stage, plus bystander"
mkunit product/space
mkunit product/stage ../space
unit_no_plan_mocks product/stage   # unreadable real outputs must FAIL, not mock
mkunit bystander
C0=$(commit "C0: create")
tg_apply_all apply0
claim "initial apply succeeds against the S3 backend" rc_is apply0 0

rm_units product
C1=$(commit "C1: delete product")
FILTER="[${C0}...${C1}]"

tg_plan plan_flag "${FILTER}" --filter-allow-destroy
observe "Terragrunt warns the units 'do not have a remote_state configuration'" \
  log_has plan_flag 'do not have a remote_state configuration'
claim "removed stage can read removed space's real outputs (plan succeeds without mocks)" rc_is plan_flag 0

tg_apply apply_flag "${FILTER}" --filter-allow-destroy
claim "both removed units are destroyed" event_count_is DESTROY 2
claim "stage destroyed before space"     events_in_order DESTROY product/stage product/space

show_events
lab_finish
