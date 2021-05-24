param (
    [Parameter(Mandatory=$true)][string]$agent,
    [Parameter(Mandatory=$true)][string]$license,
    [Parameter(Mandatory=$true)][string]$site,
    [Parameter(Mandatory=$true)][string]$infrastructure,
    [Parameter(Mandatory=$true)][string]$infrastructureTemplate,
    #optional parameters
    [string] $environmentType = "Development",
    [string] $agentVersion = "8.1.0",
    [string] $parameters = $PSScriptRoot + "./parameters/agent_parameters.json",
    [string] $internetNetworkName
)
$RepositoryUrl = "https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main"

# Get Latest CustomerPortal SDK Release Tag
$CustomerPortalSDKLatestReleaseAPI = "https://api.github.com/repos/criticalmanufacturing/portal-sdk/releases/latest"
$CustomerPortalSDKLatestTag = Invoke-WebRequest -Uri $CustomerPortalSDKLatestReleaseAPI | % { $_.Content } | ConvertFrom-Json | % { $_.tag_name }

# Download the latest release powershell asset
$CustomerPortalSDKPowershellAssetName = "Cmf.CustomerPortal.Sdk.Powershell-$CustomerPortalSDKLatestTag.win-x64.zip"
$CustomerPortalSDKReleaseUrl = "https://github.com/criticalmanufacturing/portal-sdk/releases/latest/download/$CustomerPortalSDKPowershellAssetName"

New-Item -ItemType directory -Path .\sdk -Force | Out-Null
$progressPreference = 'silentlyContinue';
Invoke-WebRequest -Uri $CustomerPortalSDKReleaseUrl -OutFile "./sdk/"
Clear-Host

Expand-Archive .\sdk\$CustomerPortalSDKPowershellAssetName -DestinationPath "./sdk/" -Force
Remove-Item .\sdk\$CustomerPortalSDKPowershellAssetName
Import-Module .\sdk\Cmf.CustomerPortal.Sdk.Powershell.dll

# Login
Set-Login

# Agent properties
$package = "@criticalmanufacturing\infrastructureagent:$agentVersion"
$target = "dockerswarm"
# $destination = "qa"
$outputDir = $PSScriptRoot + "./agent"

# Infrastructure properties

# Create agent
New-Environment -Name $agent -ParametersPath $parameters -EnvironmentType $environmentType -SiteName $site -LicenseName $license -DeploymentPackageName $package -DeploymentTargetName $target -OutputDir $outputDir

# Create infrastructure from template with the infrastructure agent
$url = New-InfrastructureFromTemplate -Name $infrastructure -TemplateName $infrastructureTemplate -AgentName $agent

# Create docker dependencies
if (![string]::IsNullOrEmpty($internetNetworkName)) {
    docker network create -d overlay --attachable internet
}
docker network create -d overlay --attachable traefik-network

# Run agent installation script
Push-Location .\agent\
.\deployStackToSwarm.ps1
Pop-Location

# Check agent connection to customer portal
$waitTime = 10
$timeout = 60 * $waitTime
$isConnected = $false
$totalWaitedTime = 0

Write-Host "Waiting for agent to be connected with Customer Portal..."

Do
{
    # wait
    Start-Sleep -Seconds $waitTime
    $totalWaitedTime = $totalWaitedTime + $waitTime

    # check if agent is connected
    $isConnected = Get-AgentConnection -Name $agent

    # log state
    if ($isConnected -eq $true)
    {
        Write-Debug "Infrastructure Agent $agent not connected. Retrying in $waitTime seconds."
    }
    else
    {
        Write-Debug "Infrastructure Agent $agent not connected. Retrying in $waitTime seconds."
    }
} While (($isConnected -eq $false) -and ($totalWaitedTime -le $timeout))

# inform the user to proceed with the environment installation
Write-Host $url

Read-Host -Prompt "Press Enter to exit"