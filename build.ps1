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
# @TODO Unused
[string]$COMMON_PARTITION = Get-RequiredConfigValue -Config $config -Key "CommonPartition"
[string]$POPS_PARTITION = Get-RequiredConfigValue -Config $config -Key "PopsPartition"
[string]$ART_ZIP_PATH = Get-OptionalConfigValue -Config $config -Key "ArtZipPath" -DefaultValue ""
[boolean]$ART_ZIP_EXISTS = $ART_ZIP_PATH -ne ""
if ($ART_ZIP_EXISTS -and -not (Test-Path $ART_ZIP_PATH)) {
    throw "ART ZIP path specified does not exist: '$ART_ZIP_PATH'"
}
[string[]]$ART_FILE_TYPES = @(
    "COV",
    "COV2",
    "ICO",
    "LGO",
    "LAB",
    "SCR",
    "BG"
)

[string]$PFSSHELL_PATH = "lib\pfsshell\pfsshell.exe"
[string]$POPSTARTER_PATH = "lib\popstarter\POPSTARTER.ELF"
[string]$COPY_ROOT = "__copy"
[string]$TEMP_ROOT = "__temp"
[string]$COPY_PLACEHOLDER_FILE_NAME = "place-files-to-copy-here"
[string]$BLANK_MEMORY_CARD_PATH = "lib\blank_memory_card.bin"

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

    Write-Host "Copying directory '$SourcePath' to PFS '${Partition}:${DestPath}'..."

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

function Get-RandomArtPath {
    param(
        [string[]]$ArtPaths,
        [string]$TitleId,
        [string]$ArtType,
        [int]$Count = 1
    )

    # Filter art paths to only those matching TitleId and ArtType
    $paths_of_type_for_title = @($ArtPaths | Where-Object { $_ -like "*/${TitleId}_${ArtType}.*" -or $_ -like "*/${TitleId}_${ArtType}_*" })

    $result = @()
    for ($i = 0; $i -lt $Count; $i++) {
        if ($paths_of_type_for_title.Count -eq 0) {
            break
        }

        # Pick a random index
        $randomIndex = Get-Random -Minimum 0 -Maximum $paths_of_type_for_title.Count
        $selectedPath = $paths_of_type_for_title[$randomIndex]

        # Add to result
        $result += $selectedPath

        # Remove selected path from available paths
        $paths_of_type_for_title = @($paths_of_type_for_title | Where-Object { $_ -ne $selectedPath })
    }

    return $result
}


# ============================================================================
# Main
# ============================================================================

# Proactively clean up any old temp files (e.g. if previous run crashed)
if (Test-Path $TEMP_ROOT) {
    Remove-Item -Path $TEMP_ROOT -Recurse -Force
}

# === Phase 0 - Copy any source files
Write-Host "Copying source files to HDD..."
# PSX .VCD files
Copy-ToPfsRecursive -Partition $POPS_PARTITION -SourcePath "$COPY_ROOT\POPS" -DestPath "/"

# === Phase 0.1 - Read in HDD state
Write-Host "Reading HDD state..."
# Read all .VCD files
Write-Host "Scanning for PSX .VCD files..."
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

        # Write-Host "  [DEBUG] Found PSX game: $titleId ($gameName)"
        [PSCustomObject]@{
            FileName = $fileName
            GameName = $gameName
            TitleId  = $titleId
        }
    }
}
Write-Host "Found $($all_psx_data.Count) PSX games"
# Read all existing app config directories
Write-Host "Reading existing APPS folders..."
[string[]]$existing_opl_apps = Get-PfsFilePaths -Partition $OPL_PARTITION -Path "/APPS"
# Read all existing art files
Write-Host "Reading existing ART files..."
[string[]]$existing_art_files = Get-PfsFilePaths -Partition $OPL_PARTITION -Path "/ART"
# Read all HDD partition names (for PS2 games)
Write-Host "Scanning for PS2 game partitions..."
[string[]]$all_partition_names = Get-PfsPartitionNames
$all_ps2_data = $all_partition_names | Where-Object { $_ -like "PP.*" } | ForEach-Object {
    # e.g. PP.SLUS-20685..APE_ESCAPE_2
    # Trim possible trailing * (which shows in pfsshell output)
    $partitionName = $_ -replace '\*$', ''

    # Extract and reformat Title ID
    # e.g. `PP.SLUS-20685..APE_ESCAPE_2` -> `SLUS_206.85`
    $trimmed = $partitionName.Substring(3)  # Remove `PP.`
    $parts = $trimmed -split '\.\.'         # Split into `SLUS-20685` and `APE_ESCAPE_2`
    $titleIdParts = $parts[0] -split '-'     # Split title ID into `SLUS` and `20685`
    $titleId = $titleIdParts[0] + "_" + $titleIdParts[1].Insert(3, ".")  # e.g. `SLUS_206.85`
    # Write-Host "  [DEBUG] Found PS2 game: $titleId ($($parts[1]))"
    [PSCustomObject]@{
        TitleId = $titleId
    }
}
Write-Host "Found $($all_ps2_data.Count) PS2 games"
# Read all CFG files
Write-Host "Reading existing CFG files..."
[string[]]$existing_cfg_files = Get-PfsFilePaths -Partition $OPL_PARTITION -Path "/CFG"
# Read all VMC files
Write-Host "Reading existing VMC files..."
[string[]]$existing_vmc_files = Get-PfsFilePaths -Partition $OPL_PARTITION -Path "/VMC"

