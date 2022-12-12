#!/bin/bash

configure_variable () {
    if [ -z "${!2}" ]
    then
        read -rp "$1: " "$2" </dev/tty
        if [ -z "${!2}" ]
        then
            echo "$1 not provided"
            exit 1
        fi
        export "$2=${!2}"
    else
        echo "$1 = ${!2}"
    fi
}

configure_variable_with_default () {
    if [ -z "${!3}" ]
    then
        read -rp "$1 [$2]: " "$3" </dev/tty
        export "$3"="${!3:-$2}"
    else
        echo "$1 = ${!3}"
    fi
}

file=./configuration.txt

if [ -f $file ]; then
    source $file
fi

configure_variable "Infrastructure Name" CMF_CUSTOMER_INFRASTRUCTURE
configure_variable_with_default "Agent Name" "$CMF_CUSTOMER_INFRASTRUCTURE Agent" CMF_CUSTOMER_AGENT
configure_variable "Customer" CMF_CUSTOMER
configure_variable "FEC Version" CMF_FEC_VERSION
configure_variable "Customer Portal Token" CMF_PORTAL_TOKEN
configure_variable_with_default "Environment Type (Testing/Production/Staging/Development)" Production CMF_ENVIRONMENT_TYPE
configure_variable_with_default "Internet Network Name" internet CMF_INTERNET_NETWORK_NAME
configure_variable_with_default "Volumes base folder"  /opt/fec CMF_VOLUMES_BASE_FOLDER

# read -rp "Continue? (yes/no) " yn

# case $yn in 
# 	yes ) echo "Continuing";;
# 	no ) echo "Exiting ...";
# 		exit;;
# 	* ) echo "Please answer yes or no";
# 		exit 1;;
# esac

echo; echo "Configuration saved to $file. To configure again, delete the file."; echo;

echo "CMF_ENVIRONMENT_TYPE=\"$CMF_ENVIRONMENT_TYPE\"
CMF_INTERNET_NETWORK_NAME=\"$CMF_INTERNET_NETWORK_NAME\"
CMF_PORTAL_TOKEN=\"$CMF_PORTAL_TOKEN\"
CMF_CUSTOMER=\"$CMF_CUSTOMER\"
CMF_CUSTOMER_INFRASTRUCTURE=\"$CMF_CUSTOMER_INFRASTRUCTURE\"
CMF_CUSTOMER_AGENT=\"$CMF_CUSTOMER_AGENT\"
CMF_VOLUMES_BASE_FOLDER=\"$CMF_VOLUMES_BASE_FOLDER\"
CMF_FEC_VERSION=\"$CMF_FEC_VERSION\"" > $file