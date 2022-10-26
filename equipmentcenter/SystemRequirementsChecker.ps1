param (
    [string]$DatabaseServerInstance = $null
)

Install-Package Hardware.Info -RequiredVersion 10.1.0 -Destination packages -Force -source https://www.nuget.org/api/v2 -SkipDependencies
Install-Package ByteSize -RequiredVersion 2.1.1 -Destination packages -Force -source https://www.nuget.org/api/v2 -SkipDependencies

Add-Type -Path './packages/ByteSize.2.1.1/lib/netstandard2.0/ByteSize.dll'
Add-Type -Path './packages/Hardware.Info.10.1.0/lib/netstandard2.0/Hardware.Info.dll'

$memoryByteSize = [ByteSizeLib.ByteSize]::Parse("16GB")
$diskByteSize = [ByteSizeLib.ByteSize]::Parse("250GB")
$cores = 8
$logicalProcessors = 16
$collation = "Latin1_General_CI_AS"

if (![string]::IsNullOrEmpty($DatabaseServerInstance)) {
    Install-Module SqlServer -Force

    $cred = Get-Credential -Message "Credential are required for access to $DatabaseServerInstance"
    $pw = ConvertFrom-SecureString -SecureString $cred.Password -AsPlainText
    
    $queryResult = Invoke-Sqlcmd -Query "SELECT CONVERT (varchar, SERVERPROPERTY('collation')) as Collation" -ServerInstance $DatabaseServerInstance -Database "master" -Username $cred.UserName -Password $pw
    
    if ( $queryResult.Collation -ne $collation ) {
        Write-Error "INVALID COLLATION: REQUIRED={$collation}, ACTUAL={$($queryResult.Collation)}"
    }
    else {
        Write-Output "COLLATION IS VALID"
    }
}
else {
    Write-Warning "DATABASE INSTANCE ADDRESS NOT PROVIDED, SKIPPING COLLATION VALIDATION"
}


function Test-Url {

    param (
        $Url
    )

    $statusCode = $(Invoke-WebRequest -Method GET -Uri $url).StatusCode
    if ($statusCode -ne 200) {
        Write-Error "$url return status code $statusCode"
    }
}

Test-Url https://portal.criticalmanufacturing.com/
Test-Url https://security.criticalmanufacturing.com/
Test-Url https://criticalmanufacturing.io/
Test-Url https://docker.io/
Test-Url https://mcr.microsoft.com/
Test-Url https://github.com/
Test-Url https://raw.githubusercontent.com/


$hardwareInfo = [Hardware.Info.HardwareInfo]::new()

$hardwareInfo.RefreshMemoryStatus()
$hardwareInfo.RefreshCPUList()
$hardwareInfo.RefreshDriveList()

$rootDriveName = $IsWindows ? "C:\" : "/";

$rootDrive = [System.IO.DriveInfo]::GetDrives() | Where-Object {$_.Name -eq $rootDriveName}

if ($null -eq $rootDrive)
{
    Write-Error "COULD NOT FIND ROOT DRIVE"
}
else
{
    $totalDiskByteSize = [ByteSizeLib.ByteSize]::FromBytes($rootDrive.TotalSize);
    $availableDiskByteSize = [ByteSizeLib.ByteSize]::FromBytes($rootDrive.AvailableFreeSpace);

    # Write-Output "TOTAL DISK SIZE: {$totalDiskByteSize}; FREE SPACE: {$availableDiskByteSize}"

    if ($availableDiskByteSize -lt $diskByteSize)
    {
        Write-Error "DISK SPACE UNDER REQUIRED VALUE: REQUIRED={$diskByteSize}; AVAILABLE={$availableDiskByteSize}"
    }
    else
    {
        Write-Output "DISK SPACE IS VALID"
    }
}

$availableMemoryByteSize = [ByteSizeLib.ByteSize]::FromBytes($hardwareInfo.MemoryStatus.TotalPhysical);

# Write-Output "TOTAL MEMORY: $availableMemoryByteSize"

if ($availableMemoryByteSize -lt $memoryByteSize)
{
    Write-Error "MEMORY UNDER REQUIRED VALUE: REQUIRED={$memoryByteSize}; ACTUAL={$availableMemoryByteSize}"
}
else
{
    Write-Output "MEMORY IS VALID"
}

$coresAvailable = 0
$hardwareInfo.CpuList | ForEach-Object {$coresAvailable += $_.NumberOfCores}

# Write-Output "TOTAL CPU CORES: $coresAvailable"

if ($coresAvailable -lt $cores)
{
    Write-Error "NUMBER OF CORES UNDER REQUIRED VALUE: REQUIRED={$cores}; ACTUAL={$coresAvailable}"
}
else
{
    Write-Output "NUMBER OF CORES IS VALID"
}


$logicalProcessorsAvailable = 0
$hardwareInfo.CpuList | ForEach-Object {$logicalProcessorsAvailable += $_.NumberOfLogicalProcessors}


# Write-Output "TOTAL LOGICAL PROCESSORS: {#logicalProcessorsAvailable}""

if ($logicalProcessorsAvailable -lt $logicalProcessors)
{
    Write-Error "NUMBER OF LOGICAL PROCESSORS UNDER REQUIRED VALUE: REQUIRED={$logicalProcessors}; ACTUAL={$logicalProcessorsAvailable}"  -Category InvalidArgument
}
else
{
    Write-Output "NUMBER OF LOGICAL PROCESSORS IS VALID"
}
