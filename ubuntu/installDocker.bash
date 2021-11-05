#update system
apt update -y -qq
apt upgrade -y -qq
#remove old docker version
apt-get remove docker docker-engine docker.io containerd runc -qq -y
#install utils
apt-get install wget apt-transport-https ca-certificates curl gnupg-agent software-properties-common apache2-utils -qq -y
#install DOCKER CE
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
apt update -y -qq 
apt-get install docker-ce docker-ce-cli containerd.io -y -qq
apt update -y -qq
apt upgrade -y -qq
#change docker default log policy
echo "{
    \"log-driver\": \"json-file\",
    \"log-opts\": {
        \"max-size\": \"10m\",
        \"max-file\": \"5\"
    }
}" > /etc/docker/daemon.json

if [[ $(grep Microsoft /proc/version) ]]; 
then
	echo "Bash is running on WSL"
	# Start Docker daemon automatically when logging in if not running.
	RUNNING=`ps aux | grep dockerd | grep -v grep`
	if [ -z "$RUNNING" ]; then
		sudo dockerd > /dev/null 2>&1 &
		disown
	fi
else
	#reload docker config
	systemctl reload docker
fi


