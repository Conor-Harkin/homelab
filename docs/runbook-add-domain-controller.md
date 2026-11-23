# Runbook: Adding a domain controller and checking AD health

| | |
|---|---|
| **Purpose** | Add an additional domain controller (DC) to the existing `conorlab.internal` domain, then confirm AD, DNS and replication are healthy. |
| **When to use** | Adding redundancy, replacing an old DC, or adding a DC at a new site. |
| **Time** | About 1.5 hours (most of it is install time) |
| **Last tested** | November 2026, adding DC02 (Server Core) alongside DC01 |

---

## 1. Prerequisites

- [ ] At least one healthy existing DC is online (`dcdiag` passes on it).
- [ ] A free static IP in the DC range (10.10.10.10–19) and a name following the naming convention (`DCxx`).
- [ ] An account in **Domain Admins** (for example `CONORLAB\conor.harkin.admin`).
- [ ] The **DSRM password** (keep the same one across DCs, stored in the password manager).
- [ ] Windows Server 2025 ISO (Server Core recommended for DCs).
- [ ] A snapshot or backup of the existing DC(s) taken before you start.

**Values used in this runbook** (change them for the new DC):

| Item | Value |
|---|---|
| New DC name | `DC02` |
| New DC IP | `10.10.10.11/24` |
| Gateway | `10.10.10.1` |
| Existing DC | `dc01.conorlab.internal` (10.10.10.10) |
| Domain | `conorlab.internal` |

---

## 2. Build the server

1. Create the VM: 2 vCPU, 2 GB RAM (Core) or 4 GB (Desktop Experience), 60 GB disk, network **LabNet**.
2. Install **Windows Server 2025 Standard** (the edition *without* Desktop Experience, for Server Core).
3. Set the local Administrator password at first sign-in.
4. In SConfig, choose **15** to open PowerShell.

## 3. Configure the network

Point DNS at the **existing DC**. The new server must use AD DNS to find the domain.

```powershell
New-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress 10.10.10.11 -PrefixLength 24 -DefaultGateway 10.10.10.1
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses 10.10.10.10
Set-TimeZone -Id "GMT Standard Time"
```

**Check:** the server can find a domain controller.
```powershell
Resolve-DnsName _ldap._tcp.dc._msdcs.conorlab.internal -Type SRV
```
✅ Returns `dc01.conorlab.internal` on port 389.

## 4. Rename and join the domain

```powershell
Add-Computer -NewName "DC02" -DomainName "conorlab.internal" -Credential CONORLAB\conor.harkin.admin -Restart
```

After the reboot, sign in as the domain admin. On Server Core: press **Esc**, choose **Other user**, and enter `CONORLAB\conor.harkin.admin`.

> The computer account appears in `OU=Workstations` (because of `redircmp`). Promotion moves it to the **Domain Controllers** OU automatically.

## 5. Install the AD DS role

Locally on the new server, or remotely from an existing DC:
```powershell
Install-WindowsFeature AD-Domain-Services -IncludeManagementTools -ComputerName dc02.conorlab.internal
```
✅ `Success: True`

## 6. Promote to a domain controller

Run on the new server's console, **or** from an existing DC inside `Enter-PSSession -ComputerName dc02.conorlab.internal`.

> **Over PowerShell remoting, always pass `-Credential`.** Without it, the Kerberos double hop stops the new server from checking your permissions against the existing DC (see Troubleshooting).

**Dry run first:**
```powershell
Test-ADDSDomainControllerInstallation -DomainName "conorlab.internal" -InstallDns -Credential (Get-Credential CONORLAB\conor.harkin.admin)
```
✅ All tests completed successfully. The "delegation for this DNS server cannot be created" warning is expected and safe to ignore.

**Promote:**
```powershell
Install-ADDSDomainController -DomainName "conorlab.internal" -InstallDns -ReplicationSourceDC "dc01.conorlab.internal" -Credential (Get-Credential CONORLAB\conor.harkin.admin)
```
- Enter the DSRM password twice and confirm with **Y**.
- The server replicates AD from the source DC, then reboots. The first boot can take several minutes. Don't power it off.
- A remote session will drop with a connection error. That's expected.

## 7. Post-promotion configuration

