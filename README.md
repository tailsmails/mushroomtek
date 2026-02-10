![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)
# 🍄 MushroomTek (MTK Network Stealth Utility)

**MushroomTek** is a network privacy and modem manipulation tool specifically designed for **MediaTek (MTK)** chipsets. It leverages low-level AT commands to enforce cellular privacy, prevent carrier-side triangulation, and optimize LTE connectivity in high-interference environments.

## Key Features

*   **Anti-Triangulation:** Disables Neighbor Cell Measurement Reports (`ESBP=1,6,0`), making it significantly harder for the carrier to pinpoint your location via multi-tower trilateration.
*   **Cell/Band Locking:** Forces the modem to stay on specific EARFCNs (LTE Band 3) and prevents forced handovers to monitored or congested cells.
*   **Modem Silence:** Suppresses unsolicited report codes (`CURC=0`) to reduce the radio's software footprint.
*   **Automated Rotation:** Implements a randomized loop for cell locking to mimic human behavior and evade automated network "flagging."

## Compilation

```bash
# 1. Install Dependencies
pkg update
pkg install git clang make

# 2. Compile V Language (from official source)
git clone https://github.com/vlang/v
cd v
make
./v symlink
cd ..

# 3. Compile mushroomtek
v -prod mushroomtek.v -o mushroomtek
```

## Usage

1. **Run with Root Privileges:**
   ```bash
   su -c ./mushroomtek
   ```
2. **Configuration:**
   - Enter your target EARFCNs (e.g., `1850,1300`).
   - Use `next` to skip the current timer.
   - Use `>EARFCN` for immediate manual override.
   - Use `+` or `-` to dynamically manage your whitelist.

## Safety & Emergency Exit

The tool includes an **Emergency Restoration** feature. Press `Ctrl+C` to terminate. The script will automatically:
*   Restore default band masks.
*   Re-enable neighbor reports.
*   Unlock the cell/frequency lock.
*   Return the modem to standard operational mode.

## Disclaimer

This tool is for educational and personal privacy research only. Use responsibly and in accordance with local regulations.
