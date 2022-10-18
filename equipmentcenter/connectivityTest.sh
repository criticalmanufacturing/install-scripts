#!/bin/bash

set -e

testcon () {
    echo -n "$1 "
    status_code=$(curl --write-out %{http_code} --silent --output /dev/null $1 || echo "")
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