**On the new DC:** point to its partner DC first and itself second, and add DNS forwarders (forwarders are per server and aren't replicated).
```powershell
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses 10.10.10.10,127.0.0.1
Add-DnsServerForwarder -IPAddress 1.1.1.1,8.8.8.8
```

**On the existing DC:** add the new DC as its secondary DNS server.
```powershell
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses 10.10.10.10,10.10.10.11
```

**In DHCP:** give clients both DNS servers (option 006).
```powershell
Set-DhcpServerv4OptionValue -ScopeId 10.10.10.0 -DnsServer 10.10.10.10,10.10.10.11
```

---

## 8. Health checks

Run from an existing DC.

| Check | Command | Expected result |
|---|---|---|
| Replication summary | `repadmin /replsummary` | **0 fails** for every DC |
| Replication per partition | `repadmin /showrepl` | Every partition shows *"was successful"* |
| Overall DC health | `dcdiag` | No tests marked **failed** (some warnings are normal in a lab) |
| DNS health | `dcdiag /test:dns` | Passes on all DCs |
| New DC registered in DNS | `Resolve-DnsName _ldap._tcp.dc._msdcs.conorlab.internal -Type SRV` | **Both** DCs returned |
| FSMO role holders | `netdom query fsmo` | All five roles held by an online DC |
| All DCs listed | `Get-ADDomainController -Filter * \| Select Name, IPv4Address, IsGlobalCatalog` | New DC listed, `IsGlobalCatalog: True` |

**Prove replication end to end:**
```powershell
New-ADUser -Name "Repl Test" -SamAccountName "repl.test" -Path "OU=IT,OU=Users,OU=CONORLAB,DC=conorlab,DC=internal"
Get-ADUser repl.test -Server dc02.conorlab.internal
Remove-ADUser repl.test -Confirm:$false
```
✅ The new DC returns the test user. If it doesn't yet, force a sync with `repadmin /syncall /AdeP` and check again.

---

## 9. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Verification of user credential permissions failed. Failed to examine the Active Directory forest` (when promoting over remoting) | **Kerberos double hop**: your credentials aren't forwarded from the new server to the existing DC | Add `-Credential (Get-Credential DOMAIN\admin)` to the command, or run it on the new server's console |
| `DNS name does not exist` on the SRV lookup | Usually a typo. The record is `_ldap._tcp.dc._msdcs.<domain>` (note the underscore before `msdcs`) | Retype it. If it still fails, check the server's DNS points at the existing DC |
| `A positional parameter cannot be found that accepts argument...` | A typo in a parameter name (for example `_DomainName` instead of `-DomainName`) | Use **Tab** to autocomplete parameter names |
| Domain join fails / "domain could not be contacted" | The new server isn't using AD DNS | `Set-DnsClientServerAddress` to the existing DC's IP |
| Replication errors in `repadmin` straight after promotion | Replication hasn't finished its first cycle | Wait a few minutes, then `repadmin /syncall /AdeP` |
| Kerberos / logon errors, "clock skew" | Time differs by more than 5 minutes between machines | Check time on both DCs (`w32tm /query /status`). The PDC Emulator is the domain's time source |
| No copy and paste on Server Core VM | VirtualBox clipboard sharing needs a desktop session | Manage the server remotely from another DC with `Enter-PSSession` / `Invoke-Command` |

---

## 10. Rollback

If the new DC has problems and needs removing:

1. **If it's still working:** demote it cleanly.
   ```powershell
   Uninstall-ADDSDomainController -Credential (Get-Credential CONORLAB\conor.harkin.admin)
   ```
   Then remove it from the domain and delete the VM.
2. **If it's dead:** don't bring it back online. On a healthy DC, remove its metadata: in *Active Directory Users and Computers*, delete its computer object from the **Domain Controllers** OU and confirm the metadata cleanup prompt. Then remove its DNS records (A, SRV and NS) and its server object in *Active Directory Sites and Services*.
3. Point any DNS settings and DHCP option 006 back to the remaining DC(s).
4. If it held any FSMO roles, **seize** them onto a healthy DC:
   ```powershell
   Move-ADDirectoryServerOperationMasterRole -Identity "DC01" -OperationMasterRole RIDMaster, PDCEmulator, InfrastructureMaster, SchemaMaster, DomainNamingMaster -Force
   ```

---

## 11. Sign-off checklist

- [ ] New DC joined, promoted and in the **Domain Controllers** OU
- [ ] DNS on both DCs configured (partner first, self second), with forwarders on the new DC
- [ ] DHCP option 006 includes the new DC
- [ ] `repadmin /replsummary` shows 0 fails
- [ ] `dcdiag` shows no failed tests
- [ ] Test user replicated and deleted
- [ ] Snapshot or backup of all DCs taken after the change
- [ ] Commands saved to `scripts/` and README updated
