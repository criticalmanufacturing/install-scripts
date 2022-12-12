#!/bin/bash

set -e

source ./configure.sh

## ======== PARAMETERS ========
curl -fsSL -u $REPOSITORY_USER:$REPOSITORY_PASSWORD $REPOSITORY/linux/install.sh | bash


## ======== INSTALL DOCKER AND PORTAINER ========
echo
echo "Installing Container Dependencies (Docker, Portainer, etc)"
curl -fsSL -u $REPOSITORY_USER:$REPOSITORY_PASSWORD $REPOSITORY/linux/install.sh | bash

## ======== CREATE INFRASTRUCTURE AND AGENT ========
echo
echo "Creating Infrastructure and Deploying Agent"

parameters=agent_params.json

echo "{
    \"INTERNET_NETWORK\": \"$internetNetworkName\"
}" > $parameters

curl -fsSL -u $REPOSITORY_USER:$REPOSITORY_PASSWORD $REPOSITORY/linux/portal/initializeInfrastructure.bash | bash -s -- --agent "$agent" --customer "$customer" --infrastructure "$infrastructure" --environmentType "$environmentType" --internetNetworkName "$internetNetworkName" --portalToken "$portalToken" --parameters "$parameters"

## ======== CREATE VOLUMES FOLDERS ========
echo; echo "Creating volume folders"
mkdir -p $BASE_FOLDER/packages
mkdir -p $BASE_FOLDER/mssql
mkdir -p $BASE_FOLDER/documents
mkdir -p $BASE_FOLDER/logs
mkdir -p $BASE_FOLDER/multimedia
