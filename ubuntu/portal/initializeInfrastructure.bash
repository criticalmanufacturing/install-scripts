#!/bin/bash

REPOSITORY=${REPOSITORY:-"https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main"}

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -a|--agent) agent="$2"; shift ;;
        -s|--site) site="$2"; shift ;; # deprecated, but can still be in use
        -c|--customer) customer="$2"; shift ;;
        -i|--infrastructure) infrastructure="$2"; shift ;;
        -e|--environmentType) environmentType="$2"; shift ;;
        -n|--internetNetworkName) internetNetworkName="$2"; shift ;;
        -t|--portalToken) portalToken="$2"; shift ;;
        -p|--parameters) parameters="$2"; shift ;;
        -v|--verbose) verbose=1 ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

if [[ $verbose -eq 1 ]]
then
    echo "agent: $agent"
    echo "site: $site"
    echo "customer: $customer"
    echo "infrastructure: $infrastructure"
    echo "environmentType: $environmentType"
    echo "internetNetworkName: $internetNetworkName"
    echo "pat: $portalToken"
    echo "parameters: $parameters"
fi

curl -Os "$REPOSITORY/utils/portal/runInitializeInfrastructure.ps1"
pwsh -File ./runInitializeInfrastructure.ps1 -agent "$agent" -site "$site" -customer "$customer" -infrastructure "$infrastructure" -environmentType "$environmentType" -internetNetworkName "$internetNetworkName" -portalToken "$portalToken" -parameters "$parameters"
