#!/bin/bash
REPOSITORY="https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main"

#read arguments
while [ $# -gt 0 ]; do
  case "$1" in
    --password*l|-p*)
      if [[ "$1" != *=* ]]; then shift; fi
      portainerPassword="${1#*=}"
      ;;
    --securitytoken*|-s*)
      if [[ "$1" != *=* ]]; then shift; fi
      securityToken="${1#*=}"
      ;;
    *)
      >&2 printf "Error: Invalid argument\n"
      exit 1
      ;;
  esac
  shift
done

echo "PortainerPassword: $portainerPassword"
echo "SecurityToken: $securityToken"

#disable swap
swapoff -a
sed -i 's/\/swap.img/#\/swap.img/g' /etc/fstab

#install docker
curl -fsSL "$REPOSITORY/ubuntu/installDocker.bash" | bash;

# Install PowerShell
curl -fsSL "$REPOSITORY/ubuntu/20.04/installPowershell.bash" | bash;

#Deploy portainer
wget -q "$REPOSITORY/utils/deployPortainer.ps1"
pwsh -File ./deployPortainer.ps1 -RepositoryUrl $REPOSITORY -PortainerPassword "$portainerPassword"
