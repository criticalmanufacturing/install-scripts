#!/bin/bash
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
curl -L https://github.com/criticalmanufacturing/install-scripts/ubuntu/installDocker.bash | bash

#init docker swarm cluster
docker swarm init
docker swarm update --task-history-limit 3
 
curl -L https://downloads.portainer.io/portainer-agent-stack.yml -o portainer-agent-stack.yml
hashedPassword=$(htpasswd -nbB admin $portainerPassword | cut -d ":" -f 2 | sed 's+\$+$$+g' )
pattern='s+\-\-tlsskipverify+--admin-password '$hashedPassword' --tlsskipverify+g'
sed -i "$pattern" portainer-agent-stack.yml
docker stack deploy -c portainer-agent-stack.yml portainer
 
# Install powershell
wget -q https://packages.microsoft.com/config/ubuntu/20.04/packages-microsoft-prod.deb
dpkg -i packages-microsoft-prod.deb
apt-get update -y
add-apt-repository universe
apt-get install -y powershell

# Start PowerShell
wget -q https://github.com/criticalmanufacturing/install-scripts/utils/createPortainerStack.ps1
pwsh ./createPortainerStack.ps1 -StackName portainer -PortainerUser admin -PortainerPassword qaz123WSX -StackFileName ./portainer-agent-stack.yml
rm -f createPortainerStack.ps1 