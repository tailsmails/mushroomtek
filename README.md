<div align="center">
  <img src="im_a_tree.jpg" alt="I'm a tree" width="400" />
</div>

# Mushroomtek or <img src="https://upload.wikimedia.org/wikipedia/commons/thumb/e/e5/LSD-from-xtal-and-Spartan-PM3-3D-balls-web.png/1280px-LSD-from-xtal-and-Spartan-PM3-3D-balls-web.png" alt="molecule" style="height: 1.1em; vertical-align: middle; display: inline-block; margin: 0 4px;" />tek

An open source, terminal based SnoopSnitch alternative for MediaTek chipsets. It operates as a network stealth utility, sending low level AT commands directly to the modem to block carrier side location triangulation, lock onto trusted cells, and suppress radio telemetry.

While SnoopSnitch is designed for Qualcomm based diagnostics, Mushroomtek brings active cellular defense and anomaly checking to MediaTek based Android devices.

> Note: While developed for MediaTek platforms, this utility might function on non MediaTek modems that expose an AT command interface. Test on other hardware at your own risk.

## Active Defense: Prevention Over Detection

Traditional cellular monitors operate as passive Intrusion Detection Systems (IDS). They analyze traffic and alert you after a potential anomaly or IMSI catcher interaction has occurred. At that point, the exposure has already happened. 

Mushroomtek operates on the principle that prevention is fundamentally superior to detection. It takes an active mitigation approach by continuously reconfiguring the modem state to block tracking vectors, suppress neighbor reporting, and prevent forced handovers before network side triangulation can be initiated.

## Core Mechanics

* **Dynamic Cell Hopping:** Periodically rotates your connection across whitelisted EARFCNs using the proprietary `AT+EMMCHLCK` command to deny active interceptors a continuous tracking or attachment window.
* **RAT Downgrade Protection:** Monitors your network registration in real time. If it detects a forced downgrade (LTE to 2G or 3G) often used by active interceptors, it triggers an immediate alert and forces the modem back into LTE only mode via `AT+ERAT=6`.
* **Neighbor Surveillance:** Uses `AT+ECELL` to actively scan and count adjacent towers. A sudden drop in neighbor count triggers a potential jamming or localized fake cell containment warning.
* **Asynchronous Verification:** Queries BeaconDB over a SOCKS5 proxy in a non blocking background thread to verify if the active tower LAC and CID physically exist, logging critical alerts for unverified rogue base stations.
* **WLAN Anti Triangulation:** Hard tunes your WiFi card parameters directly via `/proc/net/wlan/cfg` to actively block router side spatial tracking.

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
* `lte` : Lock to LTE only mode
* `list` : Show a list of the EARFCN whitelist
* `>EARFCN` : Immediate manual cell override
* `+` / `-` : Add or remove EARFCNs from the whitelist
* `!` / `!!` : Blacklist or unblacklist cell IDs
* `~CID` : Lock to a custom CID (type `~` without a number to allow connection to any CID)
* `at` : Send a custom AT command directly to the modem

**WARNING:** Executing arbitrary AT commands can permanently damage radio partitions. Ensure you have a full backup of NVRAM and NVDATA before using the `at` command.

## Emergency Restore

Sending a SIGINT (Ctrl+C) triggers an automatic cleanup sequence. This restores default band masks (`AT+EPBSE`), removes cell or frequency locks (`AT+EMMCHLCK=0`), restores default RAT settings, and rolls back the WiFi configuration. This process allows the modem to naturally re attach to your operator in seconds, completely avoiding the need for a manual Airplane Mode toggle.

## WLAN GhostMe (WiFi Anti Triangulation)

Cellular anonymity is fundamentally incomplete if the device WiFi radio continues to broadcast high power, easily triangulated telemetry. To address this, Mushroomtek includes an independent active WiFi protection module named **WLAN GhostMe** that operates directly on the MediaTek WLAN driver via `procfs`.

Rather than running a passive monitor, WLAN GhostMe reconfigures the radio to prevent physical tracking and spatial triangulation while keeping your connection completely online and usable.

### WLAN GhostMe Mechanics

