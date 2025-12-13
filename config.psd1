@{
    # Device name of connected PS2 HDD (e.g. "\\.\PHYSICALDRIVE5")
    # Can be identified by running `Get-CimInstance -ClassName Win32_DiskDrive`
    Ps2Device       = ""
    # Name of OPL partition (default: "+OPL")
    OplPartition    = "+OPL"
    # Name of common partition where POPS.ELF lives (default: "__common")
    CommonPartition = "__common"
    # Name of partition where POPStarter reads .VCD files (default: "__.POPS")
    PopsPartition   = "__.POPS"

    # (Optional) Path to OPL Manager Art DB backup
    # List of backups found here: https://oplmanager.com/site/?backups
    # Example: https://archive.org/details/OPLM_ART_2024_09
    ArtZipPath     = ""
}