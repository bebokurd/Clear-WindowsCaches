# -----------------------------------------------------------------------------
# Script Name: Clear-WindowsCaches.ps1
# Description: Cleans up various system, update, and GPU caches on Windows.
# Author:      Chya Luqman
# Discord:     https://discord.com/invite/YTeRSG8kER
# Style:       Chris Titus Tech Script Template with WPF GUI
# License:     MIT License
# -----------------------------------------------------------------------------

<#
.SYNOPSIS
    Optimized Windows Cache Cleanup Script with WPF GUI.
.DESCRIPTION
    Safely clears system temp files, Windows Update downloads, NVIDIA shader caches,
    DirectX shader cache, local DNS cache, Recycle Bin, and Prefetch files.
    Launches an interactive GUI if run without arguments, or runs in headless
    CLI mode if parameter switches are provided.
.PARAMETER ScanOnly
    Performs a dry-run scan to estimate space savings without modifying any files.
.PARAMETER Silent
    Suppresses the prompt to exit at the end of the script (useful for automation).
.PARAMETER NoServiceStop
    Prevents stopping Windows Update services when cleaning the update cache.
.EXAMPLE
    .\Clear-WindowsCaches.ps1 -ScanOnly
.EXAMPLE
    .\Clear-WindowsCaches.ps1 -Silent -NoServiceStop
#>

[CmdletBinding()]
param (
    [switch]$ScanOnly,
    [switch]$Silent,
    [switch]$NoServiceStop,
    [switch]$MemoryClean,
    [switch]$CreateRestorePoint
)

# -----------------------------------------------------------------------------
# 1. Administrator Check and Elevation
# -----------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "=========================================================" -ForegroundColor Yellow
    Write-Host "[!] Warning: This script requires Administrator privileges!" -ForegroundColor Yellow
    Write-Host "[*] Attempting to relaunch as Administrator..." -ForegroundColor Yellow
    Write-Host "=========================================================" -ForegroundColor Yellow
    
    $argsList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
    if ($ScanOnly) { $argsList += "-ScanOnly" }
    if ($Silent) { $argsList += "-Silent" }
    if ($NoServiceStop) { $argsList += "-NoServiceStop" }
    if ($MemoryClean) { $argsList += "-MemoryClean" }
    if ($CreateRestorePoint) { $argsList += "-CreateRestorePoint" }
    
    try {
        Start-Process powershell -ArgumentList $argsList -Verb RunAs -ErrorAction Stop
        Exit
    } catch {
        Write-Host "[-] Failed to relaunch as Administrator. Some caches cannot be cleared." -ForegroundColor Red
        if (-not $Silent) {
            Write-Host "[*] Press any key to exit..."
            $null = [Console]::ReadKey($true)
        }
        Exit
    }
}

# -----------------------------------------------------------------------------
# 2. GUI Detection Logic
# -----------------------------------------------------------------------------
$global:guiMode = $false
# If run interactively and no command-line switch arguments are provided, launch GUI
if ($MyInvocation.BoundParameters.Count -eq 0 -and [Environment]::UserInteractive) {
    $global:guiMode = $true
}

# -----------------------------------------------------------------------------
# 3. Logging & Formatting Helpers
# -----------------------------------------------------------------------------
# Define Win32 API for Memory Cleaner
$apiCode = @"
using System;
using System.Runtime.InteropServices;

public class MemoryCleaner {
    [DllImport("kernel32.dll", EntryPoint = "SetProcessWorkingSetSize", SetLastError = true)]
    public static extern bool SetProcessWorkingSetSize(IntPtr hProcess, int dwMinimumWorkingSetSize, int dwMaximumWorkingSetSize);
}
"@
if (-not ([System.Management.Automation.PSTypeName]"MemoryCleaner").Type) {
    try {
        Add-Type -TypeDefinition $apiCode -ErrorAction SilentlyContinue
    } catch {}
}

function Update-UI {
    <#
    .SYNOPSIS
        Flushes pending UI redraw/event events to keep the WPF interface active.
    #>
    if ($global:guiMode) {
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [System.Action]{}
        )
    }
}

function Write-Log {
    <#
    .SYNOPSIS
        Logs custom colored status messages to the console or WPF textbox.
    #>
    param (
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error', 'Step')]
        [string]$Level = 'Info'
    )
    
    $prefix = ""
    switch ($Level) {
        'Step'    { $prefix = "`r`n>>> $Message" }
        'Info'    { $prefix = "[*] $Message" }
        'Success' { $prefix = "[+] $Message" }
        'Warning' { $prefix = "[!] $Message" }
        'Error'   { $prefix = "[-] $Message" }
    }
    
    if ($global:guiMode -and $global:txtLog) {
        $global:txtLog.AppendText($prefix + "`r`n")
        $global:txtLog.ScrollToEnd()
        Update-UI
    } else {
        switch ($Level) {
            'Step'    { Write-Host "`n>>> $Message" -ForegroundColor Magenta }
            'Info'    { Write-Host "[*] $Message" -ForegroundColor Cyan }
            'Success' { Write-Host "[+] $Message" -ForegroundColor Green }
            'Warning' { Write-Host "[!] $Message" -ForegroundColor Yellow }
            'Error'   { Write-Host "[-] $Message" -ForegroundColor Red }
        }
    }
}

function Format-Size {
    <#
    .SYNOPSIS
        Converts bytes to a human-readable size string.
    #>
    param (
        [double]$Bytes
    )
    if ($Bytes -ge 1GB) {
        return "{0:N2} GB" -f ($Bytes / 1GB)
    } elseif ($Bytes -ge 1MB) {
        return "{0:N2} MB" -f ($Bytes / 1MB)
    } elseif ($Bytes -ge 1KB) {
        return "{0:N2} KB" -f ($Bytes / 1KB)
    } else {
        return "$Bytes Bytes"
    }
}

