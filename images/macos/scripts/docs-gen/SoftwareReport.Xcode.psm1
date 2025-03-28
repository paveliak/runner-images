Import-Module "$PSScriptRoot/../helpers/Common.Helpers.psm1"
Import-Module "$PSScriptRoot/../helpers/Xcode.Helpers.psm1"

$os = Get-OSVersion

function Get-XcodePaths {
    $xcodePaths = Get-ChildItem -Path "/Applications" -Filter "Xcode_*.app" | Where-Object { !$_.LinkType }
    return $xcodePaths | Select-Object -ExpandProperty Fullname
}

function Get-XcodeSDKList {
    param(
        [Parameter(Mandatory)]
        [string]$XcodeRootPath
    )

    $versionInfo = Get-XcodeVersionInfo -XcodeRootPath $XcodeRootPath
    $xcodebuildPath = Get-XcodeToolPath -XcodeRootPath $XcodeRootPath -ToolName "xcodebuild"
    if ($versionInfo.Version -le [System.Version]::Parse("9.4.1")) {
        $output = Invoke-Expression "$xcodebuildPath -showsdks"
        $sdkList = $output | Where-Object { $_ -Match "-sdk" }

        return $sdkList | ForEach-Object {
            $displayName, $canonicalName = $_.Split("-sdk")
            return @{
                canonicalName = $canonicalName.Trim()
                displayName = $displayName.Trim()
            }
        }
    }

    [string]$output = Invoke-Expression "$xcodebuildPath -showsdks -json"
    return $output | ConvertFrom-Json
}

function Get-XcodeInfoList {
    $defaultXcodeRootPath = Get-DefaultXcodeRootPath

    $xcodeInfo = @{}
    Get-XcodePaths | ForEach-Object {
        $xcodeRootPath = $_
        Switch-Xcode -XcodeRootPath $xcodeRootPath

        $versionInfo = Get-XcodeVersionInfo -XcodeRootPath $xcodeRootPath
        $versionInfo.Path = $xcodeRootPath
        $versionInfo.IsDefault = ($xcodeRootPath -eq $defaultXcodeRootPath)
        $versionInfo.IsStable = Test-XcodeStableRelease -XcodeRootPath $xcodeRootPath

        $xcodeInfo.Add($xcodeRootPath, [PSCustomObject] @{
            VersionInfo = $versionInfo
            SDKInfo = Get-XcodeSDKList -XcodeRootPath $xcodeRootPath
            SimulatorsInfo = Get-XcodeSimulatorsInfo
        })
    }

    Switch-Xcode -XcodeRootPath $defaultXcodeRootPath

    return $xcodeInfo
}

function Get-XcodePlatformOrder {
    param (
        [Parameter(Mandatory)]
        [string] $PlatformName
    )

    Switch ($PlatformName) {
        "macOS" { 1 }
        "iOS" { 2 }
        "Simulator - iOS" { 3 }
        "tvOS" { 4 }
        "Simulator - tvOS" { 5 }
        "watchOS" { 6 }
        "Simulator - watchOS" { 7 }
        "visionOS" { 8 }
        "Simulator - visionOS" { 9 }
        Default { 100 }
    }
}

function Get-XcodeCommandLineToolsVersion {
    $xcodeCommandLineToolsVersion = Run-Command "pkgutil --pkg-info com.apple.pkg.CLTools_Executables" | Select -Index 1 | Take-Part -Part 1
    return $xcodeCommandLineToolsVersion
}

function Build-XcodeTable {
    param (
        [Parameter(Mandatory)]
        [hashtable] $xcodeInfo
    )

    $sortRules = @{
        Expression = { $_.Version }
        Descending = $true
    }

    $xcodeList = $xcodeInfo.Values | ForEach-Object { $_.VersionInfo } | Sort-Object $sortRules
    return $xcodeList | ForEach-Object {
        $defaultPostfix = if ($_.IsDefault) { " (default)" } else { "" }
        $betaPostfix = if ($_.IsStable) { "" } else { " (beta)" }
        $targetPath = $_.Path
        $symlinks = @()
        Get-ChildItem -Path "/Applications" | ForEach-Object {
            if ($_.LinkType -eq 'SymbolicLink') {
                $linkTarget = & readlink $_.FullName
                if ($linkTarget -eq $targetPath) {
                    $symlinks += $_.FullName
                }
            }
        }
        if ($null -eq $symlinks) {
            $symlinks = @("N/A")
        }
        return [PSCustomObject] @{
            "Version" = $_.Version.ToString() + $betaPostfix + $defaultPostfix
            "Build" = $_.Build
            "Path" = $_.Path
            "Symlinks" = [String]::Join("<br>", $symlinks)
        }
    }
}