# === Phase 1 - Generate missing APPS folders
Write-Host "Generating missing APPS folders..."
# Create temp folder
New-Item -ItemType Directory -Path $TEMP_ROOT -Force | Out-Null

foreach ($psx in $all_psx_data) {
    # Check if any existing APPS folders start with the psx title ID
    $matching_apps = $existing_opl_apps | Where-Object { $_ -like "$($psx.TitleId)*" }
    if ($matching_apps.Count -eq 0) {
        # No existing APPS folder, create one
        $appsFolderPath = Join-Path $TEMP_ROOT "APPS\$($psx.FileName)"
        New-Item -ItemType Directory -Path $appsFolderPath -Force | Out-Null

        # Create title.cfg
        $titleCfgPath = Join-Path $appsFolderPath "title.cfg"
        $titleCfgContent = @"
title=$($psx.GameName)
boot=$($psx.FileName).ELF
"@
        Set-Content -Path $titleCfgPath -Value $titleCfgContent -Encoding UTF8

        # Copy POPSTARTER.ELF
        $elfDestPath = Join-Path $appsFolderPath "$($psx.FileName).ELF"
        Copy-Item -Path $POPSTARTER_PATH -Destination $elfDestPath -Force

        Write-Host "  Created APPS folder: $($psx.FileName)"
    }
    else {
        # Write-Host "  [DEBUG] APPS folder already exists for: $($psx.FileName), skipping."
    }
}

# === Phase 2 - (Optional) Populate ART files
Write-Host "Populating ART files..."
if ($ART_ZIP_EXISTS) {
    Write-Host "Scanning ART zip file..."
    # List all zip files in ART zip relating to all PS2 and PS1 games
    $art_zip_prefixes = $all_ps2_data | ForEach-Object { "PS2/$($_.TitleId)/" }
    $art_zip_prefixes += $all_psx_data | ForEach-Object { "PS1/$($_.TitleId)/" }
    $art_zip_paths = Get-ZipPaths -ZipPath $ART_ZIP_PATH -Prefixes $art_zip_prefixes

    # Collect all PS2 and PS1 game title IDs into common array
    $all_title_data = @()
    $all_title_data += $all_ps2_data | ForEach-Object { [PSCustomObject]@{
            TitleId           = $_.TitleId
            ArtDestFilePrefix = "$($_.TitleId)"
        } }
    $all_title_data += $all_psx_data | ForEach-Object { [PSCustomObject]@{
            TitleId           = $_.TitleId
            ArtDestFilePrefix = "$($_.FileName).ELF"    # @NOTE Bug in OPL. File extension ".ELF" is considered part of the APP ART file name e.g. "SCES_015.64.Ape Escape.ELF_BG.png"
        } }

    # Pick out art files from the list for each game
    $art_to_extract = @()
    foreach ($titleData in $all_title_data) {
        foreach ($artType in $ART_FILE_TYPES) {
            # Check if this art type for this game has any existing art
            $existing_art_of_type = $existing_art_files | Where-Object { $_ -like "$($titleData.ArtDestFilePrefix)_${artType}.*" -or $_ -like "$($titleData.ArtDestFilePrefix)_${artType}_*" }
            # Only extract new files if no existing files
            if ($existing_art_of_type.Count -eq 0) {
                # SCR can extract up to 2 files
                $num_arts = ($artType -eq "SCR" ? 2 : 1)
                # Pick a random art file of type
                $art_paths = @(Get-RandomArtPath -ArtPaths $art_zip_paths -TitleId $titleData.TitleId -ArtType $artType -Count $num_arts)

                # Write-Host "  [DEBUG] ($($titleData.TitleId)_${artType}) Matching art $($art_paths.Count) paths: $($art_paths -join ', ')"

                # Collect chosen art paths (if exist in ART zip)
                for ($i = 0; $i -lt $art_paths.Count; $i++) {
                    $srcPath = $art_paths[$i]
                    # Write-Host "    [DEBUG] $($titleData.TitleId)_${artType}) Selected art path: $srcPath"
                    $ext = [System.IO.Path]::GetExtension($srcPath).TrimStart('.')
                    $destFileName = if ($i -eq 0) {
                        # Most files are like "SCES_015.64_BG.jpg"
                        "$($titleData.ArtDestFilePrefix)_${artType}.$ext"
                    }
                    else {
                        # Any art files that have more than 1 entry (i.e. just SCR)
                        # are called "SCES_015.64_SCR2.jpg" for subsequent files
                        "$($titleData.ArtDestFilePrefix)_${artType}$($i+1).$ext"
                    }

                    # Record art zip path + proper OPL name of art file
                    $art_to_extract += [PSCustomObject]@{
                        Src  = $srcPath
                        Dest = $destFileName
                    }
                }
            }
            else {
                # Write-Host "  [DEBUG] ART file(s) already exist for: $($titleId)_$($artType), skipping."
            }
        }
    }

    # Extract all art files to temp ART folder
    Write-Host "Extracting $($art_to_extract.Count) art file(s) from zip..."
    $tempArtPath = Join-Path $TEMP_ROOT "ART"
    if (-not (Test-Path $tempArtPath)) {
        New-Item -ItemType Directory -Path $tempArtPath -Force | Out-Null
    }
    $art_src_paths = $art_to_extract | ForEach-Object { $_.Src }
    Expand-ZipFiles -ZipPath $ART_ZIP_PATH -Entries $art_src_paths -Destination $tempArtPath

    # Rename extracted files to destination names
    Write-Host "Renaming art files to OPL format..."
    foreach ($art in $art_to_extract) {
        # Determine local file name e.g. `__temp\ART\SCES_015.64_BG_00.png`
        $srcFileName = [System.IO.Path]::GetFileName($art.Src)
        $srcFilePath = Join-Path $tempArtPath $srcFileName

        # Write-Host "  [DEBUG] Renaming '$srcFileName' to '$($art.Dest)'"

        if (Test-Path $srcFilePath) {
            Rename-Item -Path $srcFilePath -NewName $art.Dest -Force
        }
    }
}
else {
    Write-Host "No ART ZIP specified, skipping."
}

