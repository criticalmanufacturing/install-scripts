param (
    [Parameter(Mandatory=$true)][string]$agent,
    [Parameter(Mandatory=$true)][string]$license,
    [Parameter(Mandatory=$true)][string]$infrastructure,
    [Parameter(Mandatory=$true)][string]$infrastructureTemplate,
    #optional parameters
    [string] $environmentType,
    [string] $parameters,
    [string] $internetNetworkName,
    [string] $portalToken,
    #deprecated parameters
    [string]$site # unused, but kept for compatibility
)

$global:ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main/utils/portal/runInitializeInfrastructureFromTemplate.ps1" -OutFile "./runInitializeInfrastructureFromTemplate.ps1"
.\runInitializeInfrastructureFromTemplate.ps1 -agent "$agent" -license "$license" -infrastructure "$infrastructure" -infrastructureTemplate "$infrastructureTemplate" -environmentType "$environmentType" -parameters "$parameters" -internetNetworkName "$internetNetworkName" -portalToken "$portalToken"
Remove-Item -Path ./runInitializeInfrastructureFromTemplate.ps1
