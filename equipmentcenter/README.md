# FEC Install Scripts
Scripts to setup a single machine for installing FEC.


Before beggining you will need to have ***cURL*** installed.

## [connectivityTest.sh](https://github.com/Filipecordeiro/install-scripts/blob/feature/fecWithRepoConfigurable/equipmentCenter/connectivityTest.sh "connectivityTest.sh")

This script validates if the necessary addresses are reachable.

```
curl -fsSL https://raw.githubusercontent.com/migafgarcia/install-scripts/main-rhel-support/equipmentcenter/connectivityTest.sh | sudo bash
```



## [downloadPackages.sh](https://github.com/Filipecordeiro/install-scripts/blob/feature/fecWithRepoConfigurable/equipmentCenter/downloadPackages.sh "downloadPackages.sh")

This scripts downloads the FEC packages from the Critical Manufacturing repositories.

```
curl -fsSL https://raw.githubusercontent.com/migafgarcia/install-scripts/main-rhel-support/equipmentcenter/downloadPackages.sh | sudo bash
```


## [install.sh](https://github.com/Filipecordeiro/install-scripts/blob/feature/fecWithRepoConfigurable/equipmentCenter/install.sh "install.sh")

This script installs the necessary dependencies (Docker, Powershell, Portainer), creates a Customer Infrastructure and deploys the Infrastructure Agent.

```
curl -fsSL https://raw.githubusercontent.com/migafgarcia/install-scripts/main-rhel-support/equipmentcenter/install.sh | sudo bash
```


