#!/usr/bin/env bash

DELETE="${DELETE:-false}" # options: false, true
POLICY="${POLICY:-multi-tenancy}" # options: data-sovereignty, multi-tenancy, workload-security-rings

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

declare -a EU_REGIONS=("francecentral" "francesouth" "germanynorth" "germanywestcentral" "italynorth" "northeurope" "norwayeast" "norwaywest" "polandcentral" "spaincentral" "swedencentral" "switzerlandnorth" "switzerlandwest" "westeurope" "eu-central-1" "eu-central-2" "eu-north-1" "eu-south-1" "eu-south-2" "eu-west-1" "eu-west-3" "europe-central2" "europe-north1" "europe-southwest1" "europe-west1" "europe-west3" "europe-west4" "europe-west6" "europe-west8" "europe-west9" "europe-west12")
declare -a US_REGIONS=("centralus" "centraluseuap" "centralusstage" "eastus" "eastus2" "eastus2euap" "eastus2stage" "eastusstage" "eastusstg" "northcentralus" "northcentralusstage" "southcentralus" "southcentralusstage" "southcentralusstg" "westcentralus" "westus" "westus2" "westus2stage" "westus3" "westusstage" "us-east-1" "us-east-2" "us-gov-east-1" "us-gov-west-1" "us-west-1" "us-west-2" "us-central1" "us-east1" "us-east4" "us-east5" "us-south1" "us-west1" "us-west2" "us-west3" "us-west4")
declare -a REGIONS=("italynorth" ${EU_REGIONS[${RANDOM} % 31]} ${US_REGIONS[${RANDOM} % 35]})

declare -a TENANTS=("uc1" "uc2") # "uc3" "uc4")

declare -a SECURITY_RINGS=("sensitive" "unhardened")

# NOTE: takes the key FIRST, then the node names as separate arguments.
# The previous signature was unlabel_nodes <nodes> <key> and was called as
# `unlabel_nodes ${nodes} <key>` - an unquoted array expansion, so $1 was
# only nodes[0] and $2 was nodes[1] rather than the key. DELETE=true
# therefore unlabelled exactly one node and silently left the other 99
# carrying the previous policy's labels. That is the failure mode behind
# the 2026-10-16 incident where a stale topology.kubernetes.io/region
# hijacked Hierarchical segmentation.
function unlabel_nodes {
    local key=$1
    shift
    local node
    for node in "$@"
    do
        kubectl label nodes "${node}" "${key}-" >/dev/null 2>&1 || true
    done
}

# Initiate list of worker nodes
nodes=$(kubectl get nodes -l !node-role.kubernetes.io/control-plane -o json | jq -r '.items[].metadata.name')
readarray -t nodes <<<"${nodes}"

if [ "$DELETE" = false ]; then
    echo -e '[*] Set node labels'

    i=0
    case "$POLICY" in
        'data-sovereignty')
            for node in "${nodes[@]}"
            do
                kubectl label nodes ${node} topology.kubernetes.io/region=${REGIONS[${i} % 3]} --overwrite
                i=$((i+1))
            done
            ;;
        'multi-tenancy')
            for node in "${nodes[@]}"
            do
                # Also applied as topology.kubernetes.io/tenant (same value,
                # same node, same iteration — can never disagree with the
                # bare "tenant" label) because KLASTOS's
                # ClassSchedulingConstraint CRD only accepts
                # 'kubernetes.io/hostname' or a 'topology.kubernetes.io/'
                # prefixed topologyKey (confirmed against
                # classschedulingconstraints-crd.yaml) — it cannot reference
                # a bare custom label directly. The Gatekeeper baseline
                # keeps reading the original bare "tenant" label unchanged.
                kubectl label nodes ${node} tenant=${TENANTS[${i} % 2]} topology.kubernetes.io/tenant=${TENANTS[${i} % 2]} --overwrite
                i=$((i+1))
            done
            ;;
        'workload-security-rings')
            for node in "${nodes[@]}"
            do
                kubectl label nodes ${node} security-ring=${SECURITY_RINGS[${i} % 2]} --overwrite
                i=$((i+1))
            done
            ;;
        *)
            echo "Unknown policy: $POLICY"
            exit 1
            ;;
    esac
else
    echo -e '[*] Remove node labels'
    case "$POLICY" in
        'data-sovereignty')
            unlabel_nodes topology.kubernetes.io/region "${nodes[@]}"
            ;;
        'multi-tenancy')
            unlabel_nodes tenant "${nodes[@]}"
            unlabel_nodes topology.kubernetes.io/tenant "${nodes[@]}"
            ;;
        'workload-security-rings')
            unlabel_nodes security-ring "${nodes[@]}"
            ;;
        *)
            echo "Unknown policy: $POLICY"
            exit 1
            ;;
    esac
fi
