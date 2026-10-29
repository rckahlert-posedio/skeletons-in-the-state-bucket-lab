#!/usr/bin/env bash
# e05 — Does Terragrunt treat a hand-written `generate "backend"` block like a
# `remote_state` block when running removed units from a Git worktree?
#
# Many real setups (including the one that prompted this lab) configure a remote
# backend via `generate "backend"` rather than `remote_state`. Terragrunt's Git
# filter docs strongly recommend "remote state". Both styles here store state
# outside the checkout, so the only difference is how Terragrunt sees it.
. "$(dirname "$0")/../../lib/lab.sh"
lab_variants BACKEND_STYLE remote_state generate
lab_init

section "C0: create product/space <- product/stage, plus bystander"
mkunit product/space
mkunit product/stage ../space
unit_no_plan_mocks product/stage   # unreadable real outputs must FAIL, not mock
mkunit bystander
C0=$(commit "C0: create")
tg_apply_all apply0
claim "initial apply succeeds" rc_is apply0 0

rm_units product
C1=$(commit "C1: delete product")
FILTER="[${C0}...${C1}]"

tg_plan plan_flag "${FILTER}" --filter-allow-destroy
observe "Terragrunt warns the units 'do not have a remote_state configuration'" \
  log_has plan_flag 'do not have a remote_state configuration'
note "the warning appears for BOTH styles here: it reacts to the local backend type, so this lab cannot tell whether generate+gcs/s3 would trigger it (needs a real remote backend, e.g. S3 on MinIO)"
claim "removed stage can read removed space's real outputs (plan succeeds without mocks)" rc_is plan_flag 0

tg_apply apply_flag "${FILTER}" --filter-allow-destroy
claim "both removed units are destroyed" event_count_is DESTROY 2
claim "stage destroyed before space"     events_in_order DESTROY product/stage product/space

show_events
lab_finish
