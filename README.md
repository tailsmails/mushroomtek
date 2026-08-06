<div align="center">
  <img src="im_a_tree.jpg" alt="I'm a tree" width="400" />
</div>

# Mushroomtek

An open-source, terminal-based SnoopSnitch alternative for MediaTek chipsets. It operates as a network stealth utility, sending low-level AT commands directly to the modem to block carrier-side location triangulation, lock onto trusted cells, and suppress radio telemetry.

While SnoopSnitch is designed for Qualcomm-based diagnostics, Mushroomtek brings active cellular defense and anomaly-checking to MediaTek-based Android devices.

> Note: While developed for MediaTek platforms, this utility might function on non-MediaTek modems that expose an AT command interface. Test on other hardware at your own risk.

## Active Defense: Prevention Over Detection

Traditional cellular monitors operate as passive Intrusion Detection Systems (IDS). They analyze traffic and alert you after a potential anomaly or IMSI-catcher interaction has occurred. At that point, the exposure has already happened. 

Mushroomtek operates on the principle that prevention is fundamentally superior to detection. It takes an active mitigation approach by continuously reconfiguring the modem's state to block tracking vectors, suppress neighbor reporting, and prevent forced handovers before network-side triangulation can be initiated.

## Core Mechanics

* **Anti-Triangulation:** Disables Neighbor Cell Measurement Reports via AT+ESBP=1,6,0. The modem stops broadcasting surrounding tower signal data back to the carrier, effectively breaking multi-tower trilateration.
* **Cell and Band Locking:** Forces the modem onto specific EARFCNs and blocks forced handovers to monitored or congested cells.
* **Modem Silence:** Suppresses unsolicited report codes (CURC=0) to minimize the radio footprint on the network side.
* **Automated Rotation:** Randomized cell lock cycling to mimic natural movement patterns and avoid automated network anomaly detection.
* **Dynamic Verification:** Integrates with BeaconDB (an open-source Mozilla Location Service replacement) to verify connected cell tower IDs against public databases, identifying potential rogue base stations without relying on API keys.

## Prerequisites

* Root access (Magisk, KernelSU, APatch, etc.)
* Terminal emulator (e.g., Termux) or ADB Shell

## Build

```bash
pkg update
pkg install git clang make

git clone https://github.com/vlang/v
cd v && make && ./v symlink && cd ..

v -prod mushroomtek.v -o mushroomtek
```

## Execution

Run the compiled binary with root privileges:

```bash
su -c ./mushroomtek
```

Enter target EARFCNs when prompted (e.g., 1850,1300).

### Runtime Commands

* `next` : Skip current timer cycle
* `status` : Get current modem status
* `trust` : Show trust score of the current cell tower
* `neighbors` : Show neighbor cell towers
* `scan` : Scan SIM card status
* `history` : Show history of verified towers
* `lte` : Lock to LTE-only mode
* `list` : Show a list of the EARFCN whitelist
* `>EARFCN` : Immediate manual cell override
* `+` / `-` : Add or remove EARFCNs from the whitelist
* `!` / `!!` : Blacklist or unblacklist cell IDs
* `~CID` : Lock to a custom CID (type `~` without a number to allow connection to any CID)
* `at` : Send a custom AT command directly to the modem

**WARNING:** Executing arbitrary AT commands can permanently damage radio partitions. Ensure you have a full backup of NVRAM and NVDATA before using the `at` command.

## Emergency Restore

Sending a SIGINT (Ctrl+C) triggers an automatic cleanup sequence. This restores default band masks, re-enables neighbor reports, removes cell/frequency locks, and returns the modem to standard automatic mode.

## Disclaimer

This tool is strictly for educational, privacy research, and personal defensive purposes.

## License

![License: EUPL 1.2](https://img.shields.io/badge/License-EUPL%201.2-gray.svg)
