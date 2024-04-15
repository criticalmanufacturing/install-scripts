# Get Latest CustomerPortal SDK Release Tag

$CustomerPortalSDKLatestReleaseAPI = "https://api.github.com/repos/criticalmanufacturing/portal-sdk/releases/latest"
$CustomerPortalSDKLatestTag = Invoke-WebRequest -Uri $CustomerPortalSDKLatestReleaseAPI | % { $_.Content } | ConvertFrom-Json | % { $_.tag_name }
# Download the latest release powershell asset
$CustomerPortalSDKPowershellAssetName = "Cmf.CustomerPortal.Sdk.Powershell-$CustomerPortalSDKLatestTag.zip"
$CustomerPortalSDKReleaseUrl = "https://github.com/criticalmanufacturing/portal-sdk/releases/latest/download/$CustomerPortalSDKPowershellAssetName"
New-Item -ItemType directory -Path .\sdk -Force | Out-Null
Invoke-WebRequest -Uri $CustomerPortalSDKReleaseUrl -OutFile "./sdk/$CustomerPortalSDKPowershellAssetName"
Expand-Archive .\sdk\$CustomerPortalSDKPowershellAssetName -DestinationPath "./sdk/" -Force
Remove-Item .\sdk\$CustomerPortalSDKPowershellAssetName
Import-Module .\sdk\Cmf.CustomerPortal.Sdk.Powershell.dll