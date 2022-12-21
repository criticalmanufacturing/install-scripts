#!/bin/bash
set -e

REPOSITORY=${REPOSITORY:-"https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main"}

command_exists() {
	command -v "$@" > /dev/null 2>&1
}

if [ ! -f "/etc/os-release" ]; then
    echo "/etc/os-release doesn't exist, unable to detect distro"
    exit 1
fi

lsb_dist="$(. /etc/os-release && echo "$ID")"
lsb_dist="$(echo "$lsb_dist" | tr '[:upper:]' '[:lower:]')"

case "$lsb_dist" in

    ubuntu|debian)
        echo "Installing additional packages - $lsb_dist"
        if ! command_exists 7z; then
            apt-get install -y p7zip-full
        fi
    ;;


    rhel)
        echo "Installing additional packages - $lsb_dist"
        if ! command_exists 7z; then
            dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm
            dnf install -y p7zip p7zip-plugins
        fi
    ;;
    
    *)
        echo "Unsupported distro $lsb_dist"
        exit 1
    ;;

esac






