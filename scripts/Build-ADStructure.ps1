# Build-ADStructure.ps1
# Creates OU structure, department groups, sample users and an admin account for conorlab.internal

$base = "DC=conorlab,DC=internal"
$root = "OU=CONORLAB,$base"
$depts = "Finance","HR","IT","Sales","Operations"

# --- OUs ---
New-ADOrganizationalUnit -Name "CONORLAB" -Path $base
"Users","Computers","Groups","Admin Accounts","Service Accounts","Disabled Users" |
    ForEach-Object { New-ADOrganizationalUnit -Name $_ -Path $root }
$depts | ForEach-Object { New-ADOrganizationalUnit -Name $_ -Path "OU=Users,$root" }
"Workstations","Servers" | ForEach-Object { New-ADOrganizationalUnit -Name $_ -Path "OU=Computers,$root" }
"Security","Distribution" | ForEach-Object { New-ADOrganizationalUnit -Name $_ -Path "OU=Groups,$root" }

# --- Department security groups ---
$depts | ForEach-Object {
    New-ADGroup -Name "GG_$_" -GroupScope Global -GroupCategory Security `
        -Path "OU=Security,OU=Groups,$root" -Description "All $_ staff"
}

# --- Sample users (2 per department) ---
$pw = Read-Host -AsSecureString "Initial password for new users"

$users = @(
    @{First="Aoife";   Last="Byrne";    Dept="Finance";    Title="Accountant"}
    @{First="Ciaran";  Last="Walsh";    Dept="Finance";    Title="Finance Manager"}
    @{First="Niamh";   Last="Kelly";    Dept="HR";         Title="HR Officer"}
    @{First="Darragh"; Last="Ryan";     Dept="HR";         Title="HR Manager"}
    @{First="Sean";    Last="Murphy";   Dept="IT";         Title="IT Support Engineer"}
    @{First="Orla";    Last="Doyle";    Dept="IT";         Title="Systems Administrator"}
    @{First="Cian";    Last="OBrien";   Dept="Sales";      Title="Sales Executive"}
    @{First="Sinead";  Last="Kennedy";  Dept="Sales";      Title="Sales Manager"}
    @{First="Eoin";    Last="Gallagher";Dept="Operations"; Title="Operations Coordinator"}
    @{First="Roisin";  Last="McCarthy"; Dept="Operations"; Title="Operations Manager"}
)

foreach ($u in $users) {
    $sam = ("{0}.{1}" -f $u.First, $u.Last).ToLower()
    New-ADUser -Name "$($u.First) $($u.Last)" `
        -GivenName $u.First -Surname $u.Last `
        -SamAccountName $sam -UserPrincipalName "$sam@conorlab.internal" `
        -DisplayName "$($u.First) $($u.Last)" `
        -Department $u.Dept -Title $u.Title -Company "Conor Lab" `
        -Path "OU=$($u.Dept),OU=Users,$root" `
        -AccountPassword $pw -Enabled $true -ChangePasswordAtLogon $true
    Add-ADGroupMember -Identity "GG_$($u.Dept)" -Members $sam
    Write-Host "Created $sam in $($u.Dept)"
}

# --- Your own accounts: a normal user and a separate admin ---
New-ADUser -Name "Conor Harkin" -SamAccountName "conor.harkin" `
    -UserPrincipalName "conor.harkin@conorlab.internal" -Department "IT" `
    -Path "OU=IT,OU=Users,$root" -AccountPassword $pw -Enabled $true
Add-ADGroupMember -Identity "GG_IT" -Members "conor.harkin"

$adminPw = Read-Host -AsSecureString "Password for conor.harkin.admin (admin account)"
New-ADUser -Name "Conor Harkin (Admin)" -SamAccountName "conor.harkin.admin" `
    -UserPrincipalName "conor.harkin.admin@conorlab.internal" `
    -Path "OU=Admin Accounts,$root" -AccountPassword $adminPw -Enabled $true
Add-ADGroupMember -Identity "Domain Admins" -Members "conor.harkin.admin"

# --- New computers joined to the domain land in Workstations instead of the default container ---
redircmp "OU=Workstations,OU=Computers,$root"