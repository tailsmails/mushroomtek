# MushroomTek

Network stealth utility for MediaTek chipsets. Sends low-level AT commands to the modem to block carrier-side location triangulation, lock onto specific cells, and silence radio telemetry.

## What It Does

**Anti-Triangulation** -- Disables Neighbor Cell Measurement Reports via `ESBP=1,6,0`. The modem stops feeding surrounding tower signal data back to the carrier, breaking multi-tower trilateration.

**Cell/Band Locking** -- Forces the modem onto specific EARFCNs and blocks forced handovers to monitored or congested cells.

**Modem Silence** -- Suppresses unsolicited report codes (`CURC=0`) to reduce the radio's software footprint on the network side.

**Automated Rotation** -- Randomized cell lock cycling to mimic natural movement patterns and avoid automated network anomaly detection.

## Build

```
pkg update
pkg install git clang make

git clone https://github.com/vlang/v
cd v && make && ./v symlink && cd ..

v -prod mushroomtek.v -o mushroomtek
```

## Run

```
su -c ./mushroomtek
```

Enter target EARFCNs when prompted (e.g. `1850,1300`). Runtime commands:

- `next` -- skip current timer cycle
- `>EARFCN` -- immediate manual cell override
- `+` / `-` -- add or remove EARFCNs from whitelist

## Emergency Restore

`Ctrl+C` triggers automatic cleanup: restores default band masks, re-enables neighbor reports, unlocks cell/frequency, returns modem to standard mode.

## Disclaimer

Educational and personal privacy research only.

## License
![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)
