# Create-VCF-Bookmarks.ps1
# Creates browser bookmarks for VCF Lab
# Generated: 2025-11-11 12:44:48
# Updated: Added third folder for Other bookmarks

param(
    [ValidateSet('Chrome', 'Edge', 'Both')]
    [string]$Browser = 'Both',
    [string]$BookmarkBarFolder = 'VCF Lab'
)

$managementDomainBookmarks = @(
    @{ Name = 'VCF Installer'; URL = 'https://vcfinst.vcf.lab.io' }
    @{ Name = 'SDDC Manager'; URL = 'https://sddcm01.vcf.lab.io' }
    @{ Name = 'Management vCenter'; URL = 'https://mgmt-vc.vcf.lab.io/ui' }
    @{ Name = 'Management NSX Manager'; URL = 'https://nsx01.vcf.lab.io' }
    @{ Name = 'VCF Operations Manager'; URL = 'https://ops.vcf.lab.io' }
    @{ Name = 'Fleet Manager'; URL = 'https://opsfm01.vcf.lab.io' }
    @{ Name = 'MGMT ESXi01'; URL = 'https://esx01.vcf.lab.io/ui' }
    @{ Name = 'MGMT ESXi02'; URL = 'https://esx02.vcf.lab.io/ui' }
    @{ Name = 'MGMT ESXi03'; URL = 'https://esx03.vcf.lab.io/ui' }
    @{ Name = 'MGMT ESXi04'; URL = 'https://esx04.vcf.lab.io/ui' }
)

$workloadDomainBookmarks = @(
    @{ Name = 'Workload vCenter'; URL = 'https://wld-vc.vcf.lab.io/ui' }
    @{ Name = 'Workload NSX Manager'; URL = 'https://nsx02.vcf.lab.io' }
    @{ Name = 'WLD ESXi01'; URL = 'https://esxi05.vcf.lab.io/ui' }
    @{ Name = 'WLD ESXi02'; URL = 'https://esxi06.vcf.lab.io/ui' }
    @{ Name = 'WLD ESXi03'; URL = 'https://esxi07.vcf.lab.io/ui' }
)

$otherBookmarks = @(
    # Add your bookmarks here, for example:
    @{ Name = 'pfSense FW'; URL = 'https://10.0.0.1' }
    @{ Name = 'Portainer'; URL = 'https://linuxvm.lab.io:9443' }
	@{ Name = 'myKMS UI'; URL = 'http://linuxvm.lab.io:8080' }
	@{ Name = 'Password Manager'; URL = 'https://linuxvm.lab.io:8443' }
)

Function Get-ChromiumBookmarkPath {
    param([string]$BrowserType)
    $paths = @{
        'Chrome' = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Bookmarks"
        'Edge' = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Bookmarks"
    }
    return $paths[$BrowserType]
}

Function Backup-BookmarkFile {
    param([string]$BookmarkPath)
    if (Test-Path $BookmarkPath) {
        $backupPath = "$BookmarkPath.backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        Copy-Item -Path $BookmarkPath -Destination $backupPath -Force
        Write-Host "  Backup created: $backupPath" -ForegroundColor Green
        return $true
    }
    return $false
}

