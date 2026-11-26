<#
.SYNOPSIS
    Checks disk space and key services on the lab servers and produces an HTML + CSV report.

.DESCRIPTION
    For each server, the script:
      - Checks it can be reached over PowerShell remoting (WinRM)
      - Reports free space on every fixed disk, flagged OK / WARNING / CRITICAL
      - Checks that the services for that server's role are running
    The local machine is checked directly; other servers through Invoke-Command.

    Writes:
      - ServerHealth_latest.html   (overwritten each run, the "dashboard")
      - ServerHealth_history.csv   (one row per check per run, appended)

    Designed to run unattended as a Scheduled Task under a gMSA.

.PARAMETER Servers
    Hashtable of server name -> list of services to check.

.PARAMETER WarningPercent
    Free space below this percentage is a WARNING. Default 20.

.PARAMETER CriticalPercent
    Free space below this percentage is CRITICAL. Default 10.

.PARAMETER OutputFolder
    Where reports are written. Default C:\Reports\ServerHealth

.EXAMPLE
    .\Test-ServerHealth.ps1
#>

[CmdletBinding()]
param(
    [System.Collections.IDictionary]$Servers = [ordered]@{
        "DC01" = @("NTDS","DNS","Netlogon","Kdc","W32Time","DHCPServer")
        "DC02" = @("NTDS","DNS","Netlogon","Kdc","W32Time","DHCPServer")
        "FS01" = @("LanmanServer","Dfs","CertSvc")
    },
    [int]$WarningPercent  = 20,
    [int]$CriticalPercent = 10,
    [string]$OutputFolder = "C:\Reports\ServerHealth"
)

if (-not (Test-Path $OutputFolder)) { New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null }
$RunTime = Get-Date -Format "yyyy-MM-dd HH:mm"

# The checks that run on each server (locally, or remotely via Invoke-Command)
$checkBlock = {
    param($ServiceNames, $Warn, $Crit)

    $out = @()
    Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
        $pct = if ($_.Size) { [math]::Round(($_.FreeSpace / $_.Size) * 100, 1) } else { 0 }
        $status = if ($pct -lt $Crit) { "CRITICAL" } elseif ($pct -lt $Warn) { "WARNING" } else { "OK" }
        $out += [pscustomobject]@{
            Check  = "Disk $($_.DeviceID)"
            Status = $status
            Detail = "{0}% free ({1} GB of {2} GB)" -f $pct, [math]::Round($_.FreeSpace/1GB,1), [math]::Round($_.Size/1GB,1)
        }
    }
    foreach ($name in $ServiceNames) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        $out += [pscustomobject]@{
            Check  = "Service $name"
            Status = if (-not $svc) { "CRITICAL" } elseif ($svc.Status -eq "Running") { "OK" } else { "CRITICAL" }
            Detail = if ($svc) { "$($svc.DisplayName): $($svc.Status)" } else { "Service not found" }
        }
    }
    $out
}

$results = @()
foreach ($server in $Servers.Keys) {
    Write-Host "Checking $server..."
    try {
        if ($server -eq $env:COMPUTERNAME) {
            $checks = & $checkBlock $Servers[$server] $WarningPercent $CriticalPercent
        }
        else {
            $checks = Invoke-Command -ComputerName $server -ScriptBlock $checkBlock `
                -ArgumentList $Servers[$server], $WarningPercent, $CriticalPercent -ErrorAction Stop
        }
        foreach ($c in $checks) {
            $results += [pscustomobject]@{ Time = $RunTime; Server = $server; Check = $c.Check; Status = $c.Status; Detail = $c.Detail }
        }
    }
    catch {
        $results += [pscustomobject]@{ Time = $RunTime; Server = $server; Check = "Reachable"; Status = "CRITICAL"; Detail = $_.Exception.Message }
    }
}

# History (append) and latest dashboard (overwrite)
$results | Export-Csv -Path (Join-Path $OutputFolder "ServerHealth_history.csv") -NoTypeInformation -Append

$rows = foreach ($r in $results) {
    $colour = switch ($r.Status) { "OK" { "#2E7D32" } "WARNING" { "#E65100" } default { "#C00000" } }
    "<tr><td>$($r.Server)</td><td>$($r.Check)</td><td style='color:$colour;font-weight:bold'>$($r.Status)</td><td>$($r.Detail)</td></tr>"
}
$problems = @($results | Where-Object Status -ne "OK").Count
$summary  = if ($problems -eq 0) { "<p style='color:#2E7D32;font-weight:bold'>All checks OK.</p>" } else { "<p style='color:#C00000;font-weight:bold'>$problems check(s) need attention.</p>" }

$html = @"
<html><head><meta charset='utf-8'><title>Server Health</title>
<style>
  body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #222; }
  h1 { color: #1F3864; } .meta { color: #555; font-size: 13px; }
  table { border-collapse: collapse; width: 100%; font-size: 14px; }
  th { background: #1F3864; color: #fff; text-align: left; padding: 6px 10px; }
  td { padding: 6px 10px; border-bottom: 1px solid #ddd; }
</style></head><body>
<h1>Server Health</h1>
<p class='meta'>Checked: $RunTime &nbsp;|&nbsp; Run by: $env:USERNAME on $env:COMPUTERNAME &nbsp;|&nbsp; Disk thresholds: warning &lt; $WarningPercent%, critical &lt; $CriticalPercent%</p>
$summary
<table><tr><th>Server</th><th>Check</th><th>Status</th><th>Detail</th></tr>
$($rows -join "`n")
</table></body></html>
"@
$html | Out-File -FilePath (Join-Path $OutputFolder "ServerHealth_latest.html") -Encoding UTF8

Write-Host "Done. $(@($results).Count) checks, $problems problem(s). Report: $(Join-Path $OutputFolder 'ServerHealth_latest.html')"
