# install-scripts
Critical Manufacturing Installation Scripts

## Prepare single server Ubuntu 20.04 environment

```
curl -fsSL https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main/ubuntu/20.04/install.bash | bash
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

### Initialize Customer Infrastructure from a Template

The initialization assumes that docker is installed and running.
It also assumes that Windows Environment was already prepared.

Powershell Core 7.1.3 or above is required.

Using Powershell

```powershell
#--- Replace the mandatory parameter values below
$params = @{
    Agent = ""
    License = ""
    Site = ""
    Infrastructure = ""
    InfrastructureTemplate = ""
    #--- Optional parameters
    # EnvironmentType = "Development"
    # parameters = "./parameters/agent_parameters.json"
    # internetNetworkName = "internet"
}

Invoke-WebRequest -Uri "https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main/windows/portal/initializeInfrastructureFromTemplate.ps1" -OutFile "./initializeInfrastructureFromTemplate.ps1"
pwsh -File "initializeInfrastructureFromTemplate.ps1" @params
```