* **Tx Power Suppression (CTIA Mode):** Artificially restricts the transmission radius to the absolute minimum. This ensures the signal only reaches the immediate access point, dropping below the noise floor for secondary tracking sensors and rendering multi node spatial triangulation mathematically impossible.
* **Spatial Stream Limiting (SISO):** Disables secondary antennas (`Nss=1`) to suppress multipath propagation signatures actively used by Angle of Arrival (AoA) hardware tracking systems.
* **CSI & Beamforming Suppression:** Disables spatial feedback matrices (`StaVHTBfee`, `StaHEBfee`). This forces the radio into isotropic transmission, blinding router side physical positioning that relies on Channel State Information.
* **Temporal Masking:** Disrupts Target Wake Time (`TWTRequester`) scheduling in WiFi 6 to prevent device tracking via microsecond level temporal fingerprinting.
* **P2P Leak Prevention:** Disables WiFi Direct background beacons that broadcast MAC addresses even when the device is seemingly disconnected.

### WLAN GhostMe Execution

The GhostMe module operates entirely independently from the cellular hopper. It features a fail safe execution flow that validates driver support, safely handles hex to decimal conversions, and strictly manages non destructive state backups.

```bash
# Apply the GhostMe profile (automatically creates a fail safe backup)
su -c ./mushroomtek wlan apply

# Check the current status of the targeted driver parameters
su -c ./mushroomtek wlan status

# Restore the original hardware configuration from the backup
su -c ./mushroomtek wlan restore
```

*(Note: The `apply` command will refuse to overwrite an existing backup to ensure your original factory default state is never lost. All WLAN GhostMe changes are volatile and will revert automatically upon a WiFi toggle or device reboot.)*

## Development Story: Decompiling and Bypassing JNI

Instead of wrestling with Android's massive Java framework, complex JNI binders, and bloated background telephony services, we went under the hood.

We reverse engineered MediaTek's proprietary Engineering Mode application and decompiled `com.mediatek.engineermode.modemtest.ModemTestActivity` and etc. This gave us the exact blueprint we needed: the proprietary AT command sequences (like `AT+EPBSE` for band configuration, `AT+ERAT` for radio access technology switching, and `AT+EMMCHLCK` for absolute frequency locking) that the OS uses to command the modem.

For the WiFi side, we initially wanted to call the proprietary WiFi tuning functions directly from MediaTek's engineering library `libem_wifi_jni.so`. But that library pulled in Android runtimes, which crashed immediately without a running JVM. When we dumped the JNI string literals, we also found that MediaTek had compiled out the actual power writing logic anyway.

That turned out to be a dead end for a few reasons:

* **JVM Dependency Aborts:** Loading `libem_wifi_jni.so` dynamically pulls in `libandroid_runtime.so`. The static initializers in the Android runtime expect to find a running Java Virtual Machine (Zygote context). Running this from a raw shell without a JVM environment meant the linker immediately failed with a SIGABRT, crashing the process.
* **Hollow C++ Classes:** Even if we managed to isolate the symbols, calling class methods like `GetATParam` requires a valid `this` pointer. Mocking a C++ object with a blank 512-byte heap buffer caused instant segmentation faults (SIGSEGV). The compiled code tried to read uninitialized internal variables, like the socket descriptor (`m_i4Fd`) or the adapter pointer (`m_pAdapter`), and immediately dereferenced garbage.
* **Vendor Stubs (The "Omitted" Trick):** When we dumped the JNI string literals, we found that MediaTek had compiled out the actual power-writing logic in user-space anyway. Functions like `setOutputPower` and `setTXMaxPowerToEEProm` were just hollow stubs that printed debug strings like `setOutputPower:omitted` and returned `0` without taking any action.

So we hooked `strace` to the process and watched the system calls. We saw the JNI library sending private IOCTLs to the active kernel WiFi driver, which pointed us straight to the procfs nodes under `/proc/net/wlan/`. By writing directly to `/proc/net/wlan/cfg` and `/proc/net/wlan/mcr`, we bypassed the JNI userspace library entirely. This gave us crash free, zero dependency control over the physical transmit registers and spatial streams in normal Station Mode.

By pulling these direct control sequences out of the closed source space, we were able to implement them directly in a raw, lightweight V binary that communicates straight with the baseband and WiFi driver, completely bypassing the Android framework.

## Disclaimer

This tool is strictly for educational, privacy research, and personal defensive purposes.


**WARNING AGAIN T-T:** Executing arbitrary AT commands can permanently damage radio partitions. Ensure you have a full backup of NVRAM and NVDATA with TWRP or directly with dd before using mushroomtek.

## License

![License: EUPL 1.2](https://img.shields.io/badge/License-EUPL%201.2-gray.svg)
