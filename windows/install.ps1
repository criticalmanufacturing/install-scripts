$RepositoryUrl = "https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main"
Invoke-WebRequest -Uri "$RepositoryUrl/utils/deployPortainer.ps1" -OutFile deployPortainer.ps1
./deployPortainer.ps1 -RepositoryUrl $RepositoryUrl