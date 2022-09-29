#!/bin/bash
set -e

. /etc/os-release

# Register the Microsoft RedHat repository
curl https://packages.microsoft.com/config/rhel/$VERSION_ID/prod.repo | sudo tee /etc/yum.repos.d/microsoft.repo

# Install PowerShell
dnf install --assumeyes powershell
