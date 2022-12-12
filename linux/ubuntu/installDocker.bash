#!/bin/bash
set -e

#update system
apt update -y -qq

. /etc/os-release

#install utils
apt-get install wget apt-transport-https ca-certificates curl gnupg-agent software-properties-common apache2-utils -qq -y


#install DOCKER CE
curl -fsSL https://download.docker.com/linux/$ID/gpg | sudo apt-key add -
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/$ID $VERSION_CODENAME stable"
apt update -y -qq
apt-get install docker-ce docker-ce-cli containerd.io docker-compose-plugin -y -qq