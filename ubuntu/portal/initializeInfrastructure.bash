#!/bin/bash

REPOSITORY="https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/linux-infrasctucture"

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -a|--agent) agent="$2"; shift ;;
        -l|--license) license="$2"; shift ;;
        -s|--site) site="$2"; shift ;;
        -i|--infrastructure) infrastructure="$2"; shift ;;
        -s|--domain) domain="$2"; shift ;;
        -e|--environmentType) environmentType="$2"; shift ;;
        -n|--internetNetworkName) internetNetworkName="$2"; shift ;;
        -t|--portalToken) portalToken="$2"; shift ;;
        -v|--verbose) verbose=1 ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

if [[ $verbose -eq 1 ]]
then
    echo "agent: $agent"
    echo "license: $license"
    echo "site: $site"
    echo "infrastructure: $infrastructure"
    echo "domain: $domain"
    echo "environmentType: $environmentType"
    echo "internetNetworkName: $internetNetworkName"
    echo "pat: $portalToken"
fi

curl -Os "https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/linux-infrasctucture/utils/portal/initializeInfrastructure.ps1"
pwsh -File ./initializeInfrastructure.ps1 -agent "$agent" -license "$license" -site "$site" -infrastructure "$infrastructure" -domain "$domain" -environmentType "$environmentType" -internetNetworkName "$internetNetworkName" -portalToken "$portalToken"




