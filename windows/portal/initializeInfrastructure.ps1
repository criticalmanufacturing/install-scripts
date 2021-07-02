param (
    [Parameter(Mandatory=$true)][string]$agent,
    [Parameter(Mandatory=$true)][string]$license,
    [Parameter(Mandatory=$true)][string]$site,
    [Parameter(Mandatory=$true)][string]$infrastructure,
    [Parameter(Mandatory=$true)][string]$domain,
    #optional parameters
    [string] $environmentType,
    [string] $agentVersion,
    [string] $parameters,
    [string] $internetNetworkName,
    [string] $portalToken
)

$global:ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main/utils/portal/runInitializeInfrastructure.ps1" -OutFile "./runInitializeInfrastructure.ps1"
.\runInitializeInfrastructure.ps1 -agent "$agent" -license "$license" -site "$site" -infrastructure "$infrastructure" -domain "$domain" -environmentType "$environmentType" -agentVersion "$agentVersion" -parameters "$parameters" -internetNetworkName "$internetNetworkName" -portalToken "$portalToken"
Remove-Item -Path ./runInitializeInfrastructure.ps1
$global:ProgressPreference = 'Continue'