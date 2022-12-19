# FEC Install Scripts
Scripts to setup a single machine for installing FEC.


Before beggining you will need to have ***curl*** installed.

## [checkEnvironment.sh](https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main/equipmentcenter/checkEnvironment.sh "checkEnvironment.sh")

This script validates if the Linux environment is suitable for deploying FEC.

```
curl -fsSL https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main/equipmentcenter/checkEnvironment.sh | sudo bash
```


## [downloadPackages.sh](https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main/equipmentCenter/downloadPackages.sh "downloadPackages.sh")

This scripts downloads the FEC packages from the Critical Manufacturing repositories.

```
curl -fsSL https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main/equipmentcenter/downloadPackages.sh | sudo bash
```


## [install.sh](https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main/equipmentCenter/install.sh "install.sh")

This script installs the necessary dependencies (Docker, Powershell, Portainer), creates a Customer Infrastructure and deploys the Infrastructure Agent.

```
curl -fsSL https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main/install.sh | sudo bash
```


