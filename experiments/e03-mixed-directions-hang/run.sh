#!/usr/bin/env bash
# e03 — Removed units and surviving units in the same filtered run.
# Reproduces terragrunt issue #6860: surviving units run "up" (dependency order),
# removed units run "down" (reverse order); readiness ignores cross-direction
# edges but failure propagation does not, so one failing removed unit can leave
# surviving units waiting forever.
#
# Two runs over the same shape:
#   A. the removed unit is healthy          -> expected to finish
#   B. the removed unit fails to evaluate   -> #6860 predicts a hang
#
# Plans only: nothing needs to exist yet, dependencies fall back to mock outputs.
. "$(dirname "$0")/../../lib/lab.sh"
lab_init
# Deliberate waits: base's plan is slowed by 5 s so the surviving units are still
# queued when gone1 fails. Case B is declared hung once it has taken 5x as long
# as the healthy case A did (at least 20 s), so the verdict adapts to the
# machine instead of relying on a fixed timeout. Override with E03_TIMEOUT.

run_case() { # run_case <label> <healthy|broken>
  _note=; [ "$2" = broken ] && _note=" (declared hung after ${TG_TIMEOUT}s)"
  section "case $1: the removed unit gone1 is $2${_note}"
  rm -rf "${REPO:?}/live"
  mkunit live/base; unit_slow_plan live/base 5
  mkunit live/a     ../base
  mkunit live/b     ../a
  mkunit live/gone1 ../base ../a
  mkunit live/gone2 ../b
  [ "$2" = broken ] && unit_broken live/gone1
  _c0=$(commit "$1 C0: create")
  rm_units live/gone1 live/gone2
  _c1=$(commit "$1 C1: delete gone1 gone2")
  tg_plan "plan_$1" "...[${_c0}...${_c1}]... | ./**" --no-filters-file --filter-allow-destroy
}

TG_TIMEOUT=300 run_case A healthy
observe "case A finishes (took $(elapsed plan_A)s)"   finished plan_A
observe "case A: surviving unit b was planned"        log_has plan_A '\[live/b\]'

HANG_AFTER=$(( 5 * $(elapsed plan_A) )); [ "${HANG_AFTER}" -ge 20 ] || HANG_AFTER=20
B_TIMEOUT=${E03_TIMEOUT:-${HANG_AFTER}}
TG_TIMEOUT=${B_TIMEOUT} run_case B broken
B_RATIO=$(awk -v b="${B_TIMEOUT}" -v a="$(elapsed plan_A)" 'BEGIN { if (a > 0) printf "%.1fx case A", b / a; else print "case A took 0s" }')
observe "case B HANGS (killed after ${B_TIMEOUT}s, ${B_RATIO}) — issue #6860" timed_out plan_B
observe "case B: surviving unit a never ran"          log_lacks plan_B '\[live/a\]'
observe "case B: gone1 failed with 'Unknown variable'" log_has plan_B 'does_not_exist|Unknown variable'

lab_finish
