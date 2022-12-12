#!/bin/bash

set -e

## ======== DOWNLOAD FEC PACKAGES =========

sourceServer=https://criticalmanufacturing.io
sourceRepo=packages

read -rp 'Nexus Repository [https://criticalmanufacturing.io]: ' sourceServer </dev/tty
export sourceServer=${sourceServer:-"https://criticalmanufacturing.io"}

read -p 'Nexus Username: ' portalUser </dev/tty

read -sp 'Nexus Password: ' portaltoken </dev/tty
echo "${portaltoken//?/*}"
read -p 'FEC Packages version: ' version </dev/tty
version=$(echo "$version" | sed 's/\./\\\./g')

read -p 'Packages destination folder [/opt/fec/packages]: ' BASE_FOLDER </dev/tty
BASE_FOLDER=${BASE_FOLDER:-/opt/fec/packages}
mkdir -p $BASE_FOLDER

filters=("/$version/.*\\.zip\\(\\.[0-9]\\+\\)\\?$" "/$version/.*\\.xlsx$") #*.zip or *.zip.xxx or *.xlsx

logfile=$sourceRepo-backup.log
outputFile=$sourceRepo-artifacts.txt
tempFile=$sourceRepo-artifacts.temp

rm -f $outputFile

## GET DOWNLOAD URLs
echo "Fetching FEC Packages list..."

url=$sourceServer"/service/rest/v1/assets?repository="$sourceRepo
contToken="initial"
while [ -n "$contToken" ]; do
    if [ "$contToken" != "initial" ]; then
        url="$sourceServer/service/rest/v1/assets?continuationToken=$contToken&repository=$sourceRepo"
    fi
    echo Processing repository token: $contToken >> $logfile
    response=$(curl -ksSL -u "$portalUser:$portaltoken" -X GET --header 'Accept: application/json' "$url")
    echo "$response" | sed 's/"downloadUrl"/\n"downloadUrl"/g' | sed -n 's|.*"downloadUrl" : "\([^"]*\)".*|\1|p' > $tempFile
    for filter in "${filters[@]}"; do
        cat $tempFile | grep "$filter" >> $outputFile || true
    done
    contToken=( $(echo $response | sed -n 's|.*"continuationToken" : "\([^"]*\)".*|\1|p') )
done

curFolder=$(pwd)

## DOWNLOAD ARTIFACTS
echo Downloading FEC packages...
urls=($(cat $outputFile)) > /dev/null 2>&1
#echo "Urls: "${urls[@]}
IFS=$'\n' urls=($(sort <<<"${urls[*]}")); unset IFS
#echo "Sorted: "${urls[@]}

for url in "${urls[@]}"; do
    dir=$BASE_FOLDER"/"
    mkdir -p $dir
    cd $dir

    echo Downloading $url
    curl -k --progress-bar -u "$portalUser:$portaltoken" -D response.header -X GET "$url" -O
    responseCode=$(cat response.header | sed -n '1p' | cut -d' ' -f2)
    if [ "$responseCode" == "200" ]; then
        echo " - DONE"
    else
        echo " - ERROR"
        echo ERROR: Failed to download artifact: $url with error code: $responseCode 
    fi
    rm response.header > /dev/null 2>&1
    
    cd $curFolder
done
