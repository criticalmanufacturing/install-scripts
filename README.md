# install-scripts
Critical Manufacturing Installation Scripts

## Prepare Linux environment

```
curl -fsSL https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main/linux/install.sh | sudo bash
```

Installs Docker, Powershell and deploys a Portainer stack.

To install 

### Compatibility:
 - Ubuntu 20.04
 - Ubuntu 22.04
 - Debian 11
 - RHEL 8 (using CentOS packages for Docker)

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
It also assumes that the Environment was already prepared.

Powershell Core 7.1.3 or above is required.

### Initialize Infrastructure

#### Windows

Using Powershell

```powershell
#--- Replace the mandatory parameter values below
$params = @{
    Agent = ""
    Customer = ""
    Infrastructure = ""
    #--- Optional parameters
    # EnvironmentType = "Development"
    # parameters = "./parameters/agent_parameters.json"
    # internetNetworkName = "internet"
    # portalToken = ""
}

$global:ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main/windows/portal/initializeInfrastructure.ps1" -OutFile "./initializeInfrastructure.ps1"
pwsh -File "initializeInfrastructure.ps1" @params
Remove-Item -Path ./initializeInfrastructure.ps1
```
#### Linux

```bash
agent=""
customer=""
infrastructure=""
#--- Optional parameters
environmentType=""
internetNetworkName=""
portalToken=""
parameters=""

curl -fsSL https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main/ubuntu/portal/initializeInfrastructure.bash | sudo bash -s -- --agent "$agent" --customer "$customer" --infrastructure "$infrastructure" --environmentType "$environmentType" --internetNetworkName "$internetNetworkName" --portalToken "$portalToken" --parameters "$parameters"
```

### Initialize Customer Infrastructure from a Template
#### Windows

Using Powershell

```powershell
#--- Replace the mandatory parameter values below
$params = @{
    Agent = ""
    Infrastructure = ""
    InfrastructureTemplate = ""
    #--- Optional parameters
    # EnvironmentType = "Development"
    # parameters = "./parameters/agent_parameters.json"
    # internetNetworkName = "internet"
    # portalToken = ""
}

$global:ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main/windows/portal/initializeInfrastructureFromTemplate.ps1" -OutFile "./initializeInfrastructureFromTemplate.ps1"
pwsh -File "initializeInfrastructureFromTemplate.ps1" @params
Remove-Item -Path ./initializeInfrastructureFromTemplate.ps1
```
#### Linux


```bash
agent=""
infrastructure=""
infrastructureTemplate=""
#--- Optional parameters
environmentType=""
internetNetworkName=""
portalToken=""
parameters=""

curl -fsSL https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main/linux/portal/initializeInfrastructure.bash | sudo bash -s -- --agent "$agent" --infrastructure "$infrastructure" --infrastructureTemplate "$infrastructureTemplate" --environmentType "$environmentType" --internetNetworkName "$internetNetworkName" --portalToken "$portalToken" --parameters "$parameters"
```
