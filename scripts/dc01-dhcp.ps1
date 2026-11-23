# DC01 - DHCP server configuration

# Install DHCP and authorise it in Active Directory
Install-WindowsFeature DHCP -IncludeManagementTools
Add-DhcpServerInDC -DnsName "dc01.conorlab.internal" -IPAddress 10.10.10.10
netsh dhcp add securitygroups
Restart-Service DHCPServer
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12" -Name ConfigurationState -Value 2

# Scope: 10.10.10.100-200, 8-day lease
Add-DhcpServerv4Scope -Name "LabNet Clients" -StartRange 10.10.10.100 -EndRange 10.10.10.200 -SubnetMask 255.255.255.0 -LeaseDuration 8.00:00:00 -State Active

# Exclusion: .100-.109 kept for static devices
Add-DhcpServerv4ExclusionRange -ScopeId 10.10.10.0 -StartRange 10.10.10.100 -EndRange 10.10.10.109

# Options: 003 router, 006 DNS, 015 DNS domain name
Set-DhcpServerv4OptionValue -ScopeId 10.10.10.0 -Router 10.10.10.1 -DnsServer 10.10.10.10 -DnsDomain "conorlab.internal"

# Reservation for CL01
Add-DhcpServerv4Reservation -ScopeId 10.10.10.0 -IPAddress 10.10.10.150 -ClientId "08-00-27-F5-A4-13" -Name "CL01" -Description "Reserved for CL01"

# Verify
Get-DhcpServerv4OptionValue -ScopeId 10.10.10.0
Get-DhcpServerv4Lease -ScopeId 10.10.10.0
Get-DhcpServerv4Reservation -ScopeId 10.10.10.0