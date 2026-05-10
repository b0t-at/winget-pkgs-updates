$scriptPath = $MyInvocation.MyCommand.Path
$scriptDirectory = Split-Path -Parent $scriptPath
Import-Module "$scriptDirectory\..\modules\WingetMaintainerModule"

# Pfad zur HtmlAgilityPack DLL
$HtmlAgilityPackPath = "$scriptDirectory\..\libraries\HtmlAgilityPack\HtmlAgilityPack.dll"
# Laden der HtmlAgilityPack DLL
Add-Type -Path $HtmlAgilityPackPath

#### Main
$params = @{
    wingetPackage = ${Env:PackageName}
}
if($Env:WebsiteURL) {
    $params.Add("WebsiteURL", $Env:WebsiteURL)
}
if($Env:With) {
    $params.Add("With", $Env:With)
}
if($Env:Submit -eq $true) {
    $params.Add("Submit", $true)
}
else {
    $params.Add("Submit", $false)
}
if($Env:latestVersion) {
    $params.Add("latestVersion", $Env:latestVersion)
}
if($Env:latestVersionURL) {
    $params.Add("latestVersionURL", $Env:latestVersionURL)
}
if($Env:resolves) {
    $params.Add("resolves", $Env:resolves)
}
# make use of truthy evaluation to convert to clean bool
if($Env:IsTemplateUpdate -eq $true) {
    $params.Add("IsTemplateUpdate", $true)
}
else {
    $params.Add("IsTemplateUpdate", $false)
}
if($Env:releaseNotes) {
    $params.Add("releaseNotes", $Env:releaseNotes)
}
if ($Env:GHURLs) {
    $params.Add("GHURLs", $Env:GHURLs)
}
if ($Env:GHRepo) {
    $params.Add("GHRepo", $Env:GHRepo)
}
if ($Env:GHTagPattern) {
    $params.Add("GHTagPattern", $Env:GHTagPattern)
}

Update-WingetPackage @params
