#!/bin/bash

set -e

## ======== PARAMETERS ========

read -p 'Infrastructure Name: ' infrastructure </dev/tty
read -p 'Agent Name: ' agent </dev/tty
#read -p 'License: ' license </dev/tty
read -p 'Customer: ' customer </dev/tty
read -sp 'Customer Portal Token: ' portalToken </dev/tty
if [[ ${#portalToken} -lt 300 ]]
then
    echo "Error: Token is to short (${#portalToken})"
    exit
fi

partialToken="${portalToken:0: -4}"
echo "${partialToken//?/*}${portalToken: -4}"

read -p 'Environment Type (Testing/Production/Staging/Development) [Production]: ' environmentType </dev/tty
environmentType=${environmentType:-Production}

read -p 'Internet Network Name [internet]:' internetNetworkName </dev/tty
internetNetworkName=${internetNetworkName:-internet}

read -p 'Agent Parameters: ' parameters </dev/tty

read -p 'Volumes base folder [/opt/fec]: ' BASE_FOLDER </dev/tty
BASE_FOLDER=${BASE_FOLDER:-/opt/fec}

# Script Repository
read -p 'Scripts repository [https://raw.githubusercontent.com/migafgarcia/install-scripts/main-rhel-support]: ' REPOSITORY </dev/tty
export REPOSITORY=${REPOSITORY:-"https://raw.githubusercontent.com/migafgarcia/install-scripts/main-rhel-support"}
read -p 'Scripts repository user: ' REPOSITORY_USER </dev/tty
export REPOSITORY_USER=${REPOSITORY_USER:-""}
read -sp 'Scripts repository password: ' REPOSITORY_PASSWORD </dev/tty
export REPOSITORY_PASSWORD=${REPOSITORY_PASSWORD:-""}
echo

# Portal SDK
read -p 'Portal SDK Base URL (empty if not to override): ' SDK_BASE_URL </dev/tty
export SDK_BASE_URL=${SDK_BASE_URL:-""}
read -p 'Portal SDK TAG (empty if not to override/latest): ' SDK_TAG </dev/tty
export SDK_TAG=${SDK_TAG:-""}

## ======== INSTALL DOCKER AND PORTAINER ========
echo
echo "Installing Container Dependencies (Docker, Portainer, etc)"
curl -fsSL -u $REPOSITORY_USER:$REPOSITORY_PASSWORD $REPOSITORY/linux/install.sh | bash

## ======== CREATE INFRASTRUCTURE AND AGENT ========
echo
echo "Creating Infrastructure and Deploying Agent"

# parameters=agent_params.json

# echo "{
#     \"INTERNET_NETWORK\": \"$internetNetworkName\"
# }" > $parameters

curl -fsSL -u $REPOSITORY_USER:$REPOSITORY_PASSWORD $REPOSITORY/linux/portal/initializeInfrastructure.bash | bash -s -- --agent "$agent" --customer "$customer" --infrastructure "$infrastructure" --environmentType "$environmentType" --internetNetworkName "$internetNetworkName" --portalToken "$portalToken" --parameters "$parameters"

## ======== CREATE VOLUMES FOLDERS ========
echo; echo "Creating volume folders"
mkdir -p $BASE_FOLDER/packages
mkdir -p $BASE_FOLDER/mssql
mkdir -p $BASE_FOLDER/documents
#mkdir -p $BASE_FOLDER/attachments
mkdir -p $BASE_FOLDER/logs
mkdir -p $BASE_FOLDER/multimedia
