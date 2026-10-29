#!/usr/bin/env bash
# spectre-hunt.sh — find state files that no live configuration accounts for.
#
# Usage: spectre-hunt.sh <repo-dir> <state-dir> [tombstones-file]
#
# Compares three sets of unit ids:
#   live        units Terragrunt finds in the current checkout
#   state       state files in the backend (here: <state-dir>/<id>.tfstate)
#   tombstones  ids deliberately retired but not yet destroyed (one per line)
#
# and classifies every state file:
#   alive      has live config
#   tombstone  no live config, listed as a tombstone: destroy is pending, expected
#   buried     no live config, state is empty: destroy done, only the record remains
#   SPECTRE    no live config, not a tombstone, still holds resources
#
# Exits 1 if any SPECTRE is found. The id scheme here is "unit path with / -> _";
# a real implementation would read whatever keys the state (e.g. a constants id)
# and list the bucket instead of a directory.
set -eu
repo=$1; state=$2; tombstones=${3:-/dev/null}

live=$(cd "${repo}" && TG_NO_COLOR=true terragrunt find 2>/dev/null | tr '/' '_' | sort)
spectres=0
for f in "${state}"/*.tfstate; do
  [ -e "${f}" ] || continue
  id=$(basename "${f}" .tfstate)
  n=$(jq '.resources | length' "${f}")
  if printf '%s\n' "${live}" | grep -qx "${id}"; then           kind=alive
  elif grep -qx "${id}" "${tombstones}" 2>/dev/null; then       kind=tombstone
  elif [ "${n}" -eq 0 ]; then                                    kind=buried
  else                                                           kind=SPECTRE; spectres=$((spectres + 1))
  fi
  printf '%-10s %-30s resources=%s\n' "${kind}" "${id}" "${n}"
done
[ "${spectres}" -eq 0 ]
