#!/usr/bin/env bash
# e02 — A whole dependency chain removed in one commit: in which order are the
# removed units destroyed?
#
# Shape (mirrors a "product" with a space, a stage and an environment):
#   space        (no deps)
#   env          (no deps)
#   stage   ->   depends on space and env
# The run-queue docs say that for destroy, "dependent units are run before
# their dependencies" — so stage should go before both space and env.
. "$(dirname "$0")/../../lib/lab.sh"
lab_init

section "C0: create space, env, stage (stage depends on both), bystander"
mkunit product/space
mkunit product/env
mkunit product/stage ../space ../env
mkunit bystander
C0=$(commit "C0: create")
tg_apply_all apply0
claim "initial apply creates stage after space" events_in_order CREATE product/space product/stage
claim "initial apply creates stage after env"   events_in_order CREATE product/env product/stage

section "C1: delete the whole product"
rm_units product
C1=$(commit "C1: delete product")
FILTER="[${C0}...${C1}]"

tg_find find "${FILTER}"
claim "find reports all three removed units" log_count_is find '^product/' 3

tg_plan plan_flag "${FILTER}" --filter-allow-destroy
claim   "plan shows a destroy for each removed unit" log_count_is plan_flag '1 to destroy' 3
observe "plan run in the old worktree read real dependency outputs (no MOCK)" log_lacks plan_flag MOCK

forget_events
tg_apply apply_flag "${FILTER}" --filter-allow-destroy
claim "all three removed units are destroyed"            event_count_is DESTROY 3
claim "stage (the dependent) is destroyed before space"  events_in_order DESTROY product/stage product/space
claim "stage (the dependent) is destroyed before env"    events_in_order DESTROY product/stage product/env
claim "bystander untouched"                              state_is bystander 1

show_events
lab_finish
