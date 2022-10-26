#!/bin/bash

set -e

read -p 'Scripts repository [https://raw.githubusercontent.com/migafgarcia/install-scripts/main-rhel-support]: ' REPOSITORY </dev/tty
export REPOSITORY=${REPOSITORY:-"https://raw.githubusercontent.com/migafgarcia/install-scripts/main-rhel-support"}

if command -v pwsh > /dev/null 2>&1; then
    wget -q "$REPOSITORY/equipmentcenter/SystemRequirementsChecker.ps1"
    pwsh -File ./SystemRequirementsChecker.ps1
else
    echo "Powershell is not installed"
fi
