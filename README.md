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

## Portal configurations

The initialization assumes that docker is installed and running.
It also assumes that Windows Environment was already prepared.

Powershell Core 7.1.3 or above is required.

### Initialize Infrastructure

#### Windows

Using Powershell

```powershell
#--- Replace the mandatory parameter values below
$params = @{
    Agent = ""
    License = ""
    Site = ""
    Infrastructure = ""
    Domain = ""
    #--- Optional parameters
    # EnvironmentType = "Development"
    # parameters = "./parameters/agent_parameters.json"
    # internetNetworkName = "internet"
    # portalToken = ""
}

$global:ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/linux-infrasctucture/windows/portal/initializeInfrastructure.ps1" -OutFile "./initializeInfrastructure.ps1"
pwsh -File "initializeInfrastructure.ps1" @params
Remove-Item -Path ./initializeInfrastructure.ps1
```
#### Linux

```bash
agent=""
license=""
site=""
infrastructure=""
domain=""
#--- Optional parameters
environmentType=""
internetNetworkName=""
portalToken=""
parameters=""

curl -fsSL https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/linux-infrasctucture/ubuntu/portal/initializeInfrastructure.bash | bash -s -- --agent "$agent" --license "$license" --site "$site" --infrastructure "$infrastructure" --domain "$domain" --environmentType "$environmentType" --internetNetworkName "$internetNetworkName" --portalToken "$portalToken" --parameters "$parameters"
```

### Initialize Customer Infrastructure from a Template
#### Windows

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
    # portalToken = ""
}

$global:ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/linux-infrasctucture/windows/portal/initializeInfrastructureFromTemplate.ps1" -OutFile "./initializeInfrastructureFromTemplate.ps1"
pwsh -File "initializeInfrastructureFromTemplate.ps1" @params
Remove-Item -Path ./initializeInfrastructureFromTemplate.ps1
```
#### Linux

```bash
agent=""
license=""
site=""
infrastructure=""
infrastructureTemplate=""
#--- Optional parameters
environmentType=""
internetNetworkName=""
portalToken=""
parameters=""

curl -fsSL https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/linux-infrasctucture/ubuntu/portal/initializeInfrastructure.bash | bash -s -- --agent "$agent" --license "$license" --site "$site" --infrastructure "$infrastructure" --infrastructureTemplate "$infrastructureTemplate" --environmentType "$environmentType" --internetNetworkName "$internetNetworkName" --portalToken "$portalToken" --parameters "$parameters"
```