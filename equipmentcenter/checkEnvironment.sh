#!/bin/bash

set -e
if ! command -v "pwsh" > /dev/null 2>&1; then
    wget -q "$REPOSITORY/equipmentcenter/SystemRequirementsChecker.ps1"
    pwsh -File ./SystemRequirementsChecker.ps1
else
    echo "Powershell is not installed"
fi
