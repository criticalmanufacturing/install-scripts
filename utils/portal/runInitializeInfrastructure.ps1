param (
    [Parameter(Mandatory=$true)][string]$agent,
    [Obsolete("No longer needed. Value ignored.")][string]$license,
    [Parameter(Mandatory=$true)][string]$infrastructure,
    [string]$customer,
    #optional parameters
    [string] $environmentType,
    [string] $parameters,
    [string] $internetNetworkName,
    [string] $portalToken,
    #deprecated parameters
    [Obsolete("The 'customer' parameter should be used instead")][string]$site
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
try
{
    Write-Host "Login..."
    Set-Login -PAT $portalToken
}
catch 
{
    Write-Error $_.Exception.Message
    exit 1
}

$target = "dockerswarm"
$outputDir = $PSScriptRoot + "/agent"

try
{
    Write-Host "Creating infrastructure..."
    $url = New-Infrastructure -IgnoreIfExists -Name $infrastructure -SiteName "$($site)" -CustomerName "$($customer)"
} 
catch 
{
    Write-Error $_.Exception.Message
    exit 1     
}

try
{
    Write-Host "Creating agent..."
    # Create agent
    if(Test-Path $parameters) {
        New-InfrastructureAgent -CustomerInfrastructureName $infrastructure -Name $agent -ParametersPath $parameters -EnvironmentType $environmentType -DeploymentTargetName $target -OutputDir $outputDir
    } else {
        New-InfrastructureAgent -Interactive -CustomerInfrastructureName $infrastructure -Name $agent -EnvironmentType $environmentType -DeploymentTargetName $target -OutputDir $outputDir
    }
}
catch 
{
    Write-Error $_.Exception.Message
    exit 1 
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
