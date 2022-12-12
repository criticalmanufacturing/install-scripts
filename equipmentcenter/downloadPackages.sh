#!/bin/bash

set -e

source ./configure.sh

sourceServer=https://criticalmanufacturing.io
sourceRepo=packages

version=${CMF_FEC_VERSION//\./\\\.}

## GET DOWNLOAD URLs
echo "Fetching FEC Packages list..."
tempFile=$(mktemp)

url=$sourceServer"/service/rest/v1/assets?repository="$sourceRepo
contToken="initial"

while [ -n "$contToken" ]; do
    if [ "$contToken" != "initial" ]; then
        url="$sourceServer/service/rest/v1/assets?continuationToken=$contToken&repository=$sourceRepo"
    fi
    response=$(curl -sSL -u "user:$CMF_PORTAL_TOKEN" -X GET --header 'Accept: application/json' "$url")
    echo "$response" | sed 's/"downloadUrl"/\n"downloadUrl"/g' | sed -n 's|.*"downloadUrl" : "\([^"]*\)".*|\1|p' >> "$tempFile"
    mapfile -t contToken < <(echo "$response" | sed -n 's|.*"continuationToken" : "\([^"]*\)".*|\1|p')
done

packages_filter="/$version/.*\\.zip$"
masterdata_filter="/$version/.*\\.xlsx$"
multimedia_filter="/Multimedia/.*\\.zip\\(\\.[0-9]\\+\\)$"

## DOWNLOAD ARTIFACTS
echo Downloading FEC packages...

download_artifacts () {
    mapfile -t urls < <(grep "$2" < "$1")
    mkdir -p "$3"
    for url in "${urls[@]}"; do
        echo Downloading "$url"
        wget --no-verbose --no-clobber -P "$3" --user "" --password "$CMF_PORTAL_TOKEN" "$url"
    done
}

download_artifacts "$tempFile" "$packages_filter" "$CMF_VOLUMES_BASE_FOLDER/packages"
download_artifacts "$tempFile" "$multimedia_filter" "$CMF_VOLUMES_BASE_FOLDER/multimedia"
download_artifacts "$tempFile" "$masterdata_filter" .

