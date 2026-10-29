#!/usr/bin/env bash
# e07 — the removed block: tombstones, retention, laggards, resurrection.
#
# Plain Terraform, no Terragrunt and no Git: one configuration shared by several
# environments, each with its own state and its own "flesh" (a file that exists
# while the resource lives; only provisioners create or remove it). Uses only the
# built-in terraform_data resource and local-exec, so no providers are downloaded.
# Requires terraform >= 1.7.
. "$(dirname "$0")/../../lib/lab.sh"
lab_require_terraform 1.7
lab_init
tf_workspace
tf_declare events
tf_init init

# ---------------------------------------------------------------- S1
section "S1  tombstone with destroy = true retires the flesh"
note "docs: removed { destroy = true } plans a destroy and drops the address from state."
tf_apply s1_apply_live retire
tf_apply s1_apply_live_bare retire_bare
claim "before: resource in state" in_state retire events
claim "before: flesh present"     flesh_present retire events
tf_undeclare events; tf_tombstone events destroy
tf_plan s1_plan retire
show_plan s1_plan "plan with destroy = true:"
tf_apply s1_apply_tomb retire
claim "after: address dropped from state"                  not_in_state retire events
claim "after: flesh removed by destroy provisioner"        flesh_absent retire events
note "the destroy provisioner sits in the removed block: the resource block's own is gone with that block (docs)"
tf_tombstone events destroy_bare
tf_apply s1_apply_bare retire_bare
observe "without a destroy provisioner in the removed block, the flesh is left behind: a destroy provisioner is lost with its resource block" \
  flesh_present retire_bare events

# ---------------------------------------------------------------- S2
section "S2  tombstone with destroy = false forgets without destroying"
note "docs: destroy = false removes the address from state and leaves the resource running."
tf_undeclare events; tf_declare events
tf_apply s2_apply_live keep
tf_undeclare events; tf_tombstone events retain
tf_plan s2_plan keep
show_plan s2_plan "plan with destroy = false:"
tf_apply s2_apply_tomb keep
claim "after: address dropped from state" not_in_state keep events
claim "after: flesh still present"        flesh_present keep events

# ---------------------------------------------------------------- S3
section "S3  the laggard: a tombstone removed before another environment applies it"
note "docs: a removed block acts only on the state it is applied to; each environment needs its own apply."
tf_undeclare events; tf_declare events
tf_apply s3_apply_staging staging
tf_apply s3_apply_prod prod
tf_undeclare events; tf_tombstone events retain
tf_apply s3_apply_prod_tomb prod                      # prod applies the retention tombstone
claim "prod forgot the address"         not_in_state prod events
claim "prod kept its flesh"             flesh_present prod events
claim "staging still holds the address" in_state staging events
tf_undeclare events                                   # tombstone cleaned up in the repo
tf_plan s3_plan_staging staging
show_plan s3_plan_staging "staging plan with no resource block and no tombstone:"
claim "staging plan destroys by default, ignoring the retain intent" log_has s3_plan_staging 'will be destroyed'
tf_apply s3_apply_staging_gone staging
claim "staging plans a destroy and drops the address" not_in_state staging events
observe "the destroy-time side effect is not run because there is no config to carry it" \
  flesh_present staging events

# ---------------------------------------------------------------- S4
section "S4  resurrection after cleanup"
note "docs: state records what exists, not what was retired; a configuration that declares the resource again plans a create."
tf_declare events
claim "retire environment holds no address" not_in_state retire events
tf_plan s4_plan_retire retire
show_plan s4_plan_retire "plan from a stale branch that still declares the resource:"
claim "plan creates the resource again" log_has s4_plan_retire 'will be created'
tf_apply s4_apply_retire retire
claim "resource back in state" in_state retire events
claim "flesh back"             flesh_present retire events
tf_plan s4_plan_keep keep
show_plan s4_plan_keep "keep environment (flesh never removed) under the same config, plan only:"
observe "keep environment plans a create beside the surviving resource" log_has s4_plan_keep 'will be created'
observe "the surviving flesh is still there while that create is planned" flesh_present keep events

# ---------------------------------------------------------------- S5
section "S5  a tombstone and a live block for one address"
note "a removed block cannot sit beside a resource block for the same address."
tf_declare events; tf_tombstone events destroy
tf_validate s5_validate
tf_plan s5_plan retire
claim   "plan rejects the combination (Error: Removed resource still exists)" log_has s5_plan 'Error: Removed resource still exists'
observe "validate accepts it" rc_is s5_validate 0
tf_undeclare events; tf_declare events

show_events
lab_finish
