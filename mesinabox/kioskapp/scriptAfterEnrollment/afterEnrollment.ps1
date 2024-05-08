<#
    .SYNOPSIS
    1 - Downloads CMF Portal SDK.
    2 - Login into Customer Portal and Generate the Agent Stack. 
    3 - Deploy the Agent Stack

    .DESCRIPTION
    Downloads CMF Portal SDK from NPM and move its contents into the specified folder.
    After this, the CMF Portal SDK do the login using the $PAT on Customer Portal refered on the $PortalSDKAppSettingsPath and Generate the Agent Stack
     regarding the parameters from the $AgentParametersPath and the $CustomerInfrastructureName and $AgentName.
    Finnaly, after the stack been generated and downloaded like a zip, is extracted for the $Output folder (default ./agent) and the stack is deployed
     running the script deployStackToKubernetes.ps1.

    .PARAMETER PAT
    Mandatory. Specifies the PAT to login into the Customer Portal regarding the configuration from the AppSettings file received.

    .PARAMETER CustomerInfrastructureName
    Mandatory. Specifies the Customer Infrastructure Name to create the Agent.
    
    .PARAMETER AgentName
    Mandatory. Specifies the Agent Name to be created.

    .PARAMETER AgentParametersPath
    Mandatory. Specifies the Path for the Agent Parameters path.

    .PARAMETER Target
    Optional. Specifies the Target of the Agent. The default is OpenShiftOnPremisesTarget.

    .PARAMETER Description
    Optional. Specifies the Description of the Agent.

    .PARAMETER EnvironmentType
    Optional. Specifies the Environment Type of the Agent. The default is Development.

    .PARAMETER Output
    Optional. Specifies the Path for the folder where will be copied the Agent stack generated. If not specified is copied for an output folder on the current location (./agent).
#>


param (
    [Parameter(Mandatory)][string] $PAT,
    [Parameter(Mandatory)][string] $CustomerInfrastructureName,
    [Parameter(Mandatory)][string] $AgentName,
    [Parameter(Mandatory)][string] $AgentParametersPath,
    [Parameter(Mandatory)][string]$PortalSDKAppSettingsPath,
    [string] $Target = "OpenShiftOnPremisesTarget",
    [string]$Description,
    [string]$EnvironmentType = "Development",
    [string]$Output
)

Write-Host " --------- Received parameters --------- "
Write-Host "Customer Infrastructure Name: $CustomerInfrastructureName"
Write-Host "Agent Name: $AgentName"
Write-Host "Agent Parameters path: $AgentParametersPath"
Write-Host "PortalSDK AppSettings path $PortalSDKAppSettingsPath"
Write-Host "Target: $Target"
Write-Host "Description: $Description"
Write-Host "Enviroment Type: $EnvironmentType"
Write-Host "Output folder: $Output"
Write-Host " --------------------------------------- "

$currentLocation = $PSScriptRoot
Set-Location $currentLocation
$CmfPortalLocation = "$currentLocation/../node_modules/@criticalmanufacturing/portal/bin"

# where will be saved the stack generated
if ( -Not $Output) {
    $Output = "$currentLocation/agent"
}
 
$error.clear()

# Download PortalSDK and import it
try {
    Write-Host "Downloading portal-sdk..."
    Invoke-Expression "npm install @criticalmanufacturing/portal@latest --no-save"
}
catch {
    Write-Error $_.Exception.Message
    exit 1 
}

# Copy appsettings for PortalSDK, if specified
Write-Host $PortalSDKAppSettingsPath
$current = Get-Location
Write-Host $current
if ($PortalSDKAppSettingsPath) {
    if ( -Not (Test-Path -LiteralPath $PortalSDKAppSettingsPath)) {
        Write-Error "PortalSdk AppSettings path is not valid or the file was not found."
        exit 1
    }
    else {
        Write-Host "Copying the AppSettings file... From: $PortalSDKAppSettingsPath | To: $CmfPortalLocation/appsettings.json"
        Copy-Item $PortalSDKAppSettingsPath -Destination "$CmfPortalLocation/appsettings.json" -Force
        if ($error) {
            Write-Error "Failed copying the AppSettings file for PortalSDK. ExitCode: $LASTEXITCODE | $error"
            exit 1
        }
    }
}

# Login using the PAT
 try {
    Write-Host "Using the specified Customer Portal PAT to login..."
    Invoke-Expression "$CmfPortalLocation/cmf-portal login --token $PAT"
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}

Write-Host "Checking Agent Parameters path..."
$agentParamsFileExists = Test-Path -LiteralPath $AgentParametersPath
Write-Host "Agents path $AgentParametersPath $currentLocation" 
if (-Not $agentParamsFileExists) {
    Write-Error "The Agent Parameters file was not found!"
    exit 1
}

# Deploy agent
try {
    Write-Host "Creating Infrastructure Agent..."
    $fullPath = Join-Path -Path $PSScriptRoot -ChildPath $AgentParametersPath
    Invoke-Expression "$CmfPortalLocation/cmf-portal deployagent -ci $CustomerInfrastructureName -n $AgentName -params $fullPath -type $EnvironmentType -trg $Target -o $Output -d $Description"
}
catch {
    Write-Error $_.Exception.Message
    exit 1 
}

Write-Host "The output folder (location of the stack generated) is expected to be: $Output"

Write-Host "Checking for deployStackToKubernetes.ps1 on the Output folder..."

$deployStackToKubernetesPath = "$Output/deployStackToKubernetes.ps1"

$substringsToRemove = @(
    "traefik-deployment",
    "traefik-service",
    "traefik-lb-service"
)

# Read all lines from the script
$scriptContent = Get-Content -Path $deployStackToKubernetesPath

# Remove lines containing the traefik resources
$scriptContent = $scriptContent | Where-Object { $line = $_; -not ($substringsToRemove | Where-Object { $line -like "*$_*" }) }

Write-Output "Modified script content:"
$scriptContent

# Write back modified content to the script file
$scriptContent | Set-Content -Path $deployStackToKubernetesPath

#$deployStackToKubernetesPath = Join-Path -Path $PSScriptRoot -ChildPath $deployStackToKubernetesPath
if ( -Not (Test-Path -LiteralPath $deployStackToKubernetesPath)) {
    Write-Error "deployStackToKubernetes.ps1 file was not found on the Output directory $deployStackToKubernetesPath."
    exit 1
}

# Run deployStackToKubernetes.ps1 - Deploy Agent

Write-Host "Start running deployStackToKubernetes.ps1..."

# Deploy Agent
try {
    Write-Host "Deploying agent..."
   
    # deploy agent
    . ./deployAgent.ps1 -AgentName $AgentName -DeploymentScriptPath $deployStackToKubernetesPath
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}

if($error)
{
    Write-Error "The Infrastructure Agent deployment appears to have failed. ErrorMessage: $error"
    exit 1 
} else {
    Write-Host "Infrastructure Agent deployed with success!"
}

