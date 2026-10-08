#!/usr/bin/env bash
# Deletes the KWOK benchmark cluster (kind cluster, KWOK fake nodes,
# Gatekeeper, everything) built by setup-kind-kwok-manual.sh. That script
# does not delete an existing cluster itself - `kind create cluster` just
# fails if one with the same name already exists - so this is the
# companion "reinstall" step: run this, then setup-kind-kwok-manual.sh
# again, to rebuild from scratch.
#
# This is destructive and not scoped to klastos at all: it removes the
# ENTIRE cluster, including Gatekeeper and anything else deployed on it
# (the klastos stack, whichever mode it's in, included) - not just the
# klastos application layer (compare experiment1/teardown-klastos-stack.sh,
# which only removes klastos's own resources and leaves the cluster and
# Gatekeeper alone).
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-secure-sched}"

echo "=== Deleting KWOK benchmark cluster ($CLUSTER_NAME) ==="
kind delete cluster --name "$CLUSTER_NAME"
echo "=== Cluster deleted ==="
echo "Rebuild with: bash $(dirname "${BASH_SOURCE[0]}")/setup-kind-kwok-manual.sh"
