#!/usr/bin/env bash
# e04 — Event-based deletion depends on WHICH Git range a run looks at.
#
#   S1  the missed event: the deletion commit's run never destroys; the next run's
#       range starts after it -> the orphan is invisible from then on (a spectre)
#   S2  squash merge vs merge commit: does the main-branch range still contain
#       the deletion?
#   S3  what does [A...B] mean for diverged refs — a plain tree diff, or Git's
#       merge-base ("three-dot") semantics? And can a stale branch resurrect a
#       unit that main has already destroyed (a zombie)?
. "$(dirname "$0")/../../lib/lab.sh"
lab_init

section "C0: create parent <- child, plus bystander"
mkunit parent
mkunit child ../parent
mkunit bystander
C0=$(commit "C0: create")
tg_apply_all apply0

# ---------------------------------------------------------------- S1
section "S1: deletion commit C1, its run never applies; then C2 touches only bystander"
rm_units child;        C1=$(commit "C1: delete child")
touch_unit bystander;  C2=$(commit "C2: unrelated change")

tg_find s1_find_c0c1 "[${C0}...${C1}]"
claim "range [C0...C1] (the deletion's own run) sees child" found_in s1_find_c0c1 child
tg_find s1_find_c1c2 "[${C1}...${C2}]"
claim "range [C1...C2] (the next run, BEFORE_SHA=C1) does NOT see child" not_found_in s1_find_c1c2 child
tg_apply s1_apply_c1c2 "[${C1}...${C2}]" --filter-allow-destroy
claim "after the next run, child's state still holds its resource: a spectre" state_is child 1
tg_find s1_find_head "[HEAD~1...HEAD]"
claim "no later single-commit range will ever mention child again" not_found_in s1_find_head child
note "only a range reaching back to before C1 (e.g. [C0...HEAD]) can still destroy it"

# ---------------------------------------------------------------- S2
section "S2: deletion on a feature branch, merged by squash vs merge commit"
on_new_branch feature "${C0}"
rm_units child;        F1=$(commit "F1: delete child")
touch_unit bystander;  F2=$(commit "F2: touch bystander")

on_new_branch main-squash "${C0}"
S=$(squash_merge feature "squash feature")
tg_find s2_find_squash "[${C0}...${S}]"
claim "squash merge: [before...squash] sees child" found_in s2_find_squash child

on_new_branch main-merge "${C0}"
touch_file NOTES;      B1=$(commit "main moves on")
M=$(merge_commit feature "merge feature")
tg_find s2_find_merge "[${B1}...${M}]"
claim "merge commit: [before...merge] sees child" found_in s2_find_merge child
tg_find s2_find_lastcommit "[${F1}...${F2}]"
claim "a per-commit range on the branch after F1 ([F1...F2]) does NOT see child" not_found_in s2_find_lastcommit child

# ---------------------------------------------------------------- S3
section "S3: diverged refs — main deletes child, a branch from before only touches bystander"
on_new_branch main-s3 "${C0}"
rm_units child;        M1=$(commit "main: delete child")
on_new_branch branch-s3 "${C0}"
touch_unit bystander;  BR=$(commit "branch: touch bystander")
tg_find s3_find "[${M1}...${BR}]"
observe "[main...branch] reports child (=> plain tree diff, NOT git merge-base semantics)" found_in s3_find child
observe "[main...branch] reports bystander" found_in s3_find bystander

section "S3b: main destroys child; then the stale branch applies with [main...branch]"
switch_to main-s3
tg_apply s3_destroy_main "[${C0}...${M1}]" --filter-allow-destroy
claim "main's run destroys child" state_is child 0
switch_to branch-s3
forget_events
tg_apply s3_apply_branch "[${M1}...${BR}]"
observe "the stale branch's apply RECREATES child (zombie)" created child
observe "child's state holds a resource again"              state_is child 1
note "the filter is not the root cause: any apply of a branch that still contains child would recreate it. The point is that a tree-diff range SELECTS child as changed instead of protecting it"
note "GitLab MR pipelines diff against CI_MERGE_REQUEST_DIFF_BASE_SHA (the merge-base), so they would not select child here; a hand-written [main...HEAD] does"

show_events
lab_finish
