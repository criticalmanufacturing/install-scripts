param (
    [Parameter(Mandatory=$true)][string]$agent,
    [Obsolete("No longer needed. Value ignored.")][string]$license,
    [Parameter(Mandatory=$true)][string]$infrastructure,
    [Parameter(Mandatory=$true)][string]$infrastructureTemplate,
    #optional parameters
    [string] $environmentType,
    [string] $parameters,
    [string] $internetNetworkName,
    [string] $portalToken,
    #deprecated parameters
    [Obsolete("There is no need to supply it anymore")]
    [string]$site
)

$global:ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main/utils/portal/runInitializeInfrastructureFromTemplate.ps1" -OutFile "./runInitializeInfrastructureFromTemplate.ps1"
.\runInitializeInfrastructureFromTemplate.ps1 -agent "$agent" -infrastructure "$infrastructure" -infrastructureTemplate "$infrastructureTemplate" -environmentType "$environmentType" -parameters "$parameters" -internetNetworkName "$internetNetworkName" -portalToken "$portalToken"
Remove-Item -Path ./runInitializeInfrastructureFromTemplate.ps1
