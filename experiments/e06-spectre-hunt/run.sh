#!/usr/bin/env bash
# e06 — A "spectre hunt": sweep the state backend for state that no live config
# and no tombstone accounts for. Prototype of the level-triggered safety net behind
# event-based deletion (see e04 S1 for how spectres are made).
. "$(dirname "$0")/../../lib/lab.sh"
lab_init

section "C0: four units"
mkunit keep; mkunit gone; mkunit retiring; mkunit done
C0=$(commit "C0: create")
tg_apply_all apply0

section "C1: delete gone, retiring and done in one commit"
rm_units gone retiring done
C1=$(commit "C1: delete three units")
tg_apply destroy_done "[${C0}...${C1}] | ./done" --filter-allow-destroy   # done: destroyed properly
tombstone retiring                                                          # retiring: destroy pending
                                                                            # gone: forgotten (cf. e04 S1)
section "hunt"
spectre_hunt hunt1
claim "keep is alive"                          hunted_as hunt1 alive     keep
claim "done is buried (empty state)"           hunted_as hunt1 buried    done
claim "retiring is a pending tombstone"        hunted_as hunt1 tombstone retiring
claim "gone is a SPECTRE"                      hunted_as hunt1 SPECTRE   gone
claim "the hunt fails while a spectre exists"  rc_is hunt1 1

section "lay the spectre to rest: destroy from a range that still contains it"
tg_apply destroy_gone "[${C0}...HEAD] | ./gone" --filter-allow-destroy
spectre_hunt hunt2
claim "gone is buried after the catch-up destroy" hunted_as hunt2 buried gone
claim "the hunt passes once no spectre remains"   rc_is hunt2 0

lab_finish