Function Add-ChromiumBookmarks {
    param(
        [string]$BrowserType,
        [string]$FolderName,
        [array]$MgmtBookmarks,
        [array]$WldBookmarks,
        [array]$OtherBookmarks
    )
    
    $bookmarkPath = Get-ChromiumBookmarkPath -BrowserType $BrowserType
    
    Write-Host "" -ForegroundColor Cyan
    Write-Host "$BrowserType Bookmark Creation" -ForegroundColor Cyan
    Write-Host "==============================" -ForegroundColor Cyan
    
    if (-not (Test-Path $bookmarkPath)) {
        Write-Host "  $BrowserType not found" -ForegroundColor Yellow
        return $false
    }
    
    $browserProcess = if ($BrowserType -eq 'Chrome') { 'chrome' } else { 'msedge' }
    $running = Get-Process -Name $browserProcess -ErrorAction SilentlyContinue
    if ($running) {
        Write-Host "  WARNING: $BrowserType is running!" -ForegroundColor Yellow
        Write-Host "  Close $BrowserType and press Enter..." -ForegroundColor Yellow
        Read-Host
    }
    
    Write-Host "  Creating backup..." -ForegroundColor White
    Backup-BookmarkFile -BookmarkPath $bookmarkPath
    
    try {
        Write-Host "  Reading bookmarks..." -ForegroundColor White
        $bookmarkJson = Get-Content -Path $bookmarkPath -Raw | ConvertFrom-Json
        $bookmarkBar = $bookmarkJson.roots.bookmark_bar
        
        $currentId = [int]([DateTimeOffset]::Now.ToUnixTimeSeconds())
        $currentId += 1000
        
        Function New-BookmarkFolder {
            param([string]$Name, [array]$Children)
            return @{
                children = $Children
                date_added = [string]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() * 1000)
                date_last_used = "0"
                date_modified = [string]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() * 1000)
                guid = [guid]::NewGuid().ToString()
                id = [string]($script:currentId++)
                name = $Name
                type = "folder"
            }
        }
        
        Function New-Bookmark {
            param([string]$Name, [string]$URL)
            return @{
                date_added = [string]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() * 1000)
                date_last_used = "0"
                guid = [guid]::NewGuid().ToString()
                id = [string]($script:currentId++)
                name = $Name
                type = "url"
                url = $URL
            }
        }
        
        Write-Host "  Creating Management Domain bookmarks..." -ForegroundColor White
        $mgmtBookmarkObjects = @()
        foreach ($bookmark in $MgmtBookmarks) {
            $mgmtBookmarkObjects += New-Bookmark -Name $bookmark.Name -URL $bookmark.URL
            Write-Host "    + $($bookmark.Name)" -ForegroundColor Gray
        }
        $mgmtFolder = New-BookmarkFolder -Name "Management Domain" -Children $mgmtBookmarkObjects
        
        Write-Host "  Creating Workload Domain bookmarks..." -ForegroundColor White
        $wldBookmarkObjects = @()
        foreach ($bookmark in $WldBookmarks) {
            $wldBookmarkObjects += New-Bookmark -Name $bookmark.Name -URL $bookmark.URL
            Write-Host "    + $($bookmark.Name)" -ForegroundColor Gray
        }
        $wldFolder = New-BookmarkFolder -Name "Workload Domain" -Children $wldBookmarkObjects
        
        Write-Host "  Creating Other bookmarks..." -ForegroundColor White
        $otherBookmarkObjects = @()
        foreach ($bookmark in $OtherBookmarks) {
            $otherBookmarkObjects += New-Bookmark -Name $bookmark.Name -URL $bookmark.URL
            Write-Host "    + $($bookmark.Name)" -ForegroundColor Gray
        }
        $otherFolder = New-BookmarkFolder -Name "Other" -Children $otherBookmarkObjects
        
        Write-Host "  Creating main folder..." -ForegroundColor White
        $vcfLabFolder = New-BookmarkFolder -Name $FolderName -Children @($mgmtFolder, $wldFolder, $otherFolder)
        
        $existingFolder = $bookmarkBar.children | Where-Object { $_.name -eq $FolderName -and $_.type -eq "folder" }
        if ($existingFolder) {
            Write-Host "  Removing existing folder..." -ForegroundColor Yellow
            $bookmarkBar.children = @($bookmarkBar.children | Where-Object { $_.name -ne $FolderName -or $_.type -ne "folder" })
        }
        
        $bookmarkBar.children = @($bookmarkBar.children) + $vcfLabFolder
        $bookmarkJson.roots.bookmark_bar = $bookmarkBar
        
        Write-Host "  Saving bookmarks..." -ForegroundColor White
        $bookmarkJson | ConvertTo-Json -Depth 100 | Set-Content -Path $bookmarkPath -Encoding UTF8
        
        Write-Host ""
        Write-Host "  Bookmarks created!" -ForegroundColor Green
        Write-Host "    Management Domain: $($MgmtBookmarks.Count) bookmarks" -ForegroundColor Gray
        Write-Host "    Workload Domain: $($WldBookmarks.Count) bookmarks" -ForegroundColor Gray
        Write-Host "    Other: $($OtherBookmarks.Count) bookmarks" -ForegroundColor Gray
        
        return $true
    }
    catch {
        Write-Host ""
        Write-Host "  Failed: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "VCF Lab Bookmark Creator" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Creating bookmarks in $Browser" -ForegroundColor White
Write-Host ""

$success = @()

if ($Browser -eq 'Chrome' -or $Browser -eq 'Both') {
    $result = Add-ChromiumBookmarks -BrowserType 'Chrome' -FolderName $BookmarkBarFolder `
        -MgmtBookmarks $managementDomainBookmarks -WldBookmarks $workloadDomainBookmarks `
        -OtherBookmarks $otherBookmarks
    if ($result) { $success += 'Chrome' }
}

if ($Browser -eq 'Edge' -or $Browser -eq 'Both') {
    $result = Add-ChromiumBookmarks -BrowserType 'Edge' -FolderName $BookmarkBarFolder `
        -MgmtBookmarks $managementDomainBookmarks -WldBookmarks $workloadDomainBookmarks `
        -OtherBookmarks $otherBookmarks
    if ($result) { $success += 'Edge' }
}

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "Summary" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host ""

if ($success.Count -gt 0) {
    Write-Host "Bookmarks created in: $($success -join ', ')" -ForegroundColor Green
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Yellow
    Write-Host "  1. Open $($success -join ' or ')" -ForegroundColor White
    Write-Host "  2. Look for '$BookmarkBarFolder' in bookmarks bar" -ForegroundColor White
    Write-Host ""
}
else {
    Write-Host "No bookmarks created" -ForegroundColor Red
}