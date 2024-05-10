#!/bin/bash

directory="/var/lib/microshift/resources/kubeadmin"

# Loop until the directory is created
while [ ! -d "$directory" ]; do
    echo "Waiting for $directory to be created..."
    sleep 1  
done

echo "$directory has been created."

while [ -z "$HOST_IP" ]; do
  HOST_IP="https://cmos-cmos.apps.$(ip addr show $(ip link | grep DEFAULT | grep -v 'ovn\|br\|cni\|ovs\|lo' | awk '{print $2}' | tr -d ':') | grep -oP 'inet \K[\d.]+').nip.io"
  sleep 1 
done

export HOST_IP

# echo "Detected Host IP: $HOST_IP"

# /usr/bin/podman run --security-opt label:disable --env HOST_IP="$HOST_IP" --env PYTHONUNBUFFERED=1 -v /var/tmp/:/var/tmp/ -v /usr/share:/usr/share -v /var/lib/microshift/resources/kubeadmin:/var/lib/microshift/resources/kubeadmin -p 8080:8080 quay.io/luisarizmendi/kiosk-token:latest

echo "    _    ____  ____    ____  _        _  _____ _____ ___  ____  __  __ "
echo "   / \  |  _ \|  _ \  |  _ \| |      / \|_   _|  ___/ _ \|  _ \|  \/  |"
echo "  / _ \ | |_) | |_) | | |_) | |     / _ \ | | | |_ | | | | |_) | |\/| |"
echo " / ___ \|  __/|  __/  |  __/| |___ / ___ \| | |  _|| |_| |  _ <| |  | |"
echo "/_/   \_\_|   |_|     |_|   |_____/_/   \_\_| |_|   \___/|_| \_\_|  |_|"
echo ""
echo "Open $HOST_IP to continue the installation process"