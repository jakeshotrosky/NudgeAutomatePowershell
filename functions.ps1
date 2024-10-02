function Logging {
    param(
        [Parameter(Mandatory,Position=0)][string]$logString,
        [Parameter(Position=1)][ValidateSet("INFORMATION","WARNING","ERROR")][string]$logLevel,
        [Parameter(Position=2)][switch]$PassThru
    )
    $timeStamp = Get-Date
    $logFile = "$logPath/NudgeAuto.log"
    if (-Not(Test-Path $logFile)){New-Item $logFile}

    if ($logLevel){$logMessage = "${logLevel}-$($timeStamp.ToString("yyyyMMddTHHmmssff")): $logString"}
    else {$logMessage = $logString}

    if ($logLevel -in "WARNING","ERROR"){
        $arrayMessage = "$logMessage`n--Computer Name: $(($workstation.systemName).split(".")[0])`n--NinjaID: $($workstation.id)`n"
    }

    if ($logLevel -eq "WARNING"){
        $script:warnCount += 1
        $script:warnArray += $arrayMessage
    }
    if ($logLevel -eq "ERROR"){
        $script:errorCount += 1
        $script:errorArray += $arrayMessage
    }

    $params = @{Path = $logFile; Value = $logMessage; PassThru = $PassThru}
    Add-Content @params
}

function New-AuthToken {
    Logging -logString "Getting new Jamf Auth Token" -logLevel INFORMATION
    $body = @{
        grant_type = 'client_credentials'
        client_id = $clientId
        client_secret = $clientSecret
    }

    $params = @{
        Uri = "$jamfServer/api/oauth/token"
        Method = 'POST'
        Body = $body
        ContentType = 'application/x-www-form-urlencoded'
    }

    $result = Invoke-RestMethod @params
    return @{Authorization = "Bearer $($result.access_token)"}
}

function Get-AppleUpdateCatalog {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory,Position=0)]
        [psobject]
        $object
    )
    Logging -logString "Getting current versions of macOS from Apple Software Update Catalog" -logLevel INFORMATION
    $result = Invoke-RestMethod -Uri $softwareUpdateCatalogURL
    $distUrls = ($result | Select-Xml -XPath "//dict[contains(., 'com.apple.pkg.InstallAssistant.macOS')]/dict/string[contains(., 'English.dist')]").Node.InnerText
    $versions = @()
    $distUrls | ForEach-Object {
        $versions += ((Invoke-WebRequest -Uri $_).Content | Select-Xml -XPath "//key[.='VERSION']/following-sibling::string[1]/text()").Node.Value
    }
    
    $versionsNewest = @()
    $object | ForEach-Object {
        $v = $_.targetVersion
        $newestMinor = ($versions.Where{$_ -like "$v*"} | Sort-Object)
        if ($newestMinor.count -gt 1){$newestMinor = $newestMinor[-1]}
        $versionsNewest += @{targetVersion = $v; minRequired = $newestMinor}
    }
    Logging -logString "Newest versions: $($versionsNewest.minRequired -join ', ')" -logLevel INFORMATION
    return $versionsNewest
}

function Invoke-JamfProfile {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory,Position=0)]
        [string]
        $ProfileName,
        [Parameter(Mandatory,Position=1)]
        [ValidateSet("GET","PUT","POST")]
        [string]
        $Method,
        [Parameter()]
        [xml]
        $XmlPayload
    )

    $ProfileNameConverted = $ProfileName.Replace(' ','%20')
    $params = @{
        uri = "$jamfServer/JSSResource/osxconfigurationprofiles/name/$ProfileNameConverted"
        ContentType = "application/xml"
        Method = $Method
        Headers = $token
    }
    if ($Method -eq "GET"){
        Logging -logString "Getting settings for $ProfileName from Jamf" -logLevel INFORMATION
    }
    if ($Method -eq "PUT"){
        Logging -logString "Sending updated settings for $ProfileName to Jamf" -logLevel INFORMATION
        $params += @{Body = $XmlPayload}
    }
    if ($Method -eq "POST"){
        Logging -logString "Uploading new Profile to Jamf" -logLevel INFORMATION
        $params = @{
            uri = "$jamfServer/JSSResource/osxconfigurationprofiles/id/0"
            ContentType = "application/xml"
            Method = $Method
            Body = $XmlPayload
            Headers = $token
        }
    }
    return (Invoke-RestMethod @params)
}

