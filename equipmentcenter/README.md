# FEC Install Scripts
Scripts to setup a single machine for installing FEC.


Before beggining you will need to have ***cURL*** installed.

## [connectivityTest.sh](https://github.com/migafgarcia/install-scripts/blob/feature/main-rhel-support/equipmentCenter/checkEnvironment.sh "checkEnvironment.sh")

This script validates if the Linux environment is suitable for deploying FEC.

```
curl -fsSL https://raw.githubusercontent.com/migafgarcia/install-scripts/main-rhel-support/equipmentcenter/checkEnvironment.sh | sudo bash
```



## [downloadPackages.sh](https://github.com/migafgarcia/install-scripts/blob/feature/main-rhel-support/equipmentCenter/downloadPackages.sh "downloadPackages.sh")

This scripts downloads the FEC packages from the Critical Manufacturing repositories.

```
curl -fsSL https://raw.githubusercontent.com/migafgarcia/install-scripts/main-rhel-support/equipmentcenter/downloadPackages.sh | sudo bash
```


## [install.sh](https://github.com/migafgarcia/install-scripts/blob/feature/main-rhel-support/equipmentCenter/install.sh "install.sh")

This script installs the necessary dependencies (Docker, Powershell, Portainer), creates a Customer Infrastructure and deploys the Infrastructure Agent.

```
curl -fsSL https://raw.githubusercontent.com/migafgarcia/install-scripts/main-rhel-support/equipmentcenter/install.sh | sudo bash
```


