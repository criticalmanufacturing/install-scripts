#update system
zypper refresh
zypper update -y
#remove old docker version
zypper remove docker \
       docker-client \
       docker-client-latest \
       docker-common \
       docker-latest \
       docker-latest-logrotate \
       docker-logrotate \
       docker-engine \
       runc

#install utils
zypper install -y wget ca-certificates curl apache2-utils

#install SUSE Connect
#check SP 3
SUSEConnect -p sle-module-containers/15.3/x86_64 -r ''

#install DOCKER CE
zypper install -y docker
systemctl enable docker.service
systemctl start docker.service

#install Docker Compose V2
mkdir -p ~/.docker/cli-plugins/
curl -SL https://github.com/docker/compose/releases/download/v2.2.3/docker-compose-linux-x86_64 -o ~/.docker/cli-plugins/docker-compose
chmod +x ~/.docker/cli-plugins/docker-compose
#change docker default log policy
echo "{
    \"log-driver\": \"json-file\",
    \"log-opts\": {
        \"max-size\": \"10m\",
        \"max-file\": \"5\"
    }
}" > /etc/docker/daemon.json

if [[ $(grep WSL /proc/version) ]]; 
then
	echo "Bash is running on WSL"
	# Start Docker daemon automatically when logging in if not running.
	RUNNING=`ps aux | grep dockerd | grep -v grep`
	if [ -z "$RUNNING" ]; 
	then
		echo "Staring dockerd"
		sudo dockerd > /dev/null 2>&1 & disown
	fi
else
	#reload docker config
	systemctl reload docker
fi