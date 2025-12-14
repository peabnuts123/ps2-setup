# ============================================================================
# Configuration
# ============================================================================

function Get-RequiredConfigValue {
    param(
        [hashtable]$Config,
        [string]$Key
    )

    if ($null -eq $Config[$Key] -or $Config[$Key].Trim() -eq "") {
        throw "Missing required config: '$Key'"
    }
    else {
        return $Config[$Key]
    }
}

function Get-OptionalConfigValue {
    param(
        [hashtable]$Config,
        [string]$Key,
        [string]$DefaultValue = ""
    )

    if ($null -eq $Config[$Key] -or $Config[$Key].Trim() -eq "") {
        return $DefaultValue
    }
    else {
        return $Config[$Key]
    }
}

$config = Import-PowerShellDataFile -Path ".\config.psd1"

[string]$PS2_DEVICE = Get-RequiredConfigValue -Config $config -Key "Ps2Device"
[string]$OPL_PARTITION = Get-RequiredConfigValue -Config $config -Key "OplPartition"
[string]$COMMON_PARTITION = Get-RequiredConfigValue -Config $config -Key "CommonPartition"
[string]$POPS_PARTITION = Get-RequiredConfigValue -Config $config -Key "PopsPartition"
[string]$ART_ZIP_PATH = Get-OptionalConfigValue -Config $config -Key "ArtZipPath" -DefaultValue ""

