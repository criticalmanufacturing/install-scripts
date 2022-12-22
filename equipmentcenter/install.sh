#!/bin/bash

set -e

## ======== PARAMETERS ========
REPOSITORY=${REPOSITORY:-"https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main"}
source <( curl -fsSL "$REPOSITORY/equipmentcenter/configure.sh" )

## ======== INSTALL DOCKER AND PORTAINER ========
echo; echo "Installing Container Dependencies (Docker, Powershell, Portainer)"
curl -fsSL "$REPOSITORY/linux/install.sh" | bash

## ======== INSTALL 7z ========
echo; echo "Installing Additional Packages (7z)"
curl -fsSL "$REPOSITORY/equipmentcenter/installAdditionalPackages.sh" | bash

## ======== CREATE INFRASTRUCTURE AND AGENT ========
echo; echo "Creating Infrastructure and Deploying Agent"

parameters=agent_params.json

agent="$CMF_CUSTOMER_AGENT"
customer="$CMF_CUSTOMER"
infrastructure="$CMF_CUSTOMER_INFRASTRUCTURE"
environmentType="$CMF_ENVIRONMENT_TYPE"
internetNetworkName="$CMF_INTERNET_NETWORK_NAME"
portalToken="$CMF_PORTAL_TOKEN"
echo "{
    \"INTERNET_NETWORK\": \"$internetNetworkName\"
}" > $parameters

curl -fsSL "$REPOSITORY/linux/portal/initializeInfrastructure.bash" | bash -s -- --agent "$agent" --customer "$customer" --infrastructure "$infrastructure" --environmentType "$environmentType" --internetNetworkName "$internetNetworkName" --portalToken "$portalToken" --parameters "$parameters"

## ======== CREATE VOLUMES FOLDERS ========
echo; echo "Creating volume folders"
mkdir -p "$CMF_VOLUMES_BASE_FOLDER/packages"
mkdir -p "$CMF_VOLUMES_BASE_FOLDER/mssql"
mkdir -p "$CMF_VOLUMES_BASE_FOLDER/documents"
mkdir -p "$CMF_VOLUMES_BASE_FOLDER/logs"
mkdir -p "$CMF_VOLUMES_BASE_FOLDER/multimedia"
