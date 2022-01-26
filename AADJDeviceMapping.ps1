[CmdletBinding(DefaultParameterSetName = 'Default')]
param(
    [Parameter(Mandatory=$False)] [String] $TenantId = "",
    [Parameter(Mandatory=$False)] [String] $ClientId = "",
    [Parameter(Mandatory=$False)] [String] $ClientSecret = "",
    [Parameter(Mandatory=$False)] [Switch] $NameMap
)

# Get NuGet
Get-PackageProvider -Name "NuGet" -Force | Out-Null

# Get WindowsAutopilotIntune module (and dependencies)
$module = Import-Module WindowsAutopilotIntune -PassThru -ErrorAction Ignore
if (-not $module) {
    Write-Host "Installing module WindowsAutopilotIntune"
    Install-Module WindowsAutopilotIntune -Force -AllowClobber
}
Import-Module WindowsAutopilotIntune -Scope Global

# Connect to MSGraph with application credentials
Connect-MSGraphApp -Tenant $TenantId -AppId $ClientId -AppSecret $ClientSecret

# Pull latest Autopilot device information
$AutopilotDevices = Get-AutopilotDevice | Select-Object azureActiveDirectoryDeviceId,groupTag
$AUTOPILOTPCS = $AutopilotDevices | Where-Object -FilterScript {$_.groupTag -like "<GROUPTAG>*"}

# Set the OU for computer object creation
$orgUnit = "OU=Dummy-ComputersAADJ,DC=ad,DC=<DOMAIN>,DC=com" 

# Set the certificate path for name mapping
$certPath = "X509:<I>DC=com,DC=<DOMAIN>,DC=ad,CN=<CA NAME>A" 

# Create new Autopilot computer objects in AD while skipping already existing computer objects
foreach ($Device in $AUTOPILOTPCS) {
    if (Get-ADComputer -Filter "Name -eq ""$($Device.azureActiveDirectoryDeviceId)""" -SearchBase $orgUnit -ErrorAction SilentlyContinue) {
        Write-Host "Skipping $($Device.azureActiveDirectoryDeviceId) because it already exists. " -ForegroundColor Yellow
    } else {
        # Create new AD computer object
        try {
            New-ADComputer -Name "$($Device.azureActiveDirectoryDeviceId)" -SAMAccountName "$($Device.azureActiveDirectoryDeviceId.Substring(0,15))`$" -ServicePrincipalNames "HOST/$($Device.azureActiveDirectoryDeviceId)" -Path $orgUnit
            Write-Host "Computer object created. ($($Device.azureActiveDirectoryDeviceId))" -ForegroundColor Green
        } catch {
            Write-Host "Error. Skipping computer object creation." -ForegroundColor Red
        }
        
        # Perform name mapping
        try {
            $subject = $Device.azureActiveDirectoryDeviceId
            $Cert = "X509:<I>DC=com,DC=<DOMAIN>,DC=ad,CN=<CA NAME<S>CN=$subject"
            Set-ADComputer -Identity "$($Device.azureActiveDirectoryDeviceId.Substring(0,15))" -Add @{'altSecurityIdentities'="$Cert"}
            Write-Host "Name mapping for computer object done. ($($certPath)$($Device.azureActiveDirectoryDeviceId))" -ForegroundColor Green
        } catch {
            Write-Host "Error. Skipping name mapping." -ForegroundColor Red
        }
    }
}


# Reverse the process and remove any dummmy computer objects in AD that are no longer in Autopilot
$DummyDevices = Get-ADComputer -Filter * -SearchBase $orgUnit | Select-Object Name, SAMAccountName
foreach ($DummyDevice in $DummyDevices) {
	if ($AutopilotDevices.azureActiveDirectoryDeviceId -contains $DummyDevice.Name) {
         Write-Host "$($DummyDevice.Name) exists in Autopilot." -ForegroundColor Green
    } else {
        Write-Host "$($DummyDevice.Name) does not exist in Autopilot." -ForegroundColor Yellow
        Remove-ADComputer -Identity $DummyDevice.SAMAccountName -Confirm:$False 
        #Remove -WhatIf once you are comfortrable with this workflow and have verified the remove operations are only performed in the OU you specified
    }
}

#Force Replication for all Domain Controllers
(Get-ADDomainController -Filter *).Name | Foreach-Object { repadmin /syncall $_ (Get-ADDomain).DistinguishedName /AdeP }