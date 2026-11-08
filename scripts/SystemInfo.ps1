# Get-SystemInfo.ps1
# Collect local Windows system information and export two CSV reports.
#
# Computer Name $cs.Name
# Manufactorer $cs.Manufacturer
# Make
# Model $cs.Model
# OS Caption
# Last boot time LastBootUpTime
# memory cs.TotalPhysicalMemory
# Fixed drive space Size
# Free drive space FreeSpace
#


$os = Get-CimInstance -ClassName Win32_OperatingSystem 
$cs = Get-CimInstance -ClassName Win32_ComputerSystem 
$drive = Get-CimInstance -ClassName Win32_LogicalDisk |
    Where-Object { $_.DeviceID -eq 'C:' }

$systemReport = [pscustomobject]@{
    ComputerName = $cs.Name
    Manufacturer = $cs.Manufacturer
    Model        = $cs.Model
    RAMGB        = [math]::Round($cs.TotalPhysicalMemory / 1GB, 2)
    OS           = $os.Caption
    OSVersion    = $os.Version
    LastBoot     = $os.LastBootUpTime
    Drive	 = $drive.DeviceID
    DriveSpace   = [math]::Round($drive.size / 1GB, 2) 
    FreeSpace	 = [math]::Round($drive.FreeSpace / 1GB, 2) 

    
		 
}



$systemReport |
 Export-Csv -Path "C:\Users\conor.harkin\Desktop\Powershell\Scripts\SystemInfo\SystemReport.csv" -NoTypeInformation