function Set-Payload {
    param (
        [Parameter(Mandatory,Position=0)]
        [xml]
        $Payload,
        [Parameter(Mandatory,Position=1)]
        [int]
        $DeadlineDays,
        [Parameter()]
        [switch]
        $Force
    )

    $deadline = "$((Get-Date).AddDays($DeadlineDays).ToString('yyyy-MM-dd'))T10:00:00Z"

    Logging -logString "Checking if update is required" -logLevel INFORMATION
    ### Get osVersionRequirements of old payload
    $updateKeys = "requiredMinimumOSVersion","targetedOSVersionsRule","requiredInstallationDate"
    $oldVersionXml = ($Payload | Select-Xml -XPath "//dict[key = 'osVersionRequirements']").Node.FirstChild.NextSibling.ChildNodes
    $oldVersionProperties = @()
    foreach ($dict in $oldVersionXml){
        $propCount = 0
        $props = @{}
        $dict.key | ForEach-Object {
            if ($updateKeys -contains $_){$props += @{"OLD-$($_)" = $dict.string[$propCount]}}
            $propCount ++
        }
        $oldVersionProperties += $props
    }

    ### Create an Updated Version Object
    $propNoChange = 0
    $versionObjectUpdated = @()
    foreach ($newProp in $versionObject){
        foreach ($oldProp in $oldVersionProperties){
            if ($newProp.targetVersion -eq $oldProp.'OLD-targetedOSVersionsRule'){
                $combinedProps = $oldProp
                $combinedProps += $newProp
                $versionObjectUpdated += $combinedProps
                break
            }
        }
    }

    $versionObjectUpdated | ForEach-Object { ### Count the number unchanged Minimum Required Versions
        if ($_.'OLD-requiredMinimumOSVersion' -eq $_.minRequired) {
            Logging -logString "Version $($_.minRequired) has not changed" -logLevel INFORMATION
            $propNoChange ++
            return
        }
    }

    if ($Force){$propNoChange = 0} ### Set $propNoChange to 0, forcing the update
    if ($propNoChange -gt 3){
        Logging -logString "Nothing to update" -logLevel INFORMATION
        return "No Update"
    } else {
        Logging -logString "Changes found or force switch enabled. Updating XML." -logLevel INFORMATION
       $newNudgeSettings = @"
<dict>
    <key>aboutUpdateURL</key>
    <string>$aboutUrl</string>
    <key>majorUpgradeAppPath</key>
    <string>/System/Library/CoreServices/Software Update.app</string>
    <key>requiredInstallationDate</key>
    <string>$deadline</string>
    <key>requiredMinimumOSVersion</key>
    <string>$($versionObject[3].minRequired)</string>
    <key>targetedOSVersionsRule</key>
    <string>$($versionObject[3].targetVersion)</string>
</dict>
<dict>
    <key>aboutUpdateURL</key>
    <string>$aboutUrl</string>
    <key>majorUpgradeAppPath</key>
    <string>/System/Library/CoreServices/Software Update.app</string>
    <key>requiredInstallationDate</key>
    <string>$deadline</string>
    <key>requiredMinimumOSVersion</key>
    <string>$($versionObject[2].minRequired)</string>
    <key>targetedOSVersionsRule</key>
    <string>$($versionObject[2].targetVersion)</string>
</dict>
<dict>
    <key>aboutUpdateURL</key>
    <string>$aboutUrl</string>
    <key>majorUpgradeAppPath</key>
    <string>/System/Library/CoreServices/Software Update.app</string>
    <key>requiredInstallationDate</key>
    <string>$deadline</string>
    <key>requiredMinimumOSVersion</key>
    <string>$($versionObject[1].minRequired)</string>
    <key>targetedOSVersionsRule</key>
    <string>$($versionObject[1].targetVersion)</string>
</dict>
<dict>
    <key>aboutUpdateURL</key>
    <string>$aboutUrl</string>
    <key>requiredInstallationDate</key>
    <string>$deadline</string>
    <key>requiredMinimumOSVersion</key>
    <string>$($versionObject[3].minRequired)</string>
    <key>targetedOSVersionsRule</key>
    <string>$($versionObject[3].targetVersion)</string>
</dict>
"@

        ($Payload | Select-Xml -XPath "//dict[key = 'osVersionRequirements']").Node.FirstChild.NextSibling.InnerXml = $newNudgeSettings
        return $Payload
    }
    
}

function Invoke-SlackMessage {
    [CmdletBinding()]
    param (
        [Parameter()]
        [switch]
        $update
    )

    if ($update) {
        Logging -logString "Sending Slack Message confirming no updates" -logLevel INFORMATION
        $payload = [PSCustomObject]@{
            blocks = @(
                @{type = "header";text = @{type = "plain_text";text = "Nudge Run: ";emoji = $true}}
                @{type = "section";text = @{type = "mrkdwn";text = "*Latest Versions:*
macOS 13.7.3, macOS 14.7, macOS 15.0"}}
                @{type = "section";text = @{type = "mrkdwn";text = "*Deadlines:*
$((Get-Date).AddDays(14).ToString('yyyy-MM-dd'))
$((Get-Date).AddDays(28).ToString('yyyy-MM-dd'))
$((Get-Date).AddDays(42).ToString('yyyy-MM-dd'))"}}
            )
}
    } else {
        Logging -logString "Sending Slack Message confirming new updates" -logLevel INFORMATION
        $payload = [PSCustomObject]@{
            blocks = @(
                @{type = "header";text = @{type = "plain_text";text = "Nudge Run: ";emoji = $true}}
                @{type = "section";text = @{type = "mrkdwn";text = "*Nothing to update*"}}
            )
        }
    } 
    Invoke-RestMethod -Uri $webHookUrl -Body ($payload | ConvertTo-Json -Depth 4) -Method Post -ContentType 'application/json'
}
