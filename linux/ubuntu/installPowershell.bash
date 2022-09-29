#!/bin/bash
set -e

# Install powershell
. /etc/os-release
wget -q https://packages.microsoft.com/config/$ID/$VERSION_ID/packages-microsoft-prod.deb
dpkg -i packages-microsoft-prod.deb
apt-get update -y
add-apt-repository universe
apt-get install -y powershell
rm -f packages-microsoft-prod.deb