# -----------------------------------------------------------------------------
# 4. Core File Operations
# -----------------------------------------------------------------------------
function Remove-FolderContents {
    <#
    .SYNOPSIS
        Deletes contents of a folder and returns sizes in a single pass.
    #>
    param (
        [Parameter(Mandatory=$true)]
        [string]$Path,
        [switch]$Scan
    )
    if (-not (Test-Path -Path $Path -PathType Container)) {
        return @{ Initial = 0; Final = 0; Freed = 0 }
    }
    
    $freedBytes = 0
    $lockedBytes = 0
    
    try {
        $files = Get-ChildItem -Path $Path -File -Recurse -ErrorAction SilentlyContinue
        foreach ($file in $files) {
            $len = $file.Length
            
            if ($Scan) {
                $freedBytes += $len
            } else {
                try {
                    Remove-Item -Path $file.FullName -Force -ErrorAction Stop
                    $freedBytes += $len
                } catch {
                    $lockedBytes += $len
                }
            }
        }
    } catch {
        # Silent fail on directory structural lock issues
    }
    
    if (-not $Scan) {
        try {
            $dirs = Get-ChildItem -Path $Path -Directory -Recurse -ErrorAction SilentlyContinue | Sort-Object -Property FullName -Descending
            foreach ($dir in $dirs) {
                try {
                    if ((Get-ChildItem -Path $dir.FullName -ErrorAction SilentlyContinue).Count -eq 0) {
                        Remove-Item -Path $dir.FullName -Force -Recurse -ErrorAction Stop
                    }
                } catch {}
            }
        } catch {}
    }
    
    return @{
        Initial = $freedBytes + $lockedBytes
        Final   = $lockedBytes
        Freed   = $freedBytes
    }
}

function Combine-Results {
    <#
    .SYNOPSIS
        Aggregates multiple folder cleanup results.
    #>
    param (
        [PSCustomObject[]]$Results
    )
    $initial = 0
    $final = 0
    $freed = 0
    foreach ($r in $Results) {
        if ($r) {
            $initial += $r.Initial
            $final += $r.Final
            $freed += $r.Freed
        }
    }
    return @{ Initial = $initial; Final = $final; Freed = $freed }
}

# -----------------------------------------------------------------------------
# 5. Modular Cache Cleaning Functions
# -----------------------------------------------------------------------------
function Clear-WindowsTempCache {
    <#
    .SYNOPSIS
        Clears the System and User Temp directories.
    #>
    param (
        [switch]$ScanOnly
    )
    $userTempPath = $env:TEMP
    $sysTempPath = Join-Path $env:SystemRoot "Temp"
    
    if ($ScanOnly) {
        Write-Log "Scanning Temp folders..."
    } else {
        Write-Log "Cleaning Temp folders..."
    }
    
    $userTempRes = Remove-FolderContents $userTempPath -Scan:$ScanOnly
    $sysTempRes = Remove-FolderContents $sysTempPath -Scan:$ScanOnly
    
    $totalFreed = $userTempRes.Freed + $sysTempRes.Freed
    Write-Log "Cleaned $(Format-Size $totalFreed) from Windows Temp." -Level Success
    
    return @(
        [PSCustomObject]@{
            "Cache Name"  = "User Temp Cache"
            "Initial"     = (Format-Size $userTempRes.Initial)
            "Final"       = (Format-Size $userTempRes.Final)
            "Space Freed" = (Format-Size $userTempRes.Freed)
            "RawFreed"    = $userTempRes.Freed
        },
        [PSCustomObject]@{
            "Cache Name"  = "System Temp Cache"
            "Initial"     = (Format-Size $sysTempRes.Initial)
            "Final"       = (Format-Size $sysTempRes.Final)
            "Space Freed" = (Format-Size $sysTempRes.Freed)
            "RawFreed"    = $sysTempRes.Freed
        }
    )
}

function Clear-WindowsUpdateCache {
    <#
    .SYNOPSIS
        Clears Windows SoftwareDistribution (Updates) cache.
    #>
    param (
        [switch]$ScanOnly,
        [switch]$NoServiceStop
    )
    $winUpdatePath = Join-Path $env:SystemRoot "SoftwareDistribution"
    
    if ($ScanOnly) {
        Write-Log "Scanning Windows Update Cache..."
    } else {
        Write-Log "Cleaning Windows Update Cache..."
    }
    
    $shouldStopServices = (-not $NoServiceStop) -and (-not $ScanOnly)
    $stoppedServices = @()
    
    if ($shouldStopServices) {
        $services = @("wuauserv", "bits", "cryptsvc", "appidsvc")
        foreach ($svcName in $services) {
            $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq "Running") {
                Write-Log "Stopping service: $svcName..."
                try {
                    Stop-Service -Name $svcName -Force -ErrorAction Stop
                    $stoppedServices += $svcName
                } catch {
                    Write-Log "Could not stop service $svcName." -Level Warning
                }
            }
        }
    }
    
    $winUpdateRes = Remove-FolderContents $winUpdatePath -Scan:$ScanOnly
    
    if ($shouldStopServices -and $stoppedServices.Count -gt 0) {
        foreach ($svcName in $stoppedServices) {
            Write-Log "Starting service: $svcName..."
            try {
                Start-Service -Name $svcName -ErrorAction Stop
            } catch {
                Write-Log "Could not restart service $svcName." -Level Error
            }
        }
    }
    
    Write-Log "Cleaned $(Format-Size $winUpdateRes.Freed) from Update cache." -Level Success
    return [PSCustomObject]@{
        "Cache Name"  = "Windows Update Cache"
        "Initial"     = (Format-Size $winUpdateRes.Initial)
        "Final"       = (Format-Size $winUpdateRes.Final)
        "Space Freed" = (Format-Size $winUpdateRes.Freed)
        "RawFreed"    = $winUpdateRes.Freed
    }
}