function Build-XcodeDevicesList {
    param (
        [Parameter(Mandatory)][object] $XcodeInfo,
        [Parameter(Mandatory)][object] $Runtime
    )

    $runtimeId = $Runtime.identifier
    $runtimeName = $Runtime.name
    $output = $XcodeInfo.SimulatorsInfo.devices.$runtimeId
    if ($null -eq $output) {
        $output = $XcodeInfo.SimulatorsInfo.devices.$runtimeName
    }

    return $output
}

function Build-XcodeSDKTable {
    param (
        [Parameter(Mandatory)]
        [hashtable] $xcodeInfo
    )

    $sdkNames = @()
    $xcodeInfo.Values | ForEach-Object {
        $_.SDKInfo | ForEach-Object {
            $sdkNames += $_.canonicalName
        }
    }

    $sdkNames = $sdkNames | Select-Object -Unique
    return $sdkNames | ForEach-Object {
        $sdkName = $_
        $sdkDisplayName = ""
        $xcodeList = @()
        $xcodeInfo.Values | ForEach-Object {
            $sdk = $_.SDKInfo | Where-Object { $_.canonicalName -eq $sdkName } | Select-Object -First 1
            if ($sdk) {
                $sdkDisplayName = $sdk.displayName
                $xcodeList += $_.VersionInfo.Version
            }
        }

        $xcodeList = $xcodeList | Sort-Object

        return [PSCustomObject] @{
            "SDK" = $sdkDisplayName
            "SDK Name" = $sdkName
            "Xcode Version" = [String]::Join(", ", $xcodeList)
        }
    } | Sort-Object {
            # Sort rule 1
            $sdkNameParts = $_."SDK".Split(" ")
            $platformName = [String]::Join(" ", $sdkNameParts[0..($sdkNameParts.Length - 2)])
            return Get-XcodePlatformOrder $platformName
        }, {
            # Sort rule 2
            $sdkNameParts = $_."SDK".Split(" ")
            return [System.Version]::Parse($sdkNameParts[-1])
        }
}

function Format-XcodeSimulatorName {
    param(
        [Parameter(Mandatory)][string] $Device
    )

    $formattedDeviceName = $Device.Replace("ʀ", "R")
    return $formattedDeviceName
}

function Build-XcodeSimulatorsTable {
    param (
        [Parameter(Mandatory)]
        [hashtable] $xcodeInfo
    )

    $runtimes = @()
    $xcodeInfo.Values | ForEach-Object {
        $_.SimulatorsInfo.runtimes | ForEach-Object {
            $runtimes += $_
        }
    }
    $runtimes = $runtimes | Sort-Object @{ Expression = { $_.identifier } } -Unique
    return $runtimes | ForEach-Object {
        $runtime = $_
        $runtimeDevices = @()
        $xcodeInfo.Values | ForEach-Object {
            $runtimeFound = $_.SimulatorsInfo.runtimes | Where-Object { $_.identifier -eq $runtime.identifier } | Select-Object -First 1
            if ($runtimeFound) {
                $devicesToAdd = Build-XcodeDevicesList -XcodeInfo $_ -Runtime $runtimeFound
                $runtimeDevices += $devicesToAdd | Select-Object -ExpandProperty name
            }
        }
        $runtimeDevices = $runtimeDevices | ForEach-Object { Format-XcodeSimulatorName $_ } | Select-Object -Unique
        If (($runtimeDevices | Where-Object { -not ([string]::IsNullOrWhitespace($_)) }).Count -eq 0) {
            $sortedRuntimeDevices = @("N/A")
        } else {
            $sortedRuntimeDevices = $runtimeDevices | Sort-Object @{
                Expression = { $_.Split(" ")[0] };
                Descending = $true;
            }, {
                $_.Split(" ") | Select-Object -Skip 1 | Join-String -Separator " "
            }
        }
        return [PSCustomObject] @{
            "OS" = $runtime.name
            "Simulators" = [String]::Join("<br>", $sortedRuntimeDevices)
        }
    } | Sort-Object {
        # Sort rule 1
        $sdkNameParts = $_."OS".Split(" ")
        $platformName = [String]::Join(" ", $sdkNameParts[0..($sdkNameParts.Length - 2)])
        return Get-XcodePlatformOrder $platformName
    }, {
        # Sort rule 2
        $sdkNameParts = $_."OS".Split(" ")
        return [System.Version]::Parse($sdkNameParts[-1])
    }
}
