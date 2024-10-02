<#
.SYNOPSIS
    Update one or more Jamf Configuration Profiles for Nudge with the latest versions of macOS'
.DESCRIPTION
    Nudge Automate Powershell allows you to update one or more Jamf Configuration Profiles
    with the latest macOS versions in moments rather than manually modifying Configuration Profiles
    script parameters or a json file every time Apple releases a new version.

    Configuration for this script is handled via the vars.ps1 variable file. Variables include:
    STRING VARIABLES
        $logPath: The directory where logs will be saved to
        $jamfServer: Your Jamf Server URL
        $clientId: Your Jamf API Cliet ID
        $clientSecret: Your Jamf API Client Secret
        $webhookURL: Your Slack webhook for Nudge Automate notifications
        $aboutUrl: Provide a link to your org's macOS update policy
        $softwareUpdateCatalogURL: Apple's Software Update Catalog URL
    OBJECT VARIABLES
        $targetVersions: Provide the major macOS Version numbers that Nudge should work with.
                --As of October 2024, the major versions are 12, 13, 14, and 15.
                --Apple  supports the latest 3 major versions of macOS
                --macOS 12 is included so that Nudge will push users to update to the latest major version
        $jamfProfiles: Provide the name of the Jamf Configuration Profiles you want to update and how many
        days (int) in the future should be considered the deadline for each configuration profiles 
                --Multiple Profiles are supported, allowing you to set different deadlines. This is useful
                for patching in phases.
.PARAMETER Force
    Force the update to send whether or not there's actually anything to update. If this parameter is used
    on a Configuration Profile with identical macOS version numbers, the deadline will be set according to
    your vars.ps1 file.
.PARAMETER BypassNotification
    Prevents the script from sending a notification to slack.
.NOTES
    Written for Powershell 7 on Debian
#>


[CmdletBinding()]
param (
    [Parameter()]
    [switch]
    $Force,
    [Parameter()]
    [switch]
    $BypassNotification
)

Push-Location $PSScriptRoot
. ./vars.ps1
. ./functions.ps1

if ($jamfServer -notlike "https://*"){$jamfServer = "https://$($jamfServer)"}

Logging -logString "NUDGE AUTOMATE RUN: BEGIN" -logLevel INFORMATION

$token = New-AuthToken
$versionObject = Get-AppleUpdateCatalog -object $targetVersions

$jamfProfiles | ForEach-Object {
    Logging -logString "Working on Profile: $($_.name)" -logLevel INFORMATION
    $profileXml = (Invoke-JamfProfile -ProfileName $_.name -Method GET)
    $configPayload = $profileXml.os_x_configuration_profile.general.payloads
    $updatedPayload = Set-Payload -Payload $configPayload -DeadlineDays $_.deadline -force:$Force
    if ($updatedPayload -eq "No Update"){
        break
    } else {
        $profileXml.os_x_configuration_profile.general.payloads = $updatedPayload.InnerXml
        $profileXml.os_x_configuration_profile.general.redeploy_on_update = "All"
        Invoke-JamfProfile -ProfileName $_.name -Method PUT -XmlPayload $profileXml        
    }
}

if ($BypassNotification){
    exit
}

if ($updatedPayload -eq "No Update"){
     Invoke-SlackMessage
 } else {Invoke-SlackMessage -update}