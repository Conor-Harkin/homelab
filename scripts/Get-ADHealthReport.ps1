<#
.SYNOPSIS
    Produces an HTML report of common Active Directory security and hygiene issues.

.DESCRIPTION
    Reports on:
      - Stale accounts: enabled users who haven't signed in for X days (or never have)
      - Enabled users whose password never expires
      - Members of Domain Admins (including nested members)
      - Locked-out accounts
    Saves an HTML report (and a CSV per section) to the output folder.

    Note: LastLogonDate comes from lastLogonTimestamp, which only replicates every
    9-14 days, so it's accurate for "stale for 90 days" reporting but not to the day.

.PARAMETER StaleDays
    Accounts with no sign-in for this many days are reported as stale. Default 90.

.PARAMETER SearchBase
    Where to look for user accounts. Default: the CONORLAB OU.

.PARAMETER OutputFolder
    Where to save the report. Default C:\Reports

.PARAMETER Open
    Opens the HTML report when finished.

.EXAMPLE
    .\Get-ADHealthReport.ps1 -Open

.EXAMPLE
    .\Get-ADHealthReport.ps1 -StaleDays 1 -Open
    Lab test: flags anyone who hasn't signed in today.
#>

[CmdletBinding()]
param(
    [int]$StaleDays = 90,
    [string]$SearchBase = "OU=CONORLAB,DC=conorlab,DC=internal",
    [string]$OutputFolder = "C:\Reports",
    [switch]$Open
)

if (-not (Test-Path $OutputFolder)) { New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null }
$Stamp  = Get-Date -Format "yyyyMMdd_HHmm"
$Cutoff = (Get-Date).AddDays(-$StaleDays)
$Props  = "LastLogonDate","whenCreated","PasswordLastSet","PasswordNeverExpires","Enabled","Department","Description"

Write-Host "Collecting data from AD..."

# 1. Stale accounts: enabled, and either last sign-in before the cutoff or never signed in
#    (accounts created before the cutoff that have never been used)
$allUsers = Get-ADUser -Filter 'Enabled -eq $true' -SearchBase $SearchBase -Properties $Props
$stale = $allUsers | Where-Object {
    ($_.LastLogonDate -and $_.LastLogonDate -lt $Cutoff) -or
    (-not $_.LastLogonDate -and $_.whenCreated -lt $Cutoff)
} | Select-Object Name, SamAccountName, Department,
    @{ n = "LastLogon"; e = { if ($_.LastLogonDate) { $_.LastLogonDate.ToString("yyyy-MM-dd") } else { "Never" } } },
    @{ n = "Created";   e = { $_.whenCreated.ToString("yyyy-MM-dd") } } |
    Sort-Object LastLogon

# 2. Enabled accounts whose password never expires
$neverExpires = $allUsers | Where-Object PasswordNeverExpires |
    Select-Object Name, SamAccountName, Department,
    @{ n = "PasswordLastSet"; e = { if ($_.PasswordLastSet) { $_.PasswordLastSet.ToString("yyyy-MM-dd") } else { "Never" } } },
    Description

# 3. Domain Admins, including members of nested groups
$domainAdmins = Get-ADGroupMember -Identity "Domain Admins" -Recursive |
    ForEach-Object { Get-ADUser -Identity $_.SamAccountName -Properties $Props } |
    Select-Object Name, SamAccountName, Enabled,
    @{ n = "LastLogon"; e = { if ($_.LastLogonDate) { $_.LastLogonDate.ToString("yyyy-MM-dd") } else { "Never" } } },
    @{ n = "PasswordLastSet"; e = { if ($_.PasswordLastSet) { $_.PasswordLastSet.ToString("yyyy-MM-dd") } else { "Never" } } }

# 4. Locked-out accounts
$lockedOut = Search-ADAccount -LockedOut -UsersOnly |
    Select-Object Name, SamAccountName, LastLogonDate

# ---------------- Build the HTML report ----------------
function New-Section {
    param([string]$Title, [string]$Explanation, $Data)
    $Data  = @($Data | Where-Object { $_ })
    $count = $Data.Count
    $body = if ($count -gt 0) { $Data | ConvertTo-Html -Fragment } else { "<p class='ok'>Nothing to report.</p>" }
    "<h2>$Title <span class='count'>($count)</span></h2><p class='note'>$Explanation</p>$body"
}

$css = @"
<style>
  body  { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #222; }
  h1    { color: #1F3864; margin-bottom: 4px; }
  h2    { color: #1F3864; border-bottom: 2px solid #1F3864; padding-bottom: 4px; margin-top: 32px; }
  .count{ color: #C00000; }
  .note { color: #555; font-size: 13px; margin-top: 0; }
  .ok   { color: #2E7D32; font-weight: bold; }
  table { border-collapse: collapse; width: 100%; font-size: 14px; }
  th    { background: #1F3864; color: #fff; text-align: left; padding: 6px 10px; }
  td    { padding: 6px 10px; border-bottom: 1px solid #ddd; }
  tr:nth-child(even) td { background: #f4f6fa; }
  .meta { color: #555; font-size: 13px; }
</style>
"@

$sections = @(
    New-Section "Stale accounts" "Enabled users with no sign-in for $StaleDays+ days (or never). Disable or confirm with their manager." $stale
    New-Section "Password never expires" "Enabled users exempt from password expiry. Should only be service accounts, documented." $neverExpires
    New-Section "Domain Admins" "Everyone with full control of the domain, including nested group members. Keep this list as short as possible." $domainAdmins
    New-Section "Locked-out accounts" "Accounts currently locked out by the lockout policy." $lockedOut
)

$html = @"
<html><head><meta charset='utf-8'><title>AD Health Report</title>$css</head><body>
<h1>Active Directory Health Report</h1>
<p class='meta'>Domain: conorlab.internal &nbsp;|&nbsp; Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm') &nbsp;|&nbsp; Run by: $env:USERNAME &nbsp;|&nbsp; Scope: $SearchBase</p>
$($sections -join "`n")
</body></html>
"@

$reportPath = Join-Path $OutputFolder "ADHealthReport_$Stamp.html"
$html | Out-File -FilePath $reportPath -Encoding UTF8

# CSV per section, for anyone who wants to filter in Excel
$stale        | Export-Csv (Join-Path $OutputFolder "Stale_$Stamp.csv") -NoTypeInformation
$neverExpires | Export-Csv (Join-Path $OutputFolder "PasswordNeverExpires_$Stamp.csv") -NoTypeInformation
$domainAdmins | Export-Csv (Join-Path $OutputFolder "DomainAdmins_$Stamp.csv") -NoTypeInformation

Write-Host ("Stale: {0}   Password never expires: {1}   Domain Admins: {2}   Locked out: {3}" -f `
    @($stale).Count, @($neverExpires).Count, @($domainAdmins).Count, @($lockedOut).Count)
Write-Host "Report saved: $reportPath"

if ($Open) { Start-Process $reportPath }
