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
    # infrastructureParameters = "./parameters/infrastructure_parameters.json"
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
infrastructureParameters=""

curl -fsSL https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main/ubuntu/portal/initializeInfrastructure.bash | sudo bash -s -- --agent "$agent" --customer "$customer" --infrastructure "$infrastructure" --environmentType "$environmentType" --internetNetworkName "$internetNetworkName" --portalToken "$portalToken" --parameters "$parameters" --infrastructureParameters "$infrastructureParameters"
```

## Configure customer infrastructure to use a Proxy

When you want to use a Proxy and configure a infrastructure/machine to pass all the connections through a proxy, there are additional configurations that need to be performed to be able to communicate with the external network and get the necessary packages and images from the registry. You must set some environment variables on your system, to permit your machine to communicate through your proxy and access the external network to download the essencial packages and others.

For Linux machines, add the following export commands lines on your /etc/bash.bashrc, ensuring that bash will start with additional environment variables. The goal is to add the necessary environment variables to your system. For Windows machines you can try achive the same goal by creating environemnt variables and configuring the docker daemon.

```bash
export "HTTP_PROXY=http://<<proxyuser:proxypassword>@><proxy.example.com>:<proxyport>"
export "HTTPS_PROXY=http://<<proxyuser:proxypassword>@><proxy.example.com>:<proxyport>"
```

Or to set in your environment variables file (*/etc/environment*) below the PATH environment:

```bash
HTTP_PROXY=http://<<proxyuser:proxypassword>@><proxy.example.com>:<proxyport>
HTTPS_PROXY=http://<<proxyuser:proxypassword>@><proxy.example.com>:<proxyport>
```

Depending on the software or system, it can be necessary you add the same environment variables in lower case to, this is 'http_proxy' and 'https_proxy'.

To define this variables to all your system, you can define on the file */etc/apt/apt.conf* (in some system on location such as */etc/apt/apt.conf.d/{something-proxy}*) the following code:

```bash
Acquire::http:proxy "http://<<proxyuser:proxypassword>@><proxy.example.com>:<proxyport>/";
Acquire::https:proxy "http://<<proxyuser:proxypassword>@><proxy.example.com>:<proxyport>/";
```

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
