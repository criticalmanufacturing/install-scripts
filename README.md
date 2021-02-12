# install-scripts
Critical Manufacturing Installation Scripts

## Prepare single server Ubuntu 20.04 environment

```
curl -fsSL https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main/ubuntu/20.04/install.bash | bash
```

Using a custom admin password for Portainer

```
curl -fsSL https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main/ubuntu/20.04/install.bash | bash -s -- -password <custom password>
```
## Prepare Windows environment

The installation assumes that docker is installed and running.

Using Command Line

```
curl -fsSL https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main/windows/install.ps1 | powershell -File -
```
Using Powershell

```powershell
(Invoke-WebRequest -Uri "https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main/windows/install.ps1").Content | powershell -File -
```