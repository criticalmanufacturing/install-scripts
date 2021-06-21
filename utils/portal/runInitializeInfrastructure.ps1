param (
    [Parameter(Mandatory=$true)][string]$agent,
    [Parameter(Mandatory=$true)][string]$license,
    [Parameter(Mandatory=$true)][string]$site,
    [Parameter(Mandatory=$true)][string]$infrastructure,
    [Parameter(Mandatory=$true)][string]$domain,
    #optional parameters
    [string] $environmentType = "Development",
    [string] $agentVersion = "8.1.0",
    [string] $parameters = $PSScriptRoot + "./parameters/agent_parameters.json",
    [string] $internetNetworkName = "internet",
    [string] $portalToken
)

if ([string]::IsNullOrEmpty($environmentType)) {
    $environmentType = "Development"
}

if ([string]::IsNullOrEmpty($agentVersion)) {
    $agentVersion = "8.1.0"
}

if ([string]::IsNullOrEmpty($internetNetworkName)) {
    $internetNetworkName = "internet"
}

$RepositoryUrl = "https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/linux-infrasctucture"

# Import SDK
Invoke-WebRequest -Uri "$RepositoryUrl/utils/portal/utils/importSDK.ps1"
. ./importSDK.ps1
Remove-Item -Path ./importSDK.ps1

# Login
Set-Login -PAT $portalToken

$package = "@criticalmanufacturing\infrastructureagent:$agentVersion"
$target = "dockerswarm"
$outputDir = $PSScriptRoot + "/agent"

# Create agent
if (Test-Path $parameters) {
	New-Environment -Name $agent -ParametersPath $parameters -EnvironmentType $environmentType -SiteName $site -LicenseName $license -DeploymentPackageName $package -DeploymentTargetName $target -OutputDir $outputDir
} else {
	New-Environment -Name $agent -Interactive -EnvironmentType $environmentType -SiteName $site -LicenseName $license -DeploymentPackageName $package -DeploymentTargetName $target -OutputDir $outputDir
}

$url = New-Infrastructure -Name $infrastructure -AgentName $agent -SiteName $site -Domain $domain

# Create docker dependencies
if (![string]::IsNullOrEmpty($internetNetworkName)) {
    docker network create -d overlay --attachable internet
}
docker network create -d overlay --attachable traefik-network

# Deploy Agent
Invoke-WebRequest -Uri "$RepositoryUrl/utils/portal/utils/deployAgent.ps1"
. ./deployAgent.ps1 -agent $agent
Remove-Item -Path ./deployAgent.ps1


# inform the user to proceed with the environment installation
Write-Host $url

Read-Host -Prompt "Press Enter to exit"