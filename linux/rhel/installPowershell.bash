#!/bin/bash
set -e

# Register the Microsoft RedHat repository
curl https://packages.microsoft.com/config/rhel/8/prod.repo | tee /etc/yum.repos.d/microsoft.repo

# Install PowerShell
dnf install -y powershell