function Clear-NvidiaGraphicsCache {
    <#
    .SYNOPSIS
        Clears NVIDIA DXCache, GLCache, and general shader folders.
    #>
    param (
        [switch]$ScanOnly
    )
    $localLow = Join-Path $env:USERPROFILE "AppData\LocalLow"
    $nvidiaGlCache = Join-Path $env:LOCALAPPDATA "NVIDIA\GLCache"
    $nvidiaDxCache = Join-Path $env:LOCALAPPDATA "NVIDIA\DXCache"
    $nvidiaDxCacheLow = Join-Path $localLow "NVIDIA\PerDriverVersion\DXCache"
    $nvidiaNvCache = Join-Path $env:LOCALAPPDATA "NVIDIA Corporation\NV_Cache"
    
    if ($ScanOnly) {
        Write-Log "Scanning NVIDIA DX/GL Cache..."
    } else {
        Write-Log "Cleaning NVIDIA DX/GL Cache..."
    }
    
    $nvGlRes = Remove-FolderContents $nvidiaGlCache -Scan:$ScanOnly
    $nvDxRes = Remove-FolderContents $nvidiaDxCache -Scan:$ScanOnly
    $nvDxLowRes = Remove-FolderContents $nvidiaDxCacheLow -Scan:$ScanOnly
    $nvCorporationRes = Remove-FolderContents $nvidiaNvCache -Scan:$ScanOnly
    
    $nvCombined = Combine-Results @($nvGlRes, $nvDxRes, $nvDxLowRes, $nvCorporationRes)
    
    Write-Log "Cleaned $(Format-Size $nvCombined.Freed) from NVIDIA Caches." -Level Success
    return [PSCustomObject]@{
        "Cache Name"  = "NVIDIA DX/GL Cache"
        "Initial"     = (Format-Size $nvCombined.Initial)
        "Final"       = (Format-Size $nvCombined.Final)
        "Space Freed" = (Format-Size $nvCombined.Freed)
        "RawFreed"    = $nvCombined.Freed
    }
}

function Clear-DirectXShaderCache {
    <#
    .SYNOPSIS
        Clears system DirectX D3DSCache files.
    #>
    param (
        [switch]$ScanOnly
    )
    $dxShaderCache = Join-Path $env:LOCALAPPDATA "D3DSCache"
    
    if ($ScanOnly) {
        Write-Log "Scanning DirectX Shader Cache..."
    } else {
        Write-Log "Cleaning DirectX Shader Cache..."
    }
    
    $dxRes = Remove-FolderContents $dxShaderCache -Scan:$ScanOnly
    
    Write-Log "Cleaned $(Format-Size $dxRes.Freed) from DirectX cache." -Level Success
    return [PSCustomObject]@{
        "Cache Name"  = "DirectX Shader Cache"
        "Initial"     = (Format-Size $dxRes.Initial)
        "Final"       = (Format-Size $dxRes.Final)
        "Space Freed" = (Format-Size $dxRes.Freed)
        "RawFreed"    = $dxRes.Freed
    }
}

function Clear-DnsCache {
    <#
    .SYNOPSIS
        Flushes the DNS resolver cache.
    #>
    param (
        [switch]$ScanOnly
    )
    if ($ScanOnly) {
        Write-Log "DNS Resolver Cache checked (Scan Only)."
        $dnsStatus = "Scan Only"
    } else {
        Write-Log "Flushing DNS Client Cache..."
        $dnsStatus = "Success"
        try {
            Clear-DnsClientCache -ErrorAction Stop
        } catch {
            try {
                ipconfig /flushdns | Out-Null
            } catch {
                $dnsStatus = "Failed"
                Write-Log "Failed to flush DNS cache." -Level Warning
            }
        }
    }
    
    if ($dnsStatus -eq "Success") {
        Write-Log "DNS Cache flushed successfully." -Level Success
    }
    
    return [PSCustomObject]@{
        "Cache Name"  = "DNS Cache"
        "Initial"     = "N/A"
        "Final"       = "N/A"
        "Space Freed" = $dnsStatus
        "RawFreed"    = 0
    }
}

function Clear-RecycleBinCache {
    <#
    .SYNOPSIS
        Calculates and flushes the Recycle Bin for all local drives.
    #>
    param (
        [switch]$ScanOnly
    )
    if ($ScanOnly) {
        Write-Log "Scanning Recycle Bin contents..."
    } else {
        Write-Log "Cleaning Recycle Bin..."
    }
    
    $rbInitial = 0
    try {
        $drives = Get-PSDrive -PSProvider FileSystem
        foreach ($drive in $drives) {
            $rbPath = Join-Path $drive.Root '$RECYCLE.BIN'
            if (Test-Path $rbPath) {
                $rbRes = Remove-FolderContents $rbPath -Scan:$true
                $rbInitial += $rbRes.Initial
            }
        }
    } catch {}
    
    $rbFreed = 0
    $rbFinal = $rbInitial
    
    if (-not $ScanOnly) {
        try {
            Clear-RecycleBin -Confirm:$false -ErrorAction SilentlyContinue
        } catch {}
        
        $rbFinalAfter = 0
        try {
            foreach ($drive in $drives) {
                $rbPath = Join-Path $drive.Root '$RECYCLE.BIN'
                if (Test-Path $rbPath) {
                    $rbRes = Remove-FolderContents $rbPath -Scan:$true
                    $rbFinalAfter += $rbRes.Initial
                }
            }
        } catch {}
        
        $rbFinal = $rbFinalAfter
        $rbFreed = [Math]::Max(0, $rbInitial - $rbFinal)
    } else {
        $rbFreed = $rbInitial
        $rbFinal = 0
    }
    
    Write-Log "Cleaned $(Format-Size $rbFreed) from Recycle Bin." -Level Success
    return [PSCustomObject]@{
        "Cache Name"  = "Recycle Bin"
        "Initial"     = (Format-Size $rbInitial)
        "Final"       = (Format-Size $rbFinal)
        "Space Freed" = (Format-Size $rbFreed)
        "RawFreed"    = $rbFreed
    }
}

