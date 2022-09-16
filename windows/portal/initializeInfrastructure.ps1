param (
    [Parameter(Mandatory=$true)][string]$agent,
    [Obsolete("No longer needed. Value ignored.")][string]$license,
    [Parameter(Mandatory=$true)][string]$infrastructure,
    [Parameter(Mandatory=$true)][string]$domain,
    [string]$customer,
    #optional parameters
    [string] $environmentType,
    [string] $parameters,
    [string] $internetNetworkName,
    [string] $portalToken,
    #deprecated parameters
    [Obsolete("The 'customer' parameter should be used instead")]
    [string]$site
)

$global:ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main/utils/portal/runInitializeInfrastructure.ps1" -OutFile "./runInitializeInfrastructure.ps1"
.\runInitializeInfrastructure.ps1 -agent "$agent" -site "$site" -customer "$customer" -infrastructure "$infrastructure" -domain "$domain" -environmentType "$environmentType" -parameters "$parameters" -internetNetworkName "$internetNetworkName" -portalToken "$portalToken"
Remove-Item -Path ./runInitializeInfrastructure.ps1
$global:ProgressPreference = 'Continue'
