#!/bin/bash

set -e

read -rp 'Scripts repository [https://raw.githubusercontent.com/migafgarcia/install-scripts/main-rhel-support]: ' REPOSITORY </dev/tty
export REPOSITORY=${REPOSITORY:-"https://raw.githubusercontent.com/migafgarcia/install-scripts/main-rhel-support"}


DATABASE_ADDRESS=""
read -rp 'Database Server Instance Name (leave empty if not required): ' DATABASE_ADDRESS </dev/tty
[[ -n "$DATABASE_ADDRESS" ]] && DATABASE_ARG="-DatabaseServerInstance $DATABASE_ADDRESS"

if command -v pwsh > /dev/null 2>&1; then
    wget -q "$REPOSITORY/equipmentcenter/SystemRequirementsChecker.ps1"
    wget -q "$REPOSITORY/equipmentcenter/packages/ByteSize.dll" -P ./packages
    wget -q "$REPOSITORY/equipmentcenter/packages/Hardware.Info.dll" -P ./packages
    pwsh -File ./SystemRequirementsChecker.ps1 "$DATABASE_ARG"
else
    echo "Powershell is not installed"
fi
