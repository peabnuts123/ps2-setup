# PS2 HDD Setup Automation

## Goal

We are automating the setup of a PlayStation 2 hard drive for use with Open PS2 Loader (OPL) homebrew. This involves copying game files, apps, artwork, and config files to a PFS-formatted partition on the HDD.

## Architecture

We use `pfsshell.exe` to interact with the PS2 HDD's PFS filesystem from Windows. pfsshell is interacted by generating a list of commands and then piping them into the pfsshell executable.

## pfsshell Command Reference

```
lcd [path] - print/change the local working directory
device <device> - use this PS2 HDD;
initialize - blank and create APA/PFS on a new PS2 HDD (destructive);
mkpart <part_name> <size> <fstype> - create a new PFS formatted partition;
        Size must end with M or G literal (like 384M or 3G);
        Acceptable fs types: {PFS, CFS, HDL, REISER, EXT2, EXT2SWAP, MBR};
        Only fs type PFS will format partition, other partitions should be formatted by another utilities;
mount <part_name> - mount a partition;
umount - un-mount a partition;
ls [-l] - no mount: list partitions; mount: list files/dirs; -l: verbose list;
rename <curr_name> <new_name> - no mount: rename partition; mount: rename a file/dir.
mkdir <dir_name> - create a new directory;
rmdir <dir_name> - delete an existing empty directory;
pwd - print current PS2 HDD directory;
cd <dir_name> - change directory;
get <file_name> - copy file from PS2 HDD to current dir;
put <file_name> - copy file from current dir to PS2 HDD;
        file name must not contain a path;
rm <file_name> - delete a file;
rename <curr_name> <new_name> - rename a file/dir/partition.
rmpart <part_name> - remove partition (destructive).
df - no mount: display free space on the whole HDD; mount: display free space on partition.
exit/quit/bye - exits the program. (Do this before you unplug your HDD)
```

## pfsshell Gotchas & Limitations

### No recursive copy
`put` only copies single files. To copy a folder structure, you must:
1. Create all directories with `mkdir` (parents before children)
2. Copy each file individually with `put`

### No `mkdir -p`
`mkdir` only creates one level. Parent directories must already exist.
```
mkdir "APPS"                    # works
mkdir "APPS/MyGame"             # works if APPS exists
mkdir "APPS/MyGame/SubFolder"   # fails if APPS/MyGame doesn't exist
```

### Paths with spaces need quotes
```
mkdir "SCES_015.64.Ape Escape"
put "My Game/config.cfg"
```

### `put` accepts paths (if dirs exist)
Despite the docs saying "file name must not contain a path", you can use:
```
lcd "D:\PS2 BKP\APPS"
cd "/APPS"
put "MyGame/title.cfg"
```
This works as long as the destination directory exists.

### Error handling
pfsshell doesn't abort on errors (e.g., `mkdir` on existing dir). It prints an error and continues. This is useful for idempotent scripts.

### Piped input
Commands can be piped to pfsshell:
```powershell
$commands -join "`n" | pfsshell.exe
```
It still prints prompts and output as if interactive.

## Key Files

- `new_build/build.ps1` - Main automation script
- `new_build/pfsshell/pfsshell.exe` - The PFS filesystem tool

## Partition Layout

The main partition is `+OPL` which contains:
```
/APPS/     - Homebrew apps (ELF files + title.cfg)
/POPS/     - PS1 games (VCDs)
/ART/      - Cover art, icons, backgrounds
/CFG/      - Per-game OPL config files
/VMC/      - Virtual memory cards
/CHT/      - Cheats
/THM/      - Themes
```