function Clear-PrefetchCache {
    <#
    .SYNOPSIS
        Clears Windows system Prefetch cache files.
    #>
    param (
        [switch]$ScanOnly
    )
    $prefetchPath = Join-Path $env:SystemRoot "Prefetch"
    
    if ($ScanOnly) {
        Write-Log "Scanning Prefetch Cache..."
    } else {
        Write-Log "Cleaning Prefetch Cache..."
    }
    
    $prefRes = Remove-FolderContents $prefetchPath -Scan:$ScanOnly
    
    Write-Log "Cleaned $(Format-Size $prefRes.Freed) from Prefetch." -Level Success
    return [PSCustomObject]@{
        "Cache Name"  = "Prefetch Cache"
        "Initial"     = (Format-Size $prefRes.Initial)
        "Final"       = (Format-Size $prefRes.Final)
        "Space Freed" = (Format-Size $prefRes.Freed)
        "RawFreed"    = $prefRes.Freed
    }
}

function Clear-MemoryCache {
    <#
    .SYNOPSIS
        Optimizes process working sets to reclaim active RAM.
    #>
    param (
        [switch]$ScanOnly
    )
    
    if ($ScanOnly) {
        Write-Log "Scanning RAM Working Sets (Scan Only)..."
        return [PSCustomObject]@{
            "Cache Name"  = "Memory Cleaner"
            "Initial"     = "N/A"
            "Final"       = "N/A"
            "Space Freed" = "Ready to Clean"
            "RawFreed"    = 0
        }
    }
    
    Write-Log "Optimizing process Working Sets..."
    $processCount = 0
    
    $processes = Get-Process
    foreach ($proc in $processes) {
        if ($proc.Id -eq $PID -or $proc.Id -eq 0 -or $proc.Id -eq 4) { continue }
        try {
            $handle = $proc.Handle
            if ($handle -ne [IntPtr]::Zero) {
                $res = [MemoryCleaner]::SetProcessWorkingSetSize($handle, -1, -1)
                if ($res) { $processCount++ }
            }
        } catch {
            # Skip processes with locked handles or access denied
        }
    }
    
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    
    Write-Log "Optimized memory for $processCount processes." -Level Success
    return [PSCustomObject]@{
        "Cache Name"  = "Memory Cleaner"
        "Initial"     = "N/A"
        "Final"       = "N/A"
        "Space Freed" = "Cleaned ($processCount processes)"
        "RawFreed"    = 0
    }
}

function New-SystemRestorePoint {
    <#
    .SYNOPSIS
        Creates a Windows System Restore Point.
    #>
    Write-Log "Enabling System Protection for C: drive..."
    try {
        Enable-ComputerRestore -Drive "C:\" -ErrorAction SilentlyContinue
    } catch {}
    
    Write-Log "Creating System Restore Point..." -Level Info
    try {
        Checkpoint-Computer -Description "Before Cache Cleanup" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Log "System Restore Point created successfully." -Level Success
    } catch {
        Write-Log "Failed to create restore point: $_" -Level Warning
        Write-Log "Note: Windows limits restore points to once per 24 hours by default." -Level Info
    }
}

