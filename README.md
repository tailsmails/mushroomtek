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

## WLAN GhostMe (Wi-Fi Anti-Triangulation)

Cellular anonymity is fundamentally incomplete if the device's Wi-Fi radio continues to broadcast high-power, easily triangulated telemetry. To address this, Mushroomtek includes an independent active Wi-Fi protection module named **WLAN GhostMe** that operates directly on the MediaTek WLAN driver via `procfs`.

Rather than running a passive monitor, WLAN GhostMe reconfigures the radio to prevent physical tracking and spatial triangulation while keeping your connection completely online and usable.

### WLAN GhostMe Mechanics

* **Tx Power Suppression (CTIA Mode):** Artificially restricts the transmission radius to the absolute minimum. This ensures the signal only reaches the immediate access point, dropping below the noise floor for secondary tracking sensors and rendering multi-node spatial triangulation mathematically impossible.
* **Spatial Stream Limiting (SISO):** Disables secondary antennas (`Nss=1`) to suppress multipath propagation signatures actively used by Angle of Arrival (AoA) hardware tracking systems.
* **CSI & Beamforming Suppression:** Disables spatial feedback matrices (`StaVHTBfee`, `StaHEBfee`). This forces the radio into isotropic transmission, blinding router-side physical positioning that relies on Channel State Information.
* **Temporal Masking:** Disrupts Target Wake Time (`TWTRequester`) scheduling in Wi-Fi 6 to prevent device tracking via microsecond-level temporal fingerprinting.
* **P2P Leak Prevention:** Disables Wi-Fi Direct background beacons that broadcast MAC addresses even when the device is seemingly disconnected.

### WLAN GhostMe Execution

The GhostMe module operates entirely independently from the cellular hopper. It features a fail-safe execution flow that validates driver support, safely handles hex-to-decimal conversions, and strictly manages non-destructive state backups.

```bash
# Apply the GhostMe profile (automatically creates a fail-safe backup)
su -c ./mushroomtek wlan apply

# Check the current status of the targeted driver parameters
su -c ./mushroomtek wlan status

# Restore the original hardware configuration from the backup
su -c ./mushroomtek wlan restore
```

*(Note: The `apply` command will refuse to overwrite an existing backup to ensure your original factory default state is never lost. All WLAN GhostMe changes are volatile and will revert automatically upon a Wi-Fi toggle or device reboot.)*

## Development Story: Fighting JNI and Finding a Way Around It

Getting the WLAN GhostMe module to actually work was a massive headache. We spent a lot of time reverse-engineering MediaTek's closed-source JNI libraries, hitting brick walls, and crashing the terminal before finding a clean, zero-dependency bypass.

### Why the Native JNI Approach Failed

At first, we wanted to call the proprietary Wi-Fi tuning functions directly from MediaTek's Engineering Mode library (`libem_wifi_jni.so`). To achieve this, we attempted to use [oscall](https://github.com/tailsmails/oscall), a native execution tool compiled in V that resolves ELF symbols and lets you call C++ functions directly from the shell. 

That turned out to be a dead end for a few reasons:

* **JVM Dependency Aborts:** Loading `libem_wifi_jni.so` dynamically pulls in `libandroid_runtime.so`. The static initializers in the Android runtime expect to find a running Java Virtual Machine (Zygote context). Running this from a raw shell without a JVM environment meant the linker immediately failed with a SIGABRT, crashing the process.
* **Hollow C++ Classes:** Even if we managed to isolate the symbols, calling class methods like `GetATParam` requires a valid `this` pointer. Mocking a C++ object with a blank 512-byte heap buffer caused instant segmentation faults (SIGSEGV). The compiled code tried to read uninitialized internal variables, like the socket descriptor (`m_i4Fd`) or the adapter pointer (`m_pAdapter`), and immediately dereferenced garbage.
* **Vendor Stubs (The "Omitted" Trick):** When we dumped the JNI string literals, we found that MediaTek had compiled out the actual power-writing logic in user-space anyway. Functions like `setOutputPower` and `setTXMaxPowerToEEProm` were just hollow stubs that printed debug strings like `setOutputPower:omitted` and returned `0` without taking any action.

### Bypassing User-Space Entirely

Instead of wasting weeks trying to build a mock Java runtime environment from a raw shell, we hooked `strace` to the process and looked at the system calls. We saw the JNI library sending private IOCTLs (SIOCDEVPRIVATE + 2) to the active kernel Wi-Fi driver.

This pointed us straight to `/proc/net/wlan/`, which was a goldmine of active, writable procfs nodes. 

By writing directly to `/proc/net/wlan/cfg` and `/proc/net/wlan/mcr`:

* We bypassed the JNI user-space library entirely, getting **100% crash-free, zero-dependency execution**.
* We bypassed the dummy "omitted" JNI APIs, gaining direct control over the physical transmit registers and spatial streams in normal Station Mode.
* We handled a small driver-side quirk: the wlan driver reports values in hex (e.g., `0x0`) but only accepts decimal (e.g., `0`) when writing. We wrote a quick POSIX shell converter inside our backup-and-restore routine to make the restore process foolproof.

## Disclaimer

This tool is strictly for educational, privacy research, and personal defensive purposes.

## License

![License: EUPL 1.2](https://img.shields.io/badge/License-EUPL%201.2-gray.svg)
