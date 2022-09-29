#!/bin/bash
set -e

#update system
apt update -y -qq
apt upgrade -y -qq
. /etc/os-release
#remove old docker version
apt-get remove docker docker-engine docker.io containerd runc -qq -y
#install utils
apt-get install wget apt-transport-https ca-certificates curl gnupg-agent software-properties-common apache2-utils -qq -y
#install DOCKER CE
curl -fsSL https://download.docker.com/linux/$ID/gpg | sudo apt-key add -
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/$ID $VERSION_CODENAME stable"
apt update -y -qq
apt-get install docker-ce docker-ce-cli containerd.io -y -qq
apt update -y -qq
apt upgrade -y -qq
#install Docker Compose V2
mkdir -p ~/.docker/cli-plugins/
curl -SL https://github.com/docker/compose/releases/download/v2.2.3/docker-compose-linux-x86_64 -o ~/.docker/cli-plugins/docker-compose
chmod +x ~/.docker/cli-plugins/docker-compose
