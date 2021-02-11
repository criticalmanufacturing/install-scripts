#!/bin/bash
$portainerPassword = ""

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

if [[ $portainerPassword = "" ]]
then
  #password is empty -> let's generate a new one
  response=`curl 'https://passwordsgenerator.net/calc.php?Length=16&Symbols=1&Lowercase=1&Uppercase=1&Numbers=1&Nosimilar=1&Last=1317'`
  portainerPassword=${response:0:16}
fi

echo "PortainerPassword: $portainerPassword"
echo "SecurityToken: $securityToken"
#disable swap
swapoff -a
sed -i 's/\/swap.img/#\/swap.img/g' /etc/fstab

#install docker
curl -L https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main/ubuntu/installDocker.bash | bash

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
rm -f packages-microsoft-prod.deb

# Start PowerShell
wget -q https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main/utils/createPortainerStack.ps1
pwsh ./createPortainerStack.ps1 -StackName portainer -PortainerUser admin -PortainerPassword qaz123WSX -StackFileName ./portainer-agent-stack.yml
rm -f createPortainerStack.ps1 portainer-agent-stack.yml

#output
echo "#####################################"
echo " Portainer is running:             "
echo ""
echo " Url:       http://localhost:9000  "
echo " User:      admin                  "
echo " Password:  $portainerPassword"
echo "#####################################"