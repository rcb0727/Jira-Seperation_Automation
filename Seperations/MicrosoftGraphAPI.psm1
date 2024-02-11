﻿# MicrosoftGraphAPI

# Authentication for Microsoft Graph API
function Get-IntuneAccessToken {
    $authority = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
    $authBody = @{
        "grant_type" = "client_credentials"
        "client_id" = $clientId
        "client_secret" = $clientSecret
        "scope" = $scope
    }

    try {
        $authResponse = Invoke-RestMethod -Method Post -Uri $authority -Body $authBody
        return $authResponse.access_token
    } catch {
        Write-Warning "Failed to get access token: $($_.Exception.Message)"
        exit
    }
}

# Function to get device details from Intune
function Get-IntuneDeviceDetails {
    param (
        [Parameter(Mandatory = $true)]
        [string]$emailAddress
    )

    $accessToken = Get-IntuneAccessToken
    $headers = @{
        "Authorization" = "Bearer $accessToken"
        "Accept" = "application/json"
    }

    $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=userPrincipalName eq '$emailAddress' and operatingSystem eq 'iOS'&`$select=deviceName,serialNumber"

    try {
        $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
        if ($response.value.Count -gt 0) {
            $deviceDetails = @()
            foreach ($device in $response.value) {
                $deviceDetails += "$($device.deviceName), Serial Number: $($device.serialNumber)"
            }
            if ($deviceDetails.Count -eq 0) {
                return "No iOS devices found in Intune for email: $emailAddress"
            } else {
                return $deviceDetails -join "`r`n"
            }
        } else {
            return "No iOS devices found in Intune for email: $emailAddress"
        }
    } catch {
        return "Failed to get iOS device details: $($_.Exception.Message)"
    }
}

# Function to revoke sign-in sessions for a user
function RevokeGraphSignInSessions {
    param (
        [Parameter(Mandatory = $true)]
        [string]$emailAddress
    )

    $accessToken = Get-IntuneAccessToken
    $headers = @{
        "Authorization" = "Bearer $accessToken"
        "Content-Type" = "application/json"
    }

    $uri = "https://graph.microsoft.com/v1.0/users/$emailAddress/revokeSignInSessions"

    try {
        $response = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers
        return $response.value
    } catch {
        $responseError = $_.Exception.Response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($responseError)
        $responseBody = $reader.ReadToEnd() | ConvertFrom-Json
        $errorMessage = $responseBody.error.message
        Write-Warning "Failed to revoke sign-in sessions: $errorMessage"
    }
}

# Function to enable lost mode on a managed device
function Enable-LostMode {
    param (
        [Parameter(Mandatory = $true)]
        [string]$managedDeviceId,
        [string]$issueKey  # Added parameter for Jira issue key
    )

    $accessToken = Get-IntuneAccessToken
    $headers = @{
        "Authorization" = "Bearer $accessToken"
        "Content-Type" = "application/json"
    }

    $uri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$managedDeviceId/enableLostMode"

    $body = @{
        "message" = "Please contact Help Desk - Refer to $issueKey"  # Custom message
        "phoneNumber" = "323-340-4516"  # phone number
    } | ConvertTo-Json

    try {
        Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $body
        return "Lost mode enabled for device $managedDeviceId with message: 'Please contact Help Desk - Refer to $issueKey'"
    } catch {
        $responseError = $_.Exception.Response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($responseError)
        $responseBody = $reader.ReadToEnd() | ConvertFrom-Json
        $errorMessage = $responseBody.error.message
        Write-Warning "Failed to enable lost mode: $errorMessage"
    }
}

# Function to check and assign license
function CheckAndAssignLicense {
    param (
        [Parameter(Mandatory = $true)]
        [string]$emailAddress
    )

    $accessToken = Get-IntuneAccessToken
    if (-not $accessToken) {
        Write-Host "Failed to obtain access token."
        return
    }

    $headers = @{
        "Authorization" = "Bearer $accessToken"
        "Content-Type" = "application/json"
    }

    # Correctly define SKU IDs for F3 and E3 licenses based on the config
    $F3SkuId = $config.F3SkuId
    $E3SkuId = $config.E3SkuId

    # Check current licenses
    $uriGetLicenses = "https://graph.microsoft.com/v1.0/users/$emailAddress/licenseDetails"
    try {
        $currentLicensesResponse = Invoke-RestMethod -Method Get -Uri $uriGetLicenses -Headers $headers
        $currentLicenses = $currentLicensesResponse.value
        
        # Accurately check for F3 and E3 license presence
        $hasF3 = $currentLicenses.skuId -contains $F3SkuId
        $hasE3 = $currentLicenses.skuId -contains $E3SkuId

        if ($hasF3 -and -not $hasE3) {
            $body = @{
                "addLicenses" = @(@{ "skuId" = $E3SkuId })
                "removeLicenses" = @($F3SkuId)
            } | ConvertTo-Json

            $uriAssignLicense = "https://graph.microsoft.com/v1.0/users/$emailAddress/assignLicense"

            Invoke-RestMethod -Method Post -Uri $uriAssignLicense -Headers $headers -Body $body
            Write-Host "Successfully switched from F3 to E3 for $emailAddress. Waiting for changes to propagate."
            
            # Set global variable to indicate E3 license assignment
            $Global:LicenseChanged = $true
            
            # Wait with progress display
            $duration = 360 # 6 minutes
            $startTime = Get-Date
            for ($i = 0; $i -le $duration; $i++) {
                $percentComplete = ($i / $duration) * 100
                $elapsedTime = (Get-Date) - $startTime
                $statusMessage = "Elapsed time: $($elapsedTime.ToString("hh\:mm\:ss"))"
                Write-Progress -Activity "Waiting..." -Status $statusMessage -PercentComplete $percentComplete -SecondsRemaining ($duration - $i)
                Start-Sleep -Seconds 1
            }
            Write-Progress -Activity "Waiting..." -Completed
            Write-Host "Done waiting."

        } elseif ($hasE3) {
            Write-Host "$emailAddress already has an E3 license."
        } else {
            Write-Host "$emailAddress does not have an F3 license to switch."
        }

    } catch {
        Write-Warning "Failed to check or switch licenses for $emailAddress. Error: $($_.Exception.Message)"
    }

    # Proceed to check and enable litigation hold as necessary
    CheckLitigationHoldStatus -emailAddress $emailAddress
}


# Function to connect to Exchange Online
function ConnectToExchangeOnline {
    try {
        Connect-ExchangeOnline -CertificateThumbprint $config.certThumbprint -AppId $config.clientId -Organization $config.organization -ShowBanner:$false
    } catch {
        Write-Host "Failed to connect to Exchange Online. Error: $($_.Exception.Message)"
        throw "Failed to connect to Exchange Online."
    }
}

# Function to disconnect from Exchange Online
function DisconnectFromExchangeOnline {
    try {
        Disconnect-ExchangeOnline -Confirm:$false
    } catch {
        Write-Host "Failed to disconnect from Exchange Online. Error: $($_.Exception.Message)"
    }
}

# Function to check litigation hold status
function CheckLitigationHoldStatus {
    param (
        [Parameter(Mandatory = $true)]
        [string]$emailAddress
    )
    
    ConnectToExchangeOnline
    
    try {
        $mailbox = Get-Mailbox -Identity $emailAddress -ErrorAction Stop
        Write-Host "Checking litigation hold status for $emailAddress."
    
        if (-not $mailbox.LitigationHoldEnabled) {
            Write-Host "Litigation hold is not enabled."
            return $false
        } else {
            Write-Host "Litigation hold is already enabled."
            return $true
        }
    } catch {
        Write-Host "Failed to check litigation hold status. Error: $($_.Exception.Message)"
        return $null
    } finally {
        DisconnectFromExchangeOnline
    }
}

# Function to enable litigation hold
function EnableLitigationHold {
    param (
        [Parameter(Mandatory = $true)]
        [string]$emailAddress,
        [switch]$Quiet
    )

    ConnectToExchangeOnline
    
    try {
        if (-not $Quiet) {
            Write-Output "Enabling litigation hold."
        }
        Set-Mailbox -Identity $emailAddress -LitigationHoldEnabled $true
        # Litigation hold has been enabled successfully
        return $true
    } catch {
        if (-not $Quiet) {
            Write-Output "Failed to enable litigation hold. Error: $($_.Exception.Message)"
        }
        # Failed to enable litigation hold
        return $false
    } finally {
        DisconnectFromExchangeOnline
    }
}



# Function to revert license after litigation hold
function RevertLicenseAfterLitigationHold {
    param (
        [Parameter(Mandatory = $true)]
        [string]$emailAddress
    )

    if ($Global:LicenseChanged -eq $true) {
        $accessToken = Get-IntuneAccessToken
        if (-not $accessToken) {
            Write-Host "Failed to obtain access token."
            return
        }

        $headers = @{
            "Authorization" = "Bearer $accessToken"
            "Content-Type" = "application/json"
        }

        Write-Host "Waiting to ensure all previous changes have propagated..."
        $duration = 360 # Adjust as needed for propagation time
        $startTime = Get-Date

        for ($i = 0; $i -le $duration; $i++) {
            $percentComplete = ($i / $duration) * 100
            $elapsedTime = (Get-Date) - $startTime
            $statusMessage = "Elapsed time: $($elapsedTime.ToString("hh\:mm\:ss"))"
            Write-Progress -Activity "Waiting for propagation..." -Status $statusMessage -PercentComplete $percentComplete -SecondsRemaining ($duration - $i)
            Start-Sleep -Seconds 1
        }
        Write-Progress -Activity "Waiting for propagation..." -Completed

        Write-Host "Initiating license reversion from E3 to F3 for $emailAddress..."

        $uriAssignLicense = "https://graph.microsoft.com/v1.0/users/$emailAddress/assignLicense"
        $body = @{
            "addLicenses" = @( @{ "skuId" = $config.F3SkuId } ) # F3 SKU ID from config
            "removeLicenses" = @( $config.E3SkuId ) # E3 SKU ID from config
        } | ConvertTo-Json

        try {
            $response = Invoke-RestMethod -Method Post -Uri $uriAssignLicense -Headers $headers -Body $body
            Write-Host "License successfully reverted from E3 to F3 for $emailAddress."
        } catch {
            $errorMessage = $_.Exception.Message
            Write-Warning "Failed to revert license for $emailAddress. Error: $errorMessage"
        }
    } else {
        Write-Host "No license change detected for $emailAddress, skipping reversion."
    }
}


#Removes Office License
function RemoveLicense {
    param (
        [Parameter(Mandatory = $true)]
        [string]$emailAddress
    )

    if ($Global:LicenseChanged -eq $true) {
        $accessToken = Get-IntuneAccessToken
        if (-not $accessToken) {
            Write-Host "Failed to obtain access token."
            return
        }

        $headers = @{
            "Authorization" = "Bearer $accessToken"
            "Content-Type" = "application/json"
        }

        Write-Host "Initiating license removal for $emailAddress..."

        if (UserHasLicense -emailAddress $emailAddress -skuId $config.E3SkuId) {
            # Remove E3 license
            RemoveLicenseFromUser -emailAddress $emailAddress -skuToRemove $config.E3SkuId
            Write-Host "E3 license successfully removed for $emailAddress."
        } elseif (UserHasLicense -emailAddress $emailAddress -skuId $config.F3SkuId) {
            # Remove F3 license
            RemoveLicenseFromUser -emailAddress $emailAddress -skuToRemove $config.F3SkuId
            Write-Host "F3 license successfully removed for $emailAddress."
        } else {
            Write-Host "No applicable license found for $emailAddress, skipping removal."
        }
    } else {
        Write-Host "No license change detected for $emailAddress, skipping removal."
    }
}

Export-ModuleMember -Function 'Get-IntuneAccessToken', 'Get-IntuneDeviceDetails', 'RevokeGraphSignInSessions', 'Enable-LostMode', 'CheckLitigationHoldStatus', 'EnableLitigationHold', 'CheckAndAssignLicense','RevertLicenseAfterLitigationHold', 'RemoveLicense'
