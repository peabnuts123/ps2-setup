

# Get block device path using:
# Get-CimInstance -ClassName Win32_DiskDrive | Select-Object Caption, DeviceID, InterfaceType

# lcd <source dir>
# device \\.\PHYSICALDRIVE5
# mount +OPL

# Iterate all files from source_dir
# call


# SCES_015.64.Ape Escape\title.cfg

# .\pfsfuse\pfsfuse.exe --partition=+OPL \\.\PHYSICALDRIVE5 X -o volname=OPL


# ============================================================================
# Configuration
# ============================================================================

$PS2_DEVICE = "\\.\PHYSICALDRIVE5"
$COMMON_PARTITION = "__common"
$OPL_PARTITION = "+OPL"
$POPS_PARTITION = "__.POPS"
$PFSSHELL_PATH = ".\pfsshell\pfsshell.exe"
$SOURCE_ROOT = (Get-Location).Path
$ART_ZIP_PATH = "D:\_Downloading\PS2\OPLM_ART_2024_09.zip"
# $SOURCE_ROOT = "D:\_Downloading\PS2\Physical Apps\OPL_Manager_V24\hdl_hdd"


# ============================================================================
# Functions
# ============================================================================

function Invoke-PfsShell {
    param(
        [string[]]$Commands
    )

    $cmds = @()
    $cmds += "device $PS2_DEVICE"
    $cmds += $Commands

    $output = $cmds -join "`n" | & $PFSSHELL_PATH 2>$null | Out-String
    return ($output -split "`n") | ForEach-Object { $_.Trim() }
}

function Get-ZipPaths {
    param(
        [string]$ZipPath,
        [string[]]$Prefixes = @("")
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)

    Write-Host "[Zip] Reading: ${Prefixes}"

    try {
        $entries = $zip.Entries |
            Where-Object { -not $_.FullName.EndsWith('/') } |  # Skip directories
            Where-Object {
                $entry = $_
                $Prefixes | Where-Object { $entry.FullName.StartsWith($_) } | Select-Object -First 1
            } |
            ForEach-Object { $_.FullName }

        return $entries
    }
    finally {
        $zip.Dispose()
    }
}

function Expand-ZipFiles {
    param(
        [string]$ZipPath,
        [string[]]$Entries,
        [string]$Destination
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem

    # Ensure destination exists
    if (-not (Test-Path $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }

    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)

    try {
        foreach ($entryPath in $Entries) {
            $entry = $zip.Entries | Where-Object { $_.FullName -eq $entryPath } | Select-Object -First 1
            if ($entry) {
                $destFile = Join-Path $Destination $entry.Name
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destFile, $true)
            }
        }
    }
    finally {
        $zip.Dispose()
    }
}

