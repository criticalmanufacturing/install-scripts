# install-scripts
Critical Manufacturing Installation Scripts

## Prepare single server Ubuntu environment

```
curl -fsSL https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main/ubuntu/install.bash | sudo bash
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

curl -fsSL https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main/ubuntu/portal/initializeInfrastructure.bash | sudo bash -s -- --agent "$agent" --infrastructure "$infrastructure" --infrastructureTemplate "$infrastructureTemplate" --environmentType "$environmentType" --internetNetworkName "$internetNetworkName" --portalToken "$portalToken" --parameters "$parameters"
```


## Configure customer infrastructure to use a Proxy

When you want to use a Proxy and configure a infrastructure/machine to pass all the connections through a proxy, some troubles can appear to be possible to communicate with the external network and get the necessary packages and images from the registry. You must set some environment variables on your system, to permit your machine to communicate through your proxy and access the external network to download the essencial packages and others.

Assuming you are using a linux machine (for windows you must try achive the same goal, creating environemnt variables and configuring the docker daemon), you must run something like the next command lines to add the necessary environment variables (with values replaced) to your system.

```bash
export "HTTP_PROXY=http://<<proxyuser:proxypassword>@><proxy.example.com>:<proxyport>"
export "HTTPS_PROXY=http://<<proxyuser:proxypassword>@><proxy.example.com>:<proxyport>"
```

Depending on the software or system, can be necessary you add the same environment variables in lower case to, like http_proxy and https_proxy.

After this, your system must be able to update the current packages and get new ones, this is, all the necessary packages to deploy a customer infrastructure on your machine (the sections and scripts discussed above), in this case for example docker, portainer and powershell. 

The next part of this topic is about how to configure your docker daemon from your infrastructure to use your defined proxy (the docker is mandatory), because probably you may need some changes/configurations to make the docker pass through your proxy. 

The best solution to make the docker respect your proxy configurations is present on the [docker documentation](https://docs.docker.com/config/daemon/systemd/#httphttps-proxy), where is explained the solution assuming you are using a linux machine. Summing up, for a regular installation the steps are the follows: 
1. Create directory for docker service 
```bash
sudo mkdir -p /etc/systemd/system/docker.service.d
```

2. Create a file named *http-proxy.conf* on the previous directory (/etc/systemd/system/docker.service.d/http-proxy.conf)

3. Add your proxy configuration like environment variables (see the next example) on the created file.
```docker
[Service]
Environment="HTTP_PROXY=http://<<proxyuser:proxypassword>@><proxy.example.com>:<proxyport>"
Environment="HTTPS_PROXY=http://<<proxyuser:proxypassword>@><proxy.example.com>:<proxyport>"
```

4. Restart your docker daemon to apply your configurations
```bash
sudo systemctl daemon-reload
sudo systemctl restart docker
```

5. To check your docker configurations
```bash
sudo systemctl show --property=Environment docker
```
