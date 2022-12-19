#!/bin/bash
set -e

REPOSITORY=${REPOSITORY:-"https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main"}

command_exists() {
	command -v "$@" > /dev/null 2>&1
}

is_wsl() {
	case "$(uname -r)" in
	*microsoft* ) true ;; # WSL 2
	*Microsoft* ) true ;; # WSL 1
	* ) false;;
	esac
}

if [ ! -f "/etc/os-release" ]; then
    echo "/etc/os-release doesn't exist, unable to detect distro"
    exit 1
fi

lsb_dist="$(. /etc/os-release && echo "$ID")"
lsb_dist="$(echo "$lsb_dist" | tr '[:upper:]' '[:lower:]')"

case "$lsb_dist" in

    ubuntu|debian|rhel)
        echo "Starting environment preparation - $lsb_dist"
    ;;

    *)
        echo "Unsupported distro $lsb_dist"
        exit 1
    ;;

esac

# for debian use the ubuntu scripts
if [ "$lsb_dist" = "debian" ]; then
    lsb_dist=ubuntu
fi

curl -fsSL "$REPOSITORY"/linux/"$lsb_dist"/installOthers.bash | bash

if ! command_exists docker; then
    curl -fsSL "$REPOSITORY"/linux/"$lsb_dist"/installDocker.bash | bash
fi

if ! command_exists pwsh; then
    curl -fsSL "$REPOSITORY"/linux/"$lsb_dist"/installPowershell.bash | bash
fi

echo "# Changing docker default log policy"

if [[ ! -f "/etc/docker/daemon.json" ||  -s "/etc/docker/daemon.json" ]]; then
    # ensure file and folder exists
    mkdir -p /etc/docker
    touch -a /etc/docker/daemon.json

    echo "{
        \"log-driver\": \"json-file\",
        \"log-opts\": {
            \"max-size\": \"10m\",
            \"max-file\": \"5\"
        }
    }" > /etc/docker/daemon.json

fi


if is_wsl;
then
        echo "Bash is running on WSL"
        # Start Docker daemon automatically when logging in if not running.
        RUNNING=$(pgrep dockerd)
        if [ -z "$RUNNING" ];
        then
                echo "Staring dockerd"
                sudo dockerd > /dev/null 2>&1 & disown
        fi
else
        echo "# Enabling and starting docker service"
        systemctl enable docker
        systemctl start docker

        #reload docker config
        systemctl reload docker
fi


#Deploy portainer
if ! docker ps -a | grep -q portainer; then
    wget -q "$REPOSITORY/utils/deployPortainer.ps1"
    pwsh -File ./deployPortainer.ps1 -RepositoryUrl "$REPOSITORY"
    rm -f deployPortainer.ps1
fi