# === Phase 3 - Ensure PS2 games have memory card CFGs
Write-Host "Generating missing PS2 memory card CFG and VMC files..."
foreach ($ps2 in $all_ps2_data) {
    $vmc_file_name = "$($ps2.TitleId)_0.bin"
    $cfg_file_name = "$($ps2.TitleId).cfg"
    # @NOTE: Removed `Title=$($_.GameName)`
    # @TODO unsure how to get game name from partition
    $cfg_data = @"
CfgVersion=8
`$ConfigSource=1
`$VMC_0=$($ps2.TitleId)_0
"@

    # Check for existing CFG file
    $existing_cfg = $existing_cfg_files | Where-Object { $_ -eq $cfg_file_name }
    if ($existing_cfg.Count -eq 0) {
        # Create CFG file in temp folder
        $tempCfgPath = Join-Path $TEMP_ROOT "CFG"
        if (-not (Test-Path $tempCfgPath)) {
            New-Item -ItemType Directory -Path $tempCfgPath -Force | Out-Null
        }
        $cfgFilePath = Join-Path $tempCfgPath $cfg_file_name
        Set-Content -Path $cfgFilePath -Value $cfg_data -Encoding UTF8
        Write-Host "  Created CFG file: $cfg_file_name"
    }
    else {
        # Write-Host "  [DEBUG] CFG file already exists for: $cfg_file_name, skipping."
    }

    # Check for existing VMC file
    $existing_vmc = $existing_vmc_files | Where-Object { $_ -eq $vmc_file_name }
    if ($existing_vmc.Count -eq 0) {
        # Copy blank memory card file to temp VMC folder
        $tempVmcPath = Join-Path $TEMP_ROOT "VMC"
        if (-not (Test-Path $tempVmcPath)) {
            New-Item -ItemType Directory -Path $tempVmcPath -Force | Out-Null
        }
        $vmcFilePath = Join-Path $tempVmcPath $vmc_file_name
        Copy-Item -Path $BLANK_MEMORY_CARD_PATH -Destination $vmcFilePath -Force
        Write-Host "  Created VMC file: $vmc_file_name"
    }
    else {
        # Write-Host "  [DEBUG] VMC file already exists for: $vmc_file_name, skipping."
    }
}

# === Phase 4 - Copy temp folders to OPL partition
Write-Host "Copying generated files to OPL partition..."
if (Test-Path $TEMP_ROOT ) {
    Copy-ToPfsRecursive -Partition $OPL_PARTITION -SourcePath $TEMP_ROOT -DestPath "/"
}

# === Cleanup
Write-Host "Cleaning up temporary files..."
if (Test-Path $TEMP_ROOT) {
    Remove-Item -Path $TEMP_ROOT -Recurse -Force
}

Write-Host "Done!"

