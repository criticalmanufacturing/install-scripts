# Install powershell
zypper update
zypper install -y curl tar libicu libopenssl1_1 krb5
curl -L https://github.com/PowerShell/PowerShell/releases/download/v7.2.1/powershell-7.2.1-linux-x64.tar.gz -o /tmp/powershell.tar.gz
mkdir -p /opt/microsoft/powershell
tar -xzf /tmp/powershell.tar.gz -C /opt/microsoft/powershell/
chmod +x /usr/bin/pwsh