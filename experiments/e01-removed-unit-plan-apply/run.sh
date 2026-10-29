#!/usr/bin/env bash
# e01 — A removed unit under Git-based filters: plan and apply, with and without
# --filter-allow-destroy.
. "$(dirname "$0")/../../lib/lab.sh"
lab_init

section "C0: create parent <- child, plus an unrelated bystander"
mkunit parent
mkunit child ../parent
mkunit bystander
C0=$(commit "C0: create")
tg_apply_all apply0
claim "initial apply creates all three units" created child

section "C1: delete the leaf unit 'child'"
rm_units child
C1=$(commit "C1: delete child")
FILTER="[${C0}...${C1}]"

tg_find find "${FILTER}"
claim "find reports the removed unit" found_in find child

tg_plan plan_noflag "${FILTER}"
observe "plan WITHOUT --filter-allow-destroy shows a destroy plan for child" log_has plan_noflag '1 to destroy'
observe "plan WITHOUT the flag warns that child will be excluded from applies" log_has plan_noflag 'excluded during applies'

tg_plan plan_flag "${FILTER}" --filter-allow-destroy
claim   "plan WITH --filter-allow-destroy shows a destroy plan for child" log_has plan_flag '1 to destroy'
observe "the bystander is not part of the filtered run" log_lacks plan_flag 'bystander'

tg_apply apply_noflag "${FILTER}"
claim "apply WITHOUT the flag does not destroy child" not_destroyed child
claim "child's state still holds its resource"        state_is child 1

tg_apply apply_flag "${FILTER}" --filter-allow-destroy
claim "apply WITH the flag destroys child" destroyed child
claim "child's state is empty afterwards"  state_is child 0
claim "parent survives"                    state_is parent 1

show_events
lab_finish
