<#
.SYNOPSIS
    Bulk-creates Active Directory users from a CSV file (new starter onboarding).

.DESCRIPTION
    For each row in the CSV, the script:
      - Builds a username in first.last format (lowercase, accents and symbols removed,
        trimmed to the 20-character sAMAccountName limit, numbered if already taken)
      - Skips anyone whose EmployeeID already exists in AD, so the CSV can be re-run safely
      - Creates the account in the department's OU with a temporary password that must be
        changed at first sign-in
      - Adds the user to the department's GG_ group (which gives them their file share access)
      - Logs every action and error to a timestamped log file

    Supports -WhatIf to preview changes without making them.

.PARAMETER CsvPath
    Path to the CSV. Required columns: EmployeeID, FirstName, LastName, Department, Title

.PARAMETER LogFolder
    Folder for log files. Defaults to C:\Logs\UserLifecycle

.EXAMPLE
    .\New-BulkUsers.ps1 -CsvPath .\data\new-starters.csv -WhatIf
    Shows what would be created, without changing anything.

.EXAMPLE
    .\New-BulkUsers.ps1 -CsvPath .\data\new-starters.csv
    Creates the users. Prompts once for the temporary password.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ })]
    [string]$CsvPath,

    [string]$LogFolder = "C:\Logs\UserLifecycle"
)

# ---------------- Settings ----------------
$DomainDN    = "DC=conorlab,DC=internal"
$UpnSuffix   = "conorlab.internal"
$UsersOU     = "OU=Users,OU=CONORLAB,$DomainDN"
$Company     = "Conor Lab"
$Departments = "Finance","HR","IT","Sales","Operations"
$MaxSamLength = 20

# ---------------- Logging ----------------
if (-not (Test-Path $LogFolder)) { New-Item -Path $LogFolder -ItemType Directory -Force -WhatIf:$false | Out-Null }
$LogFile = Join-Path $LogFolder ("Onboarding_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR")] [string]$Level = "INFO"
    )
    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Add-Content -Path $LogFile -Value $line -WhatIf:$false
    switch ($Level) {
        "ERROR" { Write-Host $line -ForegroundColor Red }
        "WARN"  { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line }
    }
}

# ---------------- Helper functions ----------------
function ConvertTo-PlainName {
    # Removes accents (for example a fada) and anything that isn't a letter or hyphen, then lowercases
    param([string]$Text)
    $normalized = $Text.Normalize([Text.NormalizationForm]::FormD)
    $chars = $normalized.ToCharArray() | Where-Object {
        [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne [Globalization.UnicodeCategory]::NonSpacingMark
    }
    ((-join $chars) -replace "[^a-zA-Z\-]", "").ToLower()
}

function Get-UniqueSamAccountName {
    # Builds first.last, trims it to 20 characters, and adds a number if it's already taken
    param([string]$FirstName, [string]$LastName)

    $base = "{0}.{1}" -f (ConvertTo-PlainName $FirstName), (ConvertTo-PlainName $LastName)
    if ($base.Length -gt $MaxSamLength) { $base = $base.Substring(0, $MaxSamLength).TrimEnd(".","-") }

    $candidate = $base
    $n = 2
    while (Get-ADUser -Filter "SamAccountName -eq '$candidate'" -ErrorAction SilentlyContinue) {
        $suffix = [string]$n
        $trimmed = $base
        if (($base.Length + $suffix.Length) -gt $MaxSamLength) {
            $trimmed = $base.Substring(0, $MaxSamLength - $suffix.Length).TrimEnd(".","-")
        }
        $candidate = "$trimmed$suffix"
        $n++
    }
    return $candidate
}

# ---------------- Main ----------------
Write-Log "Onboarding started. CSV: $CsvPath. WhatIf: $([bool]$WhatIfPreference)"

$rows = Import-Csv -Path $CsvPath -Encoding UTF8
$requiredColumns = "EmployeeID","FirstName","LastName","Department","Title"
$missing = $requiredColumns | Where-Object { $_ -notin $rows[0].PSObject.Properties.Name }
if ($missing) {
    Write-Log "CSV is missing required column(s): $($missing -join ', '). Nothing was created." "ERROR"
    return
}

$password = Read-Host -AsSecureString "Temporary password for new users"
$results  = @()

foreach ($row in $rows) {
    $fullName = "$($row.FirstName) $($row.LastName)".Trim()
    $result = [pscustomobject]@{
        EmployeeID     = $row.EmployeeID
        Name           = $fullName
        Department     = $row.Department
        SamAccountName = $null
        Status         = $null
        Detail         = $null
    }

    try {
        # 1. Basic validation
        if ([string]::IsNullOrWhiteSpace($row.FirstName) -or [string]::IsNullOrWhiteSpace($row.LastName) -or [string]::IsNullOrWhiteSpace($row.EmployeeID)) {
            throw "Missing EmployeeID, FirstName or LastName"
        }
        if ($row.Department -notin $Departments) {
            throw "Unknown department '$($row.Department)'. Valid: $($Departments -join ', ')"
        }

        # 2. Skip if this employee already has an account (makes re-runs safe)
        $existing = Get-ADUser -Filter "EmployeeID -eq '$($row.EmployeeID)'" -ErrorAction SilentlyContinue
        if ($existing) {
            $result.SamAccountName = $existing.SamAccountName
            $result.Status = "Skipped"
            $result.Detail = "EmployeeID already exists"
            Write-Log "SKIP  $fullName ($($row.EmployeeID)): already exists as $($existing.SamAccountName)" "WARN"
            $results += $result
            continue
        }

        # 3. Work out username and target OU
        $sam  = Get-UniqueSamAccountName -FirstName $row.FirstName -LastName $row.LastName
        $ou   = "OU=$($row.Department),$UsersOU"
        $result.SamAccountName = $sam

        # 4. Create the account and add it to the department group
        if ($PSCmdlet.ShouldProcess("$fullName ($sam) in $ou", "Create AD user")) {
            New-ADUser -Name $fullName `
                -GivenName $row.FirstName -Surname $row.LastName `
                -DisplayName $fullName `
                -SamAccountName $sam -UserPrincipalName "$sam@$UpnSuffix" `
                -EmployeeID $row.EmployeeID `
                -Department $row.Department -Title $row.Title -Company $Company `
                -Path $ou `
                -AccountPassword $password -ChangePasswordAtLogon $true -Enabled $true `
                -ErrorAction Stop

            Add-ADGroupMember -Identity "GG_$($row.Department)" -Members $sam -ErrorAction Stop

            $result.Status = "Created"
            Write-Log "OK    $fullName -> $sam ($($row.Department)), added to GG_$($row.Department)"
        }
        else {
            $result.Status = "WhatIf"
            $result.Detail = "Would create $sam in $($row.Department)"
        }
    }
    catch {
        $result.Status = "Failed"
        $result.Detail = $_.Exception.Message
        Write-Log "FAIL  $fullName ($($row.EmployeeID)): $($_.Exception.Message)" "ERROR"
    }

    $results += $result
}

# ---------------- Summary ----------------
$created = @($results | Where-Object Status -eq "Created").Count
$skipped = @($results | Where-Object Status -eq "Skipped").Count
$failed  = @($results | Where-Object Status -eq "Failed").Count
$preview = @($results | Where-Object Status -eq "WhatIf").Count
Write-Log "Finished. Created: $created  Would create (WhatIf): $preview  Skipped: $skipped  Failed: $failed. Log: $LogFile"

$results | Format-Table EmployeeID, Name, Department, SamAccountName, Status, Detail -AutoSize | Out-String -Width 200 | Write-Host
