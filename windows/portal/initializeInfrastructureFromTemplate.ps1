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

$global:ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/linux-infrasctucture/utils/portal/runInitializeInfrastructureFromTemplate.ps1" -OutFile "./runInitializeInfrastructureFromTemplate.ps1"
.\runInitializeInfrastructureFromTemplate.ps1 -agent "$agent" -license "$license" -site "$site" -infrastructure "$infrastructure" -infrastructureTemplate "$infrastructureTemplate" -environmentType "$environmentType" -agentVersion "$agentVersion" -parameters "$parameters" -internetNetworkName "$internetNetworkName" -portalToken "$portalToken"
Remove-Item -Path ./runInitializeInfrastructureFromTemplate.ps1
