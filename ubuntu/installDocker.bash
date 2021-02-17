#update system
apt -qq update -y && apt -qq upgrade -y
#remove old docker version
apt-get -qq remove docker docker-engine docker.io containerd runc
#install utils
apt-get -qq install wget apt-transport-https ca-certificates curl gnupg-agent software-properties-common apache2-utils -y
#install DOCKER CE
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
apt -qq update -y
apt-get -qq install docker-ce docker-ce-cli containerd.io -y
apt -qq update -y
apt -qq upgrade -y
#change docker default log policy
echo "{
    \"log-driver\": \"json-file\",
    \"log-opts\": {
        \"max-size\": \"10m\",
        \"max-file\": \"5\"
    }
}" > /etc/docker/daemon.json
#reload docker config
systemctl reload docker