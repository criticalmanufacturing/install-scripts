#!/bin/bash

set -e

mkdir -p /opt/fec
mkdir -p /var/lib/docker

# free -h
grep MemTotal /proc/meminfo

lscpu | grep "Core(s) per socket:"
lscpu | grep "CPU(s):"

df -PB G /var/lib/docker | awk 'FNR==2{print "/var/lib/docker: " $2}'
df -PB G /opt/fec | awk 'FNR==2{print "/opt/fec: " $2}'

echo; echo "#####################################"; echo;


requiredMemory=15728640
requiredCores=2
requiredLogicalProcessors=8
requiredDiskSpace=244140625

# free -h
grep MemTotal /proc/meminfo | awk -v val=$requiredMemory '{if($2+0 < val+0) print "Memory under required value: REQUIRED=" val "; AVAILABLE=" $2;}'

lscpu | grep "^Core(s) per socket:" | awk -v val=$requiredCores -F ':' '{gsub(/ /,"",$2); if($2+0 < val+0) print "CPUs under required value: REQUIRED=" val "; AVAILABLE=" $2;}'
lscpu | grep "^CPU(s):" | awk -v val=$requiredLogicalProcessors -F ':' '{gsub(/ /,"",$2); if($2+0 < val+0) print "Logical Processors under required value: REQUIRED=" val "; AVAILABLE=" $2;}'


df -P /var/lib/docker | awk -v val=$requiredDiskSpace 'FNR==2{if($2+0 < val+0) print "Disk space under required: REQUIRED=" val "; AVAILABLE=" $2;}'
df -P /opt/fec | awk -v val=$requiredDiskSpace 'FNR==2{if($2+0 < val+0) print "Disk space under required: REQUIRED=" val "; AVAILABLE=" $2;}'


testcon () {
    echo -n "$1 "
    status_code=$(curl --write-out %{http_code} --silent --output /dev/null "$1" || echo "")
    if [[ ("$status_code" == 2*) || ("$status_code" == 3*) ]]
    then
        echo "- OK ($status_code)"
    else
		echo "- Failed ($status_code)"
        #exit
    fi
}

echo "Testing connectivity"
testcon https://portal.criticalmanufacturing.com
testcon https://security.criticalmanufacturing.com
testcon https://criticalmanufacturing.io
testcon https://docker.io
testcon https://mcr.microsoft.com
testcon https://github.com
testcon https://raw.githubusercontent.com


read -rp "Check DB Collation? (y/n) " yn </dev/tty

case $yn in 
	y|yes ) echo "Continuing";;
	* ) echo "Skipping DB Collation check. Exiting...";
		exit 0;;
esac


if [ ! -f "/etc/os-release" ]; then
    echo "/etc/os-release doesn't exist, unable to detect distro"
    exit 1
fi


lsb_dist="$(. /etc/os-release && echo "$ID")"
lsb_dist="$(echo "$lsb_dist" | tr '[:upper:]' '[:lower:]')"
sqlcmd=/opt/mssql-tools/bin/sqlcmd

if [[ ! -f "$sqlcmd" ]]; then 
    case "$lsb_dist" in

        ubuntu|debian)
            echo "Starting environment preparation - $lsb_dist"
            curl https://packages.microsoft.com/keys/microsoft.asc | apt-key add -
            curl "https://packages.microsoft.com/config/$lsb_dist/$VERSION_ID/prod.list" | tee /etc/apt/sources.list.d/msprod.list
            apt-get update 
            apt-get install mssql-tools unixodbc-dev
        ;;
        rhel)
            curl "https://packages.microsoft.com/config/rhel/$ID/prod.repo" > /etc/yum.repos.d/msprod.repo
            yum install mssql-tools unixODBC-devel
        ;;
        *)
            echo "Checking DB collation is currently unsupported in distro $lsb_dist"
            exit 1
        ;;

    esac

fi

requiredCollation="Latin1_General_CI_AS"

read -rp 'MSSQL Server Instance: ' instance </dev/tty
read -rp 'MSSQL Server Username: ' username </dev/tty
read -rsp 'MSSQL Server Password: ' password </dev/tty

result=$( "$sqlcmd" -S "$instance" -U "$username" -P "$password" -Q "SELECT CONVERT (varchar, SERVERPROPERTY('collation')) as Collation")
echo "$result"
echo "$result" | awk -v val=$requiredCollation 'FNR==3{if($1 != val) print "Invalid collation: REQUIRED=" val "; AVAILABLE=" $1;}'



