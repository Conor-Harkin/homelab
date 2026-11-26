<#
.SYNOPSIS
    Offboards leavers: disables their AD account, removes group access and moves it to Disabled Users.

.DESCRIPTION
    For each user, the script:
      - Refuses to touch admin or built-in accounts (safety check)
      - Saves the user's group memberships to a CSV, so access can be restored if needed
      - Disables the account and resets the password to a long random value
      - Removes the user from every group (except Domain Users, their primary group)
      - Stamps the description with the date, who did it and the ticket number
      - Moves the account to the Disabled Users OU
      - Logs every action and error to a timestamped log file

    Supports -WhatIf to preview changes without making them.

.PARAMETER Identity
    One or more usernames (sAMAccountName) to offboard.

.PARAMETER Ticket
    Optional ticket or change reference, recorded in the account description and log.

.PARAMETER LogFolder
    Folder for logs and group backups. Defaults to C:\Logs\UserLifecycle

.EXAMPLE
    .\Disable-LeaverAccount.ps1 -Identity laura.quinn -Ticket INC1001 -WhatIf
    Shows what would happen, without changing anything.

.EXAMPLE
    .\Disable-LeaverAccount.ps1 -Identity laura.quinn, sean.oneill -Ticket INC1002
    Offboards two users.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string[]]$Identity,

    [string]$Ticket = "None",

    [string]$LogFolder = "C:\Logs\UserLifecycle"
)

# ---------------- Settings ----------------
$DomainDN     = "DC=conorlab,DC=internal"
$DisabledOU   = "OU=Disabled Users,OU=CONORLAB,$DomainDN"
$AdminOU      = "OU=Admin Accounts,OU=CONORLAB,$DomainDN"
$ProtectedGroups = "Domain Admins","Enterprise Admins","Schema Admins","Administrators"
$ProtectedUsers  = "Administrator","krbtgt","Guest"

# ---------------- Logging ----------------
if (-not (Test-Path $LogFolder)) { New-Item -Path $LogFolder -ItemType Directory -Force -WhatIf:$false | Out-Null }
$Stamp   = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile = Join-Path $LogFolder "Offboarding_$Stamp.log"

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

function New-RandomPassword {
    # 28 random characters, plus one of each type so it always meets complexity rules
    $chars = (33..126 | ForEach-Object { [char]$_ })
    $random = -join (1..24 | ForEach-Object { $chars | Get-Random })
    ConvertTo-SecureString ("Aa1!" + $random) -AsPlainText -Force
}

# ---------------- Main ----------------
Write-Log "Offboarding started by $env:USERNAME. Users: $($Identity -join ', '). Ticket: $Ticket. WhatIf: $([bool]$WhatIfPreference)"
$results = @()

foreach ($id in $Identity) {
    $result = [pscustomobject]@{
        User          = $id
        Status        = $null
        GroupsRemoved = 0
        Detail        = $null
    }

    try {
        # 1. Find the user
        $user = Get-ADUser -Identity $id -Properties MemberOf, Enabled, DistinguishedName -ErrorAction Stop
        $sam  = $user.SamAccountName

        # 2. Safety checks
        if ($sam -in $ProtectedUsers) { throw "Refusing to offboard built-in account '$sam'" }
        if ($user.DistinguishedName -like "*$AdminOU") { throw "Refusing to offboard admin account '$sam'. Do this manually." }
        $groupNames = @($user.MemberOf | ForEach-Object { ($_ -split ",")[0] -replace "^CN=", "" })
        $privileged = $groupNames | Where-Object { $_ -in $ProtectedGroups }
        if ($privileged) { throw "Refusing to offboard '$sam': member of privileged group(s) $($privileged -join ', ')" }
        if ($user.DistinguishedName -like "*$DisabledOU") {
            $result.Status = "Skipped"
            $result.Detail = "Already in Disabled Users"
            Write-Log "SKIP  $sam is already in Disabled Users" "WARN"
            $results += $result
            continue
        }

        if ($PSCmdlet.ShouldProcess($sam, "Disable, remove $($groupNames.Count) group(s), move to Disabled Users")) {

            # 3. Back up group memberships so access can be restored if needed
            $backupFile = Join-Path $LogFolder "GroupBackup_${sam}_$Stamp.csv"
            $user.MemberOf | ForEach-Object { [pscustomobject]@{ User = $sam; GroupDN = $_ } } |
                Export-Csv -Path $backupFile -NoTypeInformation
            Write-Log "      $sam group backup saved: $backupFile"

            # 4. Disable and scramble the password
            Disable-ADAccount -Identity $sam -ErrorAction Stop
            Set-ADAccountPassword -Identity $sam -Reset -NewPassword (New-RandomPassword) -ErrorAction Stop
            Write-Log "      $sam disabled and password reset"

            # 5. Remove from all groups (Domain Users is the primary group and can't be removed)
            foreach ($groupDN in $user.MemberOf) {
                Remove-ADGroupMember -Identity $groupDN -Members $sam -Confirm:$false -ErrorAction Stop
                $result.GroupsRemoved++
                Write-Log "      $sam removed from $((($groupDN -split ',')[0]) -replace '^CN=', '')"
            }

            # 6. Record who, when and why
            $note = "Disabled $(Get-Date -Format 'yyyy-MM-dd') by $env:USERNAME. Ticket: $Ticket"
            Set-ADUser -Identity $sam -Description $note -ErrorAction Stop

            # 7. Move to Disabled Users
            Move-ADObject -Identity $user.DistinguishedName -TargetPath $DisabledOU -ErrorAction Stop

            $result.Status = "Offboarded"
            Write-Log "OK    $sam offboarded ($($result.GroupsRemoved) group(s) removed, moved to Disabled Users)"
        }
        else {
            $result.Status = "WhatIf"
            $result.Detail = "Would disable and remove from: $($groupNames -join ', ')"
        }
    }
    catch {
        $result.Status = "Failed"
        $result.Detail = $_.Exception.Message
        Write-Log "FAIL  ${id}: $($_.Exception.Message)" "ERROR"
    }

    $results += $result
}

# ---------------- Summary ----------------
$done    = @($results | Where-Object Status -eq "Offboarded").Count
$preview = @($results | Where-Object Status -eq "WhatIf").Count
$skipped = @($results | Where-Object Status -eq "Skipped").Count
$failed  = @($results | Where-Object Status -eq "Failed").Count
Write-Log "Finished. Offboarded: $done  Would offboard (WhatIf): $preview  Skipped: $skipped  Failed: $failed. Log: $LogFile"

$results | Format-Table User, Status, GroupsRemoved, Detail -AutoSize | Out-String -Width 200 | Write-Host
