######################################################################################################
#          Variables related to your environment
######################################################################################################
$logPath      = "" ### The directory where logs will be saved to
$jamfServer   = "" ### Your Jamf Server URL
$clientId     = "" ### Your Jamf API Cliet ID
$clientSecret = "" ### Your Jamf API Client Secret
$webhookURL   = "" ### Your Slack webhook for Nudge Automate notifications
$aboutUrl     = "" ### Provide a link to your org's macOS update policy

######################################################################################################
#          Variables related to macOS Updates
######################################################################################################

$targetVersions= @(
    @{targetVersion = 12}
    @{targetVersion = 13}
    @{targetVersion = 14}
    @{targetVersion = 15}
)

$jamfProfiles= @( ### Name = Configuration Profile Name, deadline = how many days in the future before Nudge enters aggressive mode
    @{name = ""; deadline = 14}
    @{name = ""; deadline = 28}
    @{name = ""; deadline = 42}
)

### The Apple Software Update Catalog URL
$softwareUpdateCatalogURL = "https://swscan.apple.com/content/catalogs/others/index-15-14-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog"

