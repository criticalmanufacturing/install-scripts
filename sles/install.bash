#!/bin/bash
REPOSITORY="https://raw.githubusercontent.com/joaoopereira/install-scripts/development-add-sles-scripts"

#disable swap
swapoff -a
sed -i 's/\/swap.img/#\/swap.img/g' /etc/fstab

#install docker
curl -fsSL "$REPOSITORY/sles/installDocker.bash" | bash;

# Install PowerShell
curl -fsSL "$REPOSITORY/sles/installPowershell.bash" | bash;

#Deploy portainer
wget -q "$REPOSITORY/utils/deployPortainer.ps1"
pwsh -File ./deployPortainer.ps1 -RepositoryUrl $REPOSITORY
rm -f deployPortainer.ps1
