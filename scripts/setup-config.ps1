$ErrorActionPreference = "Stop"

$scriptDir = (Get-Location).Path

$configFile = Join-Path $scriptDir "config/application-sonic-agent.yml"
$flagFile = Join-Path $scriptDir ".configed_flag"

function Prompt-Value {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [string]$Default = "",
        [switch]$Mandatory
    )

    while ($true) {
        $input = if ([string]::IsNullOrEmpty($Default)) {
            Read-Host $Prompt
        } else {
            $value = Read-Host "$Prompt [$Default]"
            if ([string]::IsNullOrEmpty($value)) { $value = $Default }
            $value
        }

        if (-not [string]::IsNullOrWhiteSpace($input)) {
            return $input.Trim()
        }

        if (-not $Mandatory -and -not [string]::IsNullOrEmpty($Default)) {
            return $Default.Trim()
        }

        Write-Host "Input cannot be empty. Please try again." -ForegroundColor Yellow
    }
}

function Get-AgentValue {
    param([Parameter(Mandatory = $true)][string]$Field)

    if (-not (Test-Path $configFile)) { return "" }
    $lines = Get-Content -Path $configFile -Encoding UTF8
    $inAgent = $false

    foreach ($line in $lines) {
        if ($line -match '^\s{2}agent:') {
            $inAgent = $true
            continue
        }
        if ($line -match '^\s{2}[^\s]' -and $line -notmatch '^\s{4}') {
            $inAgent = $false
        }
        if ($line -match '^\S') {
            $inAgent = $false
        }
        if ($inAgent -and $line -match ("^\s{4}" + [Regex]::Escape($Field) + ":\s*(.*)$")) {
            return $matches[1].Trim()
        }
    }
    return ""
}

function Update-AgentConfig {
    param(
        [Parameter(Mandatory = $true)][string]$AgentHost,
        [Parameter(Mandatory = $true)][string]$Port,
        [Parameter(Mandatory = $true)][string]$Key
    )

    $lines = Get-Content -Path $configFile -Encoding UTF8
    $inAgent = $false

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s{2}agent:') {
            $inAgent = $true
            continue
        }
        if ($line -match '^\s{2}[^\s]' -and $line -notmatch '^\s{4}') {
            $inAgent = $false
        }
        if ($line -match '^\S') {
            $inAgent = $false
        }
        if (-not $inAgent) { continue }

        if ($line -match '^\s{4}host:') {
            $lines[$i] = "    host: $AgentHost"
        } elseif ($line -match '^\s{4}port:') {
            $lines[$i] = "    port: $Port"
        } elseif ($line -match '^\s{4}key:') {
            $lines[$i] = "    key: $Key"
        }
    }

    $content = ($lines -join "`n") + "`n"
    [System.IO.File]::WriteAllText($configFile, $content, [System.Text.Encoding]::UTF8)
}

function Get-LocalIPv4 {
    try {
        $client = [System.Net.Sockets.UdpClient]::new()
        $client.Connect("8.8.8.8", 80)
        $ip = $client.Client.LocalEndPoint.Address.ToString()
        $client.Dispose()
        if ($ip -and -not $ip.StartsWith("127.")) { return $ip }
    } catch {}

    try {
        $host = [System.Net.Dns]::GetHostEntry([System.Net.Dns]::GetHostName())
        foreach ($addr in $host.AddressList) {
            if ($addr.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and -not $addr.IPAddressToString.StartsWith("127.")) {
                return $addr.IPAddressToString
            }
        }
    } catch {}

    return ""
}

if (-not (Test-Path $flagFile)) {
    Write-Host "First run. Please configure Sonic Agent:" -ForegroundColor Cyan
    $detectedHost = Get-LocalIPv4
    $currentHost = Get-AgentValue -Field "host"
    $agentPort = Get-AgentValue -Field "port"

    if ([string]::IsNullOrWhiteSpace($detectedHost)) {
        Write-Host "Failed to auto-detect IPv4. Please enter manually." -ForegroundColor Yellow
        $agentHost = Prompt-Value -Prompt "Enter Agent Host IPv4" -Default $currentHost
    } else {
        Write-Host "Detected local IPv4: $detectedHost" -ForegroundColor Green
        $agentHost = $detectedHost
    }

    $agentKey = Prompt-Value -Prompt "Enter Agent Key (contact admin)" -Mandatory

    $configDir = Join-Path $scriptDir "config"
    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Path $configDir | Out-Null
    }

    # 关键修复：参数名从 -Host 改为 -AgentHost
    Update-AgentConfig -AgentHost $agentHost -Port $agentPort -Key $agentKey
    New-Item -ItemType File -Path $flagFile -Force | Out-Null
    Write-Host "Configuration updated: $configFile" -ForegroundColor Green
}

exit 0