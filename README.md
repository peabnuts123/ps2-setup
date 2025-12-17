# PS2 Setup

A script I wrote out of necessity to create and set up all the files necessary to play PS2 and PSX backups in OPL.

Better documentation to come.

## One-time initial setup
  - Make partition called `__.POPS`
    - Use HDDMANAGER in LaunchElf to create partitions easily
  - Put POPS.ELF and IOPRP252.IMG into `__common:/POPS/`
    - Place in `__copy/__common/POPS` to easily transfer
  - Copy OPL themes in to `+OPL:/THM`
    - Place in `__copy/OPL/THM` to easily transfer

## Adding games (manual steps by user)
- PS2 games: Install with HDL-Batch-installer or whatever
- PS1 games: Place VCD files in `__copy/POPS`
