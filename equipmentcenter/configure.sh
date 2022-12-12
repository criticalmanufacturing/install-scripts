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



echo "##################################################################"
echo "Configuration saved to $file. To configure again, delete the file."
echo "##################################################################"


# read -rp "Advanced mode? () (yes/no) " yn

# case $yn in 
# 	yes ) echo "Continuing";;
# 	no ) echo "Exiting ...";
# 		exit;;
# 	* ) echo "Please answer yes or no";
# 		exit 1;;
# esac


# read -rp "Do you want to proceed? (yes/no) " yn

# case $yn in 
# 	yes ) echo "Continuing";;
# 	no ) echo "Exiting ...";
# 		exit;;
# 	* ) echo "Please answer yes or no";
# 		exit 1;;
# esac


# # Script Repository
# read -p 'Scripts repository [https://raw.githubusercontent.com/migafgarcia/install-scripts/main-rhel-support]: ' REPOSITORY </dev/tty
# export REPOSITORY=${REPOSITORY:-"https://raw.githubusercontent.com/migafgarcia/install-scripts/main-rhel-support"}
# read -p 'Scripts repository user: ' REPOSITORY_USER </dev/tty
# export REPOSITORY_USER=${REPOSITORY_USER:-""}
# read -sp 'Scripts repository password: ' REPOSITORY_PASSWORD </dev/tty
# export REPOSITORY_PASSWORD=${REPOSITORY_PASSWORD:-""}
# echo

# # Portal SDK
# read -p 'Portal SDK Base URL (empty if not to override): ' SDK_BASE_URL </dev/tty
# export SDK_BASE_URL=${SDK_BASE_URL:-""}
# read -p 'Portal SDK TAG (empty if not to override/latest): ' SDK_TAG </dev/tty
# export SDK_TAG=${SDK_TAG:-""}


echo "CMF_ENVIRONMENT_TYPE=\"$CMF_ENVIRONMENT_TYPE\"
CMF_INTERNET_NETWORK_NAME=\"$CMF_INTERNET_NETWORK_NAME\"
CMF_PORTAL_TOKEN=\"$CMF_PORTAL_TOKEN\"
CMF_CUSTOMER=\"$CMF_CUSTOMER\"
CMF_CUSTOMER_INFRASTRUCTURE=\"$CMF_CUSTOMER_INFRASTRUCTURE\"
CMF_CUSTOMER_AGENT=\"$CMF_CUSTOMER_AGENT\"
CMF_VOLUMES_BASE_FOLDER=\"$CMF_VOLUMES_BASE_FOLDER\"
CMF_FEC_VERSION=\"$CMF_FEC_VERSION\"" > $file