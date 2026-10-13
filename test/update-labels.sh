#!/usr/bin/env bash

DELETE="${DELETE:-false}" # options: false, true
POLICY="${POLICY:-multi-tenancy}" # options: data-sovereignty, multi-tenancy, workload-security-rings

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

declare -a EU_REGIONS=("francecentral" "francesouth" "germanynorth" "germanywestcentral" "italynorth" "northeurope" "norwayeast" "norwaywest" "polandcentral" "spaincentral" "swedencentral" "switzerlandnorth" "switzerlandwest" "westeurope" "eu-central-1" "eu-central-2" "eu-north-1" "eu-south-1" "eu-south-2" "eu-west-1" "eu-west-3" "europe-central2" "europe-north1" "europe-southwest1" "europe-west1" "europe-west3" "europe-west4" "europe-west6" "europe-west8" "europe-west9" "europe-west12")
declare -a US_REGIONS=("centralus" "centraluseuap" "centralusstage" "eastus" "eastus2" "eastus2euap" "eastus2stage" "eastusstage" "eastusstg" "northcentralus" "northcentralusstage" "southcentralus" "southcentralusstage" "southcentralusstg" "westcentralus" "westus" "westus2" "westus2stage" "westus3" "westusstage" "us-east-1" "us-east-2" "us-gov-east-1" "us-gov-west-1" "us-west-1" "us-west-2" "us-central1" "us-east1" "us-east4" "us-east5" "us-south1" "us-west1" "us-west2" "us-west3" "us-west4")
declare -a REGIONS=("italynorth" ${EU_REGIONS[${RANDOM} % 31]} ${US_REGIONS[${RANDOM} % 35]})

declare -a TENANTS=("uc1" "uc2") # "uc3" "uc4")

declare -a SECURITY_RINGS=("sensitive" "unhardened")

function unlabel_nodes {
    nodes=$1
    key=$2

    for node in "${nodes[@]}"
    do
        kubectl label nodes ${node} ${key}-
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
            unlabel_nodes ${nodes} topology.kubernetes.io/region
            ;;
        'multi-tenancy')
            unlabel_nodes ${nodes} tenant
            unlabel_nodes ${nodes} topology.kubernetes.io/tenant
            ;;
        'workload-security-rings')
            unlabel_nodes ${nodes} security-ring
            ;;
        *)
            echo "Unknown policy: $POLICY"
            exit 1
            ;;
    esac
fi