# -----------------------------------------------------------------------------
# 6. GUI Window Definition & Launch Logic
# -----------------------------------------------------------------------------
if ($global:guiMode) {
    # 6a. WPF XAML Layout Definition
    $xamlString = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Windows Cache Cleanup Utility" Height="650" Width="750"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize">
    <Window.Resources>
        <!-- Custom styled CheckBox -->
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="#e4e4e7"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="Margin" Value="0,6"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <BulletDecorator Background="Transparent">
                            <BulletDecorator.Bullet>
                                <Border x:Name="box" Width="18" Height="18" CornerRadius="4" Background="#1f2937" BorderBrush="#374151" BorderThickness="1.2" VerticalAlignment="Center">
                                    <Path x:Name="mark" Width="10" Height="8" Stretch="Uniform" Stroke="#38bdf8" StrokeThickness="2.2" Data="M1,4.5 L3.5,7 L8.5,2" Visibility="Collapsed" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                </Border>
                            </BulletDecorator.Bullet>
                            <ContentPresenter Margin="10,0,0,0" VerticalAlignment="Center" HorizontalAlignment="Left"/>
                        </BulletDecorator>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="box" Property="Background" Value="#0369a1"/>
                                <Setter TargetName="box" Property="BorderBrush" Value="#38bdf8"/>
                                <Setter TargetName="mark" Property="Visibility" Value="Visible"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="box" Property="BorderBrush" Value="#38bdf8"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="box" Property="Background" Value="#111827"/>
                                <Setter TargetName="box" Property="BorderBrush" Value="#1f2937"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Custom button templates for modern rounded styles with hover effects -->
        <Style TargetType="Button" x:Key="ModernButton">
            <Setter Property="Background" Value="#1f2937"/>
            <Setter Property="Foreground" Value="#f9fafb"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}" CornerRadius="6" BorderThickness="1" BorderBrush="#374151">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="5"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#374151"/>
                                <Setter TargetName="border" Property="BorderBrush" Value="#4b5563"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#4b5563"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        
        <Style TargetType="Button" x:Key="ActionButton">
            <Setter Property="Background" Value="#0284c7"/>
            <Setter Property="Foreground" Value="#ffffff"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}" CornerRadius="6">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="10,5"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#0369a1"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#075985"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="Button" x:Key="DiscordButton">
            <Setter Property="Background" Value="#5865F2"/>
            <Setter Property="Foreground" Value="#ffffff"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}" CornerRadius="6">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="10,4"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#4752C4"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#3C45A5"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="Button" x:Key="WindowControlButton">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="#9ca3af"/>
            <Setter Property="Width" Value="46"/>
            <Setter Property="Height" Value="32"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}" CornerRadius="0">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#1f2937"/>
                                <Setter Property="Foreground" Value="#ffffff"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#374151"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="Button" x:Key="CloseControlButton" BasedOn="{StaticResource WindowControlButton}">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}" CornerRadius="0,12,0,0">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#dc2626"/>
                                <Setter Property="Foreground" Value="#ffffff"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#b91c1c"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <!-- Main Window Border -->
    <Border CornerRadius="12" Background="#111827" BorderBrush="#1f2937" BorderThickness="1.5">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="32"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <!-- 1. Custom Title Bar -->
            <Grid Grid.Row="0" Name="titleBar" Background="#0f172a" ClipToBounds="True">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                
                <StackPanel Orientation="Horizontal" Grid.Column="0" Margin="12,0,0,0" VerticalAlignment="Center">
                    <!-- Title Bar Mini Icon -->
                    <Image Name="imgMiniIcon" Width="14" Height="14" Margin="0,0,8,0" Stretch="UniformToFill" VerticalAlignment="Center"/>
                    <Label Content="Windows Cache Cleanup Utility" FontSize="11" Foreground="#9ca3af" FontWeight="SemiBold" Padding="0" VerticalAlignment="Center"/>
                </StackPanel>
                
                <Button Name="btnMinimize" Style="{StaticResource WindowControlButton}" Grid.Column="1">
                    <Path Width="10" Height="1.5" Stroke="{Binding Foreground, RelativeSource={RelativeSource Mode=FindAncestor, AncestorType=Button}}" StrokeThickness="1.5" Data="M0,0 L10,0" SnapsToDevicePixels="True"/>
                </Button>
                
                <Button Name="btnClose" Style="{StaticResource CloseControlButton}" Grid.Column="2">
                    <Path Width="10" Height="10" Stroke="{Binding Foreground, RelativeSource={RelativeSource Mode=FindAncestor, AncestorType=Button}}" StrokeThickness="1.5" Data="M1,1 L9,9 M9,1 L1,9" SnapsToDevicePixels="True"/>
                </Button>
            </Grid>

            <!-- 2. Main Header -->
            <Grid Grid.Row="1" Margin="20,15,20,10">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                
                <!-- App Header Icon -->
                <Image Name="imgIcon" Grid.Column="0" Width="48" Height="48" Margin="0,0,15,0" Stretch="UniformToFill" VerticalAlignment="Center"/>

                <StackPanel Grid.Column="1" VerticalAlignment="Center">
                    <Label Content="Windows Cache Cleanup" FontSize="22" FontWeight="Bold" Foreground="#38bdf8" Padding="0"/>
                    <Label Content="by Chya Luqman" FontSize="12" Foreground="#e0f2fe" FontWeight="SemiBold" Padding="0,3,0,0"/>
                </StackPanel>

                <StackPanel Grid.Column="2" VerticalAlignment="Center">
                    <Button Name="btnDiscord" Style="{StaticResource DiscordButton}" Content="Join Discord Server"/>
                </StackPanel>
            </Grid>

            <Separator Grid.Row="1" VerticalAlignment="Bottom" Margin="20,0" Background="#1f2937"/>

            <!-- 3. Body Panel -->
            <Grid Grid.Row="2" Margin="20,15,20,15">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="280"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                
                <Border Grid.Column="0" Background="#0f172a" BorderBrush="#1f2937" BorderThickness="1" CornerRadius="8" Padding="15" Margin="0,0,10,0">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        
                        <Label Grid.Row="0" Content="Caches to Clean" FontSize="13" FontWeight="Bold" Foreground="#f9fafb" Margin="0,0,0,10" Padding="0"/>
                        
                        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
                            <StackPanel>
                                <CheckBox Name="chkTemp" Content="Windows Temp Cache" IsChecked="True" Foreground="#f3f4f6" Margin="0,4" FontSize="11.5"/>
                                <CheckBox Name="chkUpdate" Content="Windows Update Cache" IsChecked="True" Foreground="#f3f4f6" Margin="0,4" FontSize="11.5"/>
                                <CheckBox Name="chkNvidia" Content="NVIDIA DX/GL Cache" IsChecked="True" Foreground="#f3f4f6" Margin="0,4" FontSize="11.5"/>
                                <CheckBox Name="chkDirectX" Content="DirectX Shader Cache" IsChecked="True" Foreground="#f3f4f6" Margin="0,4" FontSize="11.5"/>
                                <CheckBox Name="chkDns" Content="DNS Resolver Cache" IsChecked="True" Foreground="#f3f4f6" Margin="0,4" FontSize="11.5"/>
                                <CheckBox Name="chkRecycle" Content="Recycle Bin Cache" IsChecked="True" Foreground="#f3f4f6" Margin="0,4" FontSize="11.5"/>
                                <CheckBox Name="chkPrefetch" Content="Prefetch Cache" IsChecked="True" Foreground="#f3f4f6" Margin="0,4" FontSize="11.5"/>
                                <CheckBox Name="chkMemory" Content="Memory Cleaner (RAM)" IsChecked="True" Foreground="#f3f4f6" Margin="0,4" FontSize="11.5"/>
                            </StackPanel>
                        </ScrollViewer>
                        
                        <Separator Grid.Row="2" Background="#1f2937" Margin="0,10"/>
                        
                        <StackPanel Grid.Row="3">
                            <CheckBox Name="chkRestorePoint" Content="Create Restore Point first" IsChecked="False" Foreground="#f3f4f6" Margin="0,0,0,6" FontSize="11"/>
                            <CheckBox Name="chkNoServiceStop" Content="Don't Stop Update Services" IsChecked="False" Foreground="#f3f4f6" Margin="0,0,0,10" FontSize="11"/>
                            <Button Name="btnSystemRestore" Style="{StaticResource ModernButton}" Content="Launch System Restore" Margin="0,0,0,10" Height="26"/>
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <Button Name="btnSelectAll" Style="{StaticResource ModernButton}" Content="Select All" Grid.Column="0" Margin="0,0,3,0" Height="26"/>
                                <Button Name="btnSelectNone" Style="{StaticResource ModernButton}" Content="Clear All" Grid.Column="1" Margin="3,0,0,0" Height="26"/>
                            </Grid>
                        </StackPanel>
                    </Grid>
                </Border>
                
                <Border Grid.Column="1" Background="#030712" BorderBrush="#1f2937" BorderThickness="1" CornerRadius="8" Padding="10" Margin="10,0,0,0">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>
                        <Label Content="Output Log" FontSize="13" FontWeight="Bold" Foreground="#f9fafb" Margin="0,0,0,8" Padding="0"/>
                        <TextBox Name="txtLog" Grid.Row="1" Background="Transparent" Foreground="#22d3ee" BorderBrush="Transparent" BorderThickness="0"
                                 FontFamily="Consolas" FontSize="11" VerticalScrollBarVisibility="Auto" IsReadOnly="True" AcceptsReturn="True" TextWrapping="Wrap"/>
                    </Grid>
                </Border>
            </Grid>

            <!-- 4. Footer -->
            <Border Grid.Row="3" Background="#0f172a" BorderBrush="#1f2937" BorderThickness="0,1,0,0" CornerRadius="0,0,12,12" Padding="20,15">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    
                    <StackPanel Grid.Column="0" VerticalAlignment="Center">
                        <Label Content="Status: Ready" Name="lblStatus" FontSize="12" Foreground="#9ca3af" Padding="0"/>
                    </StackPanel>
                    
                    <Button Name="btnScan" Style="{StaticResource ModernButton}" Content="Scan Only" Grid.Column="1" Width="100" Height="32" Margin="0,0,10,0"/>
                    <Button Name="btnRun" Style="{StaticResource ActionButton}" Content="Run Clean" Grid.Column="2" Width="120" Height="32"/>
                </Grid>
            </Border>
        </Grid>
    </Border>
