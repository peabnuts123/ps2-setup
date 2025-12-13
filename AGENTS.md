# PS2 HDD Setup Automation

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

