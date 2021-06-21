param (
    [Parameter(Mandatory=$true)][string]$agent,
    [Parameter(Mandatory=$true)][string]$license,
    [Parameter(Mandatory=$true)][string]$site,
    [Parameter(Mandatory=$true)][string]$infrastructure,
    [Parameter(Mandatory=$true)][string]$infrastructureTemplate,
    #optional parameters
    [string] $environmentType,
    [string] $agentVersion,
    [string] $parameters,
    [string] $internetNetworkName,
    [string] $portalToken
)

Invoke-WebRequest -Uri "https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/linux-infrasctucture/utils/portal/runInitializeInfrastructureFromTemplate.ps1"
. ./runInitializeInfrastructureFromTemplate.ps1 $argumentList