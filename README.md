# install-scripts
Critical Manufacturing Installation Scripts

## Prepare single server Ubuntu 20.04 environment

```console
$ curl -fsSL https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main/ubuntu/20.04/install.bash | bash
```

Using a custom admin password

```
$ curl -fsSL https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main/ubuntu/20.04/install.bash | bash -s -- -password <custom password>
```
## Prepare Windows environment

The installation assumes that docker is installed and running

```powershell
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main/windows/install.ps1" -OutFile install.ps1
./install.ps1
```