[string]$PFSSHELL_PATH = "lib\pfsshell\pfsshell.exe"
[string]$COPY_ROOT = "__copy"
[string]$COPY_PLACEHOLDER_FILE_NAME = "place-files-to-copy-here"

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

    # Get all items recursively (ignore copy placeholders)
    $items = Get-ChildItem -Path $SourcePath -Recurse | Where-Object { $_.Name -ne $COPY_PLACEHOLDER_FILE_NAME }

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
        Write-Host "Copying file: '$relativePath'..."
        $commands += "put `"$relativePath`""
    }

    # Unmount partition
    $commands += "umount"

    Invoke-PfsShell -Commands $commands > $null
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

    $result = Invoke-PfsShell -Commands $commands

    # Filter to only show lines after "../"
    $found_start = $false
    $filteredResult = $result | ForEach-Object {
        if ($_ -eq "") {
            # Ignore empty lines
            return
        }
        elseif ($found_start) {
            # Print all lines after the start of the list
            $_
        }
        elseif ($_ -eq "../") {
            # List starts after `../`
            $found_start = $true
        }
    }

    return $filteredResult
}

function Get-PfsPartitionNames {
    $commands = @()
    $commands += "ls"

    $result = Invoke-PfsShell -Commands $commands

    # Filter to only show lines after "Device ..." header
    $found_start = $false
    $skipped_first_line = $false
    $filteredResult = $result | ForEach-Object {
        if ($_ -eq "") {
            # Ignore empty lines
            return
        }
        elseif ($found_start -and -not $skipped_first_line) {
            # Skip the first line after ../
            $skipped_first_line = $true
        }
        elseif ($found_start -and $skipped_first_line) {
            # Print all lines after the start of the list
            $_
        }
        elseif ($_.StartsWith("Device ")) {
            # List starts one line after `Device ...`
            $found_start = $true
        }
    }

    # Extract partition name from ls output
    $parsedLines = $filteredResult | ForEach-Object {
        $parts = $_ -split '\s+'
        $parts[-1]
    }

    return $parsedLines
}


# ============================================================================
# Main
# ============================================================================

# === Phase 0 - Copy any source files
# PSX .VCD files
Copy-ToPfsRecursive -Partition $POPS_PARTITION -SourcePath "$COPY_ROOT\POPS" -DestPath "/"

# === Phase 0.1 - Read in HDD state
# Read all .VCD files
$all_psx_data = Get-PfsFilePaths -Partition $POPS_PARTITION -Path "/" | ForEach-Object {
    if ($_ -like "*.VCD") {
        # `$_` looks like `SCES_015.64.Ape Escape.VCD`

        # Extract to object
        # e.g. SCES_015.64.Ape Escape
        $fileName = [System.IO.Path]::GetFileNameWithoutExtension($_)

        # Split file name by . and take different parts
        # e.g.
        #   gameName = "Ape Escape"
        #   titleId = "SCES_015.64"
        $parts = $fileName -split '\.'
        if ($parts.Count -ge 2) {
            $gameName = $parts[-1]
            $titleId = ($parts[0..($parts.Count - 2)] -join '.')
        }
        else {
            # Invalid file name format, skip
            Write-Host "Skipping unrecognised file name format: '$fileName'"
            return
        }
        #
        [PSCustomObject]@{
            FileName = $fileName
            GameName = $gameName
            TitleId = $titleId
        }
    }
}
# Read all existing app config directories
$existing_opl_apps = Get-PfsFilePaths -Partition $OPL_PARTITION -Path "/APPS"
# Read all existing art files
$existing_art_files = Get-PfsFilePaths -Partition $OPL_PARTITION -Path "/ART"
# Read all HDD partition names (for PS2 games)
$all_partition_names = Get-PfsPartitionNames
$all_ps2_data = $all_partition_names | Where-Object { $_ -like "PP.*" } | ForEach-Object {
    # e.g. PP.SLUS-20685..APE_ESCAPE_2
    # Trim possible trailing * (which shows in pfsshell output)
    $partitionName = $_ -replace '\*$', ''

    # Extract and reformat Title ID
    # e.g. `PP.SLUS-20685..APE_ESCAPE_2` -> `SLUS_206.85`
    $trimmed = $partitionName.Substring(3)  # Remove `PP.`
    $parts = $trimmed -split '\.\.'         # Split into `SLUS-20685` and `APE_ESCAPE_2*`
    $titleIdParts = $titleId -split '-'     # Split title ID into `SLUS` and `20685`
    $titleId = $titleIdParts[0] + "_" + $titleIdParts[1].Insert(3, ".")  # e.g. `SLUS_206.85`
    [PSCustomObject]@{
        GameName = $parts[1]
        TitleId = $titleId
    }
}

# === Phase 0.2 - Output summary of HDD state
Write-Host ""
Write-Host "============================================================"
Write-Host "HDD State Summary"
Write-Host "============================================================"
Write-Host ""

Write-Host "PS2 Games Found: $($all_ps2_data.Count)"
foreach ($game in $all_ps2_data) {
  Write-Host "  - $($game.TitleId) - $($game.GameName)"
}
Write-Host ""

Write-Host "PSX Games Found: $($all_psx_data.Count)"
foreach ($game in $all_psx_data) {
  Write-Host "  - $($game.TitleId) - $($game.GameName)"
}
Write-Host ""

Write-Host "Existing OPL App Configs: $($existing_opl_apps.Count)"
foreach ($app in $existing_opl_apps) {
  Write-Host "  - $app"
}
Write-Host ""

Write-Host "Existing Art Files: $($existing_art_files.Count)"
foreach ($art in $existing_art_files) {
  Write-Host "  - $art"
}
Write-Host ""

Write-Host "============================================================"
Write-Host ""



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
    # 1. Read and validate config from build.config or something
    #     1. PS2_DEVICE
    #     1. OPL Partition
    #     1. Common partition
    #     1. POPS partition
    #     1. ART ZIP path (optional)
    # 1. Copy __copy/POPS to __.POPS:/ partition
    # 1. ls __.POPS
        # 1. For each .VCD file: extract game ID, game title, file name into an array of PS1 data
    # 1. ls +OPL:/APPS
    # 1. ls (no mount) -> extract all partitions called PP.* into array of PS2 data
    # 1. ls +OPL:/ART -> store all current art file paths
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

