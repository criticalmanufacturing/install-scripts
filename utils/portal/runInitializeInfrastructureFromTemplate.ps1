param (
    [Parameter(Mandatory=$true)][string]$agent,
    [Parameter(Mandatory=$true)][string]$license,
    [Parameter(Mandatory=$true)][string]$site,
    [Parameter(Mandatory=$true)][string]$infrastructure,
    [Parameter(Mandatory=$true)][string]$infrastructureTemplate,
    #optional parameters
    [string] $environmentType,
    [string] $parameters,
    [string] $internetNetworkName,
    [string] $portalToken
)

if ([string]::IsNullOrEmpty($environmentType)) {
    $environmentType = "Development"
}

if ([string]::IsNullOrEmpty($internetNetworkName)) {
    $internetNetworkName = "internet"
}

if ([string]::IsNullOrEmpty($parameters)) {
    $parameters = $PSScriptRoot + "./parameters/agent_parameters.json"
}

$RepositoryUrl = "https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main"
$global:ProgressPreference = 'SilentlyContinue'

# Import SDK
Invoke-WebRequest -Uri "$RepositoryUrl/utils/portal/utils/importSDK.ps1" -OutFile "./importSDK.ps1"
. ./importSDK.ps1
Remove-Item -Path ./importSDK.ps1

# Login
Set-Login -PAT $portalToken

# Agent properties
$target = "dockerswarm"
$outputDir = $PSScriptRoot + "./agent"

# Create infrastructure from template with the infrastructure agent
$url = New-InfrastructureFromTemplate -Name $infrastructure -TemplateName $infrastructureTemplate

# Create agent
if(Test-Path $parameters) {
    New-InfrastructureAgent -CustomerInfrastructureName $infrastructure -Name $agent -ParametersPath $parameters -EnvironmentType $environmentType -LicenseName $license -DeploymentTargetName $target -OutputDir $outputDir
} else {
    New-InfrastructureAgent -Interactive -CustomerInfrastructureName $infrastructure -Name $agent -EnvironmentType $environmentType -LicenseName $license -DeploymentTargetName $target -OutputDir $outputDir
}


# Create docker dependencies
if (![string]::IsNullOrEmpty($internetNetworkName)) {
    docker network create -d overlay --attachable internet
}
docker network create -d overlay --attachable --internal traefik-network

# Deploy Agent
Invoke-WebRequest -Uri "$RepositoryUrl/utils/portal/utils/deployAgent.ps1" -OutFile "./deployAgent.ps1"
. ./deployAgent.ps1 -agent $agent
Remove-Item -Path ./deployAgent.ps1

# inform the user to proceed with the environment installation
Write-Host $url

Read-Host -Prompt "Press Enter to exit"