</Window>
"@

    # 6b. Parse and Load XAML
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName System.Windows.Forms
    
    $xamlClean = $xamlString -replace 'mc:Ignorable="d"', '' -replace 'x:Class="[^"]+"', '' -replace 'xmlns:mc="[^"]+"', '' -replace 'xmlns:d="[^"]+"', ''
    [xml]$xml = $xamlClean
    $reader = New-Object System.Xml.XmlNodeReader $xml
    $window = [Windows.Markup.XamlReader]::Load($reader)
    
    # Bind WPF Controls
    $chkTemp = $window.FindName("chkTemp")
    $chkUpdate = $window.FindName("chkUpdate")
    $chkNvidia = $window.FindName("chkNvidia")
    $chkDirectX = $window.FindName("chkDirectX")
    $chkDns = $window.FindName("chkDns")
    $chkRecycle = $window.FindName("chkRecycle")
    $chkPrefetch = $window.FindName("chkPrefetch")
    $chkMemory = $window.FindName("chkMemory")
    $chkRestorePoint = $window.FindName("chkRestorePoint")
    $chkNoServiceStop = $window.FindName("chkNoServiceStop")
    $btnSystemRestore = $window.FindName("btnSystemRestore")
    
    $btnSelectAll = $window.FindName("btnSelectAll")
    $btnSelectNone = $window.FindName("btnSelectNone")
    $btnScan = $window.FindName("btnScan")
    $btnRun = $window.FindName("btnRun")
    
    $global:txtLog = $window.FindName("txtLog")
    $lblStatus = $window.FindName("lblStatus")
    
    # Custom Title Bar Control Bindings
    $btnClose = $window.FindName("btnClose")
    $btnMinimize = $window.FindName("btnMinimize")
    $titleBar = $window.FindName("titleBar")
    $btnDiscord = $window.FindName("btnDiscord")
    $imgIcon = $window.FindName("imgIcon")
    $imgMiniIcon = $window.FindName("imgMiniIcon")
    
    # Load Icon image dynamically from the script folder
    $iconPath = Join-Path $PSScriptRoot "system_cleaner_icon.png"
    if (Test-Path $iconPath) {
        try {
            $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
            $bitmap.BeginInit()
            $bitmap.UriSource = [Uri]$iconPath
            $bitmap.EndInit()
            $window.Icon = $bitmap
            $imgIcon.Source = $bitmap
            $imgMiniIcon.Source = $bitmap
        } catch {
            # Gracefully ignore icon loading errors if shell blocks it
        }
    }
    
    # Custom Event Handlers
    $btnClose.Add_Click({
        $window.Close()
    })
    
    $btnMinimize.Add_Click({
        $window.WindowState = [System.Windows.WindowState]::Minimized
    })
    
    $titleBar.Add_MouseLeftButtonDown({
        $window.DragMove()
    })
    
    $btnDiscord.Add_Click({
        try {
            Start-Process "https://discord.com/invite/YTeRSG8kER"
        } catch {
            Write-Log "Failed to open Discord. Join at: https://discord.com/invite/YTeRSG8kER" -Level Warning
        }
    })
    
    $btnSystemRestore.Add_Click({
        try {
            Start-Process "rstrui.exe"
        } catch {
            Write-Log "Failed to launch System Restore Wizard." -Level Error
        }
    })
    
    # 6c. Configure UI Event Handlers
    $btnSelectAll.Add_Click({
        $chkTemp.IsChecked = $true
        $chkUpdate.IsChecked = $true
        $chkNvidia.IsChecked = $true
        $chkDirectX.IsChecked = $true
        $chkDns.IsChecked = $true
        $chkRecycle.IsChecked = $true
        $chkPrefetch.IsChecked = $true
        $chkMemory.IsChecked = $true
    })
    
    $btnSelectNone.Add_Click({
        $chkTemp.IsChecked = $false
        $chkUpdate.IsChecked = $false
        $chkNvidia.IsChecked = $false
        $chkDirectX.IsChecked = $false
        $chkDns.IsChecked = $false
        $chkRecycle.IsChecked = $false
        $chkPrefetch.IsChecked = $false
        $chkMemory.IsChecked = $false
    })
    
    $btnScan.Add_Click({
        $btnScan.IsEnabled = $false
        $btnRun.IsEnabled = $false
        $lblStatus.Content = "Status: Scanning..."
        $global:txtLog.Clear()
        
        Write-Log "Starting Cache Scan (Dry Run)..."
        Update-UI
        
        $reportTable = @()
        $totalReclaimed = 0
        
        if ($chkTemp.IsChecked) {
            $tempRes = Clear-WindowsTempCache -ScanOnly:$true
            $reportTable += $tempRes
            foreach ($r in $tempRes) { $totalReclaimed += $r.RawFreed }
        }
        if ($chkUpdate.IsChecked) {
            $updateRes = Clear-WindowsUpdateCache -ScanOnly:$true -NoServiceStop:$chkNoServiceStop.IsChecked
            $reportTable += $updateRes
            $totalReclaimed += $updateRes.RawFreed
        }
        if ($chkNvidia.IsChecked) {
            $nvRes = Clear-NvidiaGraphicsCache -ScanOnly:$true
            $reportTable += $nvRes
            $totalReclaimed += $nvRes.RawFreed
        }
        if ($chkDirectX.IsChecked) {
            $dxRes = Clear-DirectXShaderCache -ScanOnly:$true
            $reportTable += $dxRes
            $totalReclaimed += $dxRes.RawFreed
        }
        if ($chkDns.IsChecked) {
            $dnsRes = Clear-DnsCache -ScanOnly:$true
            $reportTable += $dnsRes
        }
        if ($chkRecycle.IsChecked) {
            $rbRes = Clear-RecycleBinCache -ScanOnly:$true
            $reportTable += $rbRes
            $totalReclaimed += $rbRes.RawFreed
        }
        if ($chkPrefetch.IsChecked) {
            $prefRes = Clear-PrefetchCache -ScanOnly:$true
            $reportTable += $prefRes
            $totalReclaimed += $prefRes.RawFreed
        }
        if ($chkMemory.IsChecked) {
            $memRes = Clear-MemoryCache -ScanOnly:$true
            $reportTable += $memRes
        }
        
        Write-Log "---------------------------------------------------------"
        Write-Log "                   SCAN ONLY RESULTS SUMMARY"
        Write-Log "---------------------------------------------------------"
        foreach ($item in $reportTable) {
            Write-Log "  $($item.'Cache Name'): $($item.'Space Freed')"
        }
        Write-Log "---------------------------------------------------------"
        Write-Log "Estimated Total Savings: $(Format-Size $totalReclaimed)" -Level Success
        Write-Log "---------------------------------------------------------"
        
        $lblStatus.Content = "Status: Ready"
        $btnScan.IsEnabled = $true
        $btnRun.IsEnabled = $true
    })
    
    $btnRun.Add_Click({
        $btnScan.IsEnabled = $false
        $btnRun.IsEnabled = $false
        $lblStatus.Content = "Status: Cleaning Caches..."
        $global:txtLog.Clear()
        
        Write-Log "Starting Cache Cleanup..."
        Update-UI
        
        if ($chkRestorePoint.IsChecked) {
            New-SystemRestorePoint
            Update-UI
        }
        
        $reportTable = @()
        $totalReclaimed = 0
        
        if ($chkTemp.IsChecked) {
            Write-Log "Cleaning Windows Temp Cache..." -Level Step
            $tempRes = Clear-WindowsTempCache -ScanOnly:$false
            $reportTable += $tempRes
            foreach ($r in $tempRes) { $totalReclaimed += $r.RawFreed }
        }
        if ($chkUpdate.IsChecked) {
            Write-Log "Cleaning Windows Update Cache..." -Level Step
            $updateRes = Clear-WindowsUpdateCache -ScanOnly:$false -NoServiceStop:$chkNoServiceStop.IsChecked
            $reportTable += $updateRes
            $totalReclaimed += $updateRes.RawFreed
        }
        if ($chkNvidia.IsChecked) {
            Write-Log "Cleaning NVIDIA DX/GL Cache..." -Level Step
            $nvRes = Clear-NvidiaGraphicsCache -ScanOnly:$false
            $reportTable += $nvRes
            $totalReclaimed += $nvRes.RawFreed
        }
        if ($chkDirectX.IsChecked) {
            Write-Log "Cleaning DirectX Shader Cache..." -Level Step
            $dxRes = Clear-DirectXShaderCache -ScanOnly:$false
            $reportTable += $dxRes
            $totalReclaimed += $dxRes.RawFreed
        }
        if ($chkDns.IsChecked) {
            Write-Log "Flushing DNS Client Cache..." -Level Step
            $dnsRes = Clear-DnsCache -ScanOnly:$false
            $reportTable += $dnsRes
        }
        if ($chkRecycle.IsChecked) {
            Write-Log "Cleaning Recycle Bin..." -Level Step
            $rbRes = Clear-RecycleBinCache -ScanOnly:$false
            $reportTable += $rbRes
            $totalReclaimed += $rbRes.RawFreed
        }
        if ($chkPrefetch.IsChecked) {
            Write-Log "Cleaning Prefetch Cache..." -Level Step
            $prefRes = Clear-PrefetchCache -ScanOnly:$false
            $reportTable += $prefRes
            $totalReclaimed += $prefRes.RawFreed
        }
        if ($chkMemory.IsChecked) {
            Write-Log "Running Memory Cleaner..." -Level Step
            $memRes = Clear-MemoryCache -ScanOnly:$false
            $reportTable += $memRes
        }
        
        Write-Log "---------------------------------------------------------"
        Write-Log "                   CLEANUP SUMMARY"
        Write-Log "---------------------------------------------------------"
        foreach ($item in $reportTable) {
            Write-Log "  $($item.'Cache Name'): $($item.'Space Freed')"
        }
        Write-Log "---------------------------------------------------------"
        Write-Log "Total Disk Space Saved: $(Format-Size $totalReclaimed)" -Level Success
        Write-Log "---------------------------------------------------------"
        Write-Log "Cleanup complete. Locked files currently in use by Windows were skipped." -Level Warning
        
        $lblStatus.Content = "Status: Cleanup Complete"
        $btnScan.IsEnabled = $true
        $btnRun.IsEnabled = $true
    })
    
    # 6d. Initialize GUI Dialog Session
    $window.ShowDialog() | Out-Null
} else {
    # -----------------------------------------------------------------------------
    # 7. Headless CLI Execution Flow
    # -----------------------------------------------------------------------------
    Clear-Host
    Write-Host "=========================================================" -ForegroundColor Cyan
    if ($ScanOnly) {
        Write-Host "      Windows Cache Cleanup Tool - SCAN ONLY" -ForegroundColor Cyan
    } else {
        Write-Host "           Windows Cache Cleanup Tool" -ForegroundColor Cyan
    }
    Write-Host "=========================================================" -ForegroundColor Cyan
    Write-Log "Running with Administrator privileges." -Level Success
    
    $reportTable = @()
    $totalReclaimed = 0
    
    # Step 1: Temp Cache
    Write-Log "Task 1/7: Temp Cache Folder Operations" -Level Step
    $tempRes = Clear-WindowsTempCache -ScanOnly:$ScanOnly
    $reportTable += $tempRes
    foreach ($r in $tempRes) { $totalReclaimed += $r.RawFreed }
    
    # Step 2: Windows Update Cache
    Write-Log "Task 2/7: Windows Update Cache Operations" -Level Step
    $updateRes = Clear-WindowsUpdateCache -ScanOnly:$ScanOnly -NoServiceStop:$NoServiceStop
    $reportTable += $updateRes
    $totalReclaimed += $updateRes.RawFreed
    
    # Step 3: NVIDIA Caches
    Write-Log "Task 3/7: NVIDIA Cache Operations" -Level Step
    $nvRes = Clear-NvidiaGraphicsCache -ScanOnly:$ScanOnly
    $reportTable += $nvRes
    $totalReclaimed += $nvRes.RawFreed
    
    # Step 4: DirectX Cache
    Write-Log "Task 4/7: DirectX Cache Operations" -Level Step
    $dxRes = Clear-DirectXShaderCache -ScanOnly:$ScanOnly
    $reportTable += $dxRes
    $totalReclaimed += $dxRes.RawFreed
    
    # Step 5: DNS Resolver Cache
    Write-Log "Task 5/7: DNS Cache Operations" -Level Step
    $dnsRes = Clear-DnsCache -ScanOnly:$ScanOnly
    $reportTable += $dnsRes
    
    # Step 6: Recycle Bin
    Write-Log "Task 6/7: Recycle Bin Operations" -Level Step
    $rbRes = Clear-RecycleBinCache -ScanOnly:$ScanOnly
    $reportTable += $rbRes
    $totalReclaimed += $rbRes.RawFreed
    
    # Step 7: Prefetch Cache
    Write-Log "Task 7/7: Prefetch Cache Operations" -Level Step
    $prefRes = Clear-PrefetchCache -ScanOnly:$ScanOnly
    $reportTable += $prefRes
    $totalReclaimed += $prefRes.RawFreed
    
    # Step 8: Memory Cleaner
    if ($MemoryClean -or $global:guiMode) {
        Write-Log "Task 8/8: Memory Cleaner Operations" -Level Step
        $memRes = Clear-MemoryCache -ScanOnly:$ScanOnly
        $reportTable += $memRes
    }
    
    # Pre-cleanup Restore Point (CLI)
    if ($CreateRestorePoint -and -not $ScanOnly) {
        New-SystemRestorePoint
    }
    
    # Output CLI report table
    Write-Host ""
    Write-Host "=========================================================" -ForegroundColor Cyan
    if ($ScanOnly) {
        Write-Host "               SCAN ONLY RESULTS SUMMARY" -ForegroundColor Cyan
    } else {
        Write-Host "                   CLEANUP SUMMARY" -ForegroundColor Cyan
    }
    Write-Host "=========================================================" -ForegroundColor Cyan
    
    $reportTable | Select-Object "Cache Name", "Initial", "Final", "Space Freed" | Format-Table -AutoSize
    
    if ($ScanOnly) {
        Write-Log "Estimated Total Savings: $(Format-Size $totalReclaimed)" -Level Success
    } else {
        Write-Log "Total Disk Space Saved:  $(Format-Size $totalReclaimed)" -Level Success
    }
    Write-Host "=========================================================" -ForegroundColor Cyan
    Write-Host ""
    
    if (-not $ScanOnly) {
        Write-Log "Active files currently in use by Windows or open programs were skipped." -Level Warning
    }
    
    if (-not $Silent) {
        Write-Log "Press any key to close..."
        $null = [Console]::ReadKey($true)
    }
}