function Copy-ToPfsRecursive {
    param(
        [string]$Partition,       # Name of partition in PFS
        [string]$SourcePath,      # Local folder to copy, e.g. "D:\PS2 BKP\APPS"
        [string]$DestPath         # Destination path on PS2, e.g. "APPS" (relative to mount root)
    )

    $commands = @()

    $commands += "mount $Partition"

    # Normalize source path
    $SourcePath = (Resolve-Path $SourcePath).Path.TrimEnd('\')

    # Set local working directory to source root
    $commands += "lcd `"$SourcePath`""

    # Create and enter the top-level destination directory
    $commands += "mkdir `"$DestPath`""
    $commands += "cd `"$DestPath`""

    # Get all items recursively
    $items = Get-ChildItem -Path $SourcePath -Recurse

    # Separate directories and files
    $directories = $items | Where-Object { $_.PSIsContainer } | Sort-Object { $_.FullName.Split('\').Count }
    $files = $items | Where-Object { -not $_.PSIsContainer }

    # First pass: create all directories (sorted by depth so parents come first)
    foreach ($dir in $directories) {
        $relativePath = $dir.FullName.Substring($SourcePath.Length + 1) -replace '\\', '/'
        $commands += "mkdir `"$relativePath`""
    }

    # Second pass: copy all files
    foreach ($file in $files) {
        $relativePath = $file.FullName.Substring($SourcePath.Length + 1) -replace '\\', '/'
        $commands += "put `"$relativePath`""
    }

    # Unmount partition
    $commands += "umount"

    return $commands
}

function Get-PfsFilePaths {
  param(
        [string]$Partition,         # Name of partition in PFS
        [string]$Path               # Path within PFS partition to show
  )

    $commands = @()
    $commands += "mount $Partition"
    $commands += "cd `"$Path`""
    $commands += "ls"
    $commands += "umount"

    Write-Host "Invoking"
    $result = Invoke-PfsShell -Commands $commands

    # Filter to only show lines after "../"
    $found_start = $false
    $filteredResult = $result | ForEach-Object {
        if ($_ -eq "") {
            # Ignore empty lines
            return
        } elseif ($found_start) {
            # Print all lines after the start of the list
            $_
        } elseif ($_ -eq "../") {
            # List starts after `../`
            $found_start = $true
        }
    }

    Write-Host "<OUTPUT>"
    $filteredResult | ForEach-Object { Write-Host $_ }
    Write-Host "</OUTPUT>"
}


# ============================================================================
# Main
# ============================================================================

# # Build up the command list
# $cmds = @()
# $cmds += "device $PS2_DEVICE"
# $cmds += "mount $PS2_PARTITION"

# # Copy folders
# $cmds += Copy-ToPfsRecursive -Partition $OPL_PARTITION -SourcePath "$SOURCE_ROOT\APPS" -DestPath "/APPS"
# # $cmds += Copy-ToPfsRecursive -SourcePath "$SOURCE_ROOT\ART" -DestPath "/ART"
# # $cmds += Get-PfsRecursiveCopyCommands -SourcePath "$SOURCE_ROOT\POPS" -DestPath "POPS"

# $cmds += "umount"
# $cmds += "exit"

# # Dry run
# Write-Output $cmds
# # Run for real (uncomment when ready)
# # $cmds -join "`n" | & $PFSSHELL_PATH



<#
    # One time setup
    - Make partition called __.POPS
    - make __common:/POPS
    - put POPS.ELF and IOPRP252.IMG into __common:/POPS/


    # Add games (manual steps by user)
    - (PS2 games installed with HDL Batch or whatever)
    - PS1 games VCDs placed in __copy/POPS

    # Script logic
    1. Read and validate config from build.config or something
        1. PS2_DEVICE
        1. OPL Partition
        1. Common partition
        1. POPS partition
        1. ART ZIP path (optional)
    1. Copy __copy/POPS to __.POPS:/ partition
    1. ls __.POPS
    1. ls +OPL:/APPS
    1. ls (no mount) -> extract all partitions called PP.* into array of PS2 data
    1. ls +OPL:/ART -> store all current art file paths
    1. For each .VCD file: extract game ID, game title, file name into an array of PS1 data
    1. For each VCD file that doesn't have an APPS folder
        1. Create __temp/APPS/SCES.XX.YY.Game/
        1. Create __temp/APPS/SCES.XX.YY.Game/title.cfg with title = GameTitle and boot = FileName.ELF
        1. Create __temp/APPS/SCES.XX.YY.Game/FileName.ELF
    1. For each PS2 datum
        1. Store zip query prefix: `PS2/GameId`
    1. For each PS1 datum
        1. Store zip query prefix: `PS1/GameId`
    1. If ARTZIP exists, query for all prefixes into list of files
    1. For each game ID,ArtType
        1. If any existing art paths exist with GameID, ignore game
        1. Pick a file from the list, store it in an array with src/destination
        1. src = path in zip file
        1. dest = renamed output e.g. SLUS-20685_BG.png
    1. Collect all `.src` and extract files from ARTZIP to __temp/ART
    1. Iterate src/dest array of art files and use basename of `src` as param to rename to `dest`
    1. Copy _temp/ to +OPL:/
#>

# ============================================================================
# Test zip functions
# ============================================================================

# Write-Host "Testing Get-ZipPaths..."
# $contents = Get-ZipPaths -ZipPath $ART_ZIP_PATH -Prefixes @("PS1/SCES_015.64/", "PS1/SCUS_942.36/")
# $contents | ForEach-Object { Write-Host $_ }

Get-PfsFilePaths -Partition $COMMON_PARTITION -Path "/POPS"
