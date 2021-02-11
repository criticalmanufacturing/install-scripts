#update system
apt update -y
apt upgrade -y

#remove old docker version
apt-get remove docker docker-engine docker.io containerd runc

#install utils
apt-get install wget apt-transport-https ca-certificates curl gnupg-agent software-properties-common apache2-utils -y

#install DOCKER CE
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
apt update -y
apt-get install docker-ce docker-ce-cli containerd.io -y
apt update -y
apt upgrade -y

#change docker default log policy
echo "{
    \"log-driver\": \"json-file\",
    \"log-opts\": {
        \"max-size\": \"10m\",
        \"max-file\": \"5\"
    }
}" > /etc/docker/daemon.json

docker swarm update --task-history-limit=3
systemctl reload docker

#init docker swarm cluster
docker swarm init
docker swarm update --task-history-limit 3