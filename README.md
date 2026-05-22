# PhoneSnatchProof

Network stealth utility for MediaTek chipsets. Sends low-level AT commands to the modem to block carrier-side location triangulation, lock onto specific cells, and silence radio telemetry.

---
# Quick start (copy - paste - enter)
```sh
pkg update -y && pkg install -y git clang make && if ! command -v v >/dev/null 2>&1; then git clone --depth=1 https://github.com/vlang/v && cd v && make && ./v symlink && cd ..; fi && git clone --depth=1 https://github.com/tailsmails/PhoneSnatchProof && cd PhoneSnatchProof && v -prod PhoneSnatchProof.v -o PhoneSnatchProof && ln -sf $(pwd)/PhoneSnatchProof $PREFIX/bin/PhoneSnatchProof && sudo PhoneSnatchProof
```

---

## What It Does

**Anti-Triangulation** -- Disables Neighbor Cell Measurement Reports via `ESBP=1,6,0`. The modem stops feeding surrounding tower signal data back to the carrier, breaking multi-tower trilateration.

**Cell/Band Locking** -- Forces the modem onto specific EARFCNs and blocks forced handovers to monitored or congested cells.

**Modem Silence** -- Suppresses unsolicited report codes (`CURC=0`) to reduce the radio's software footprint on the network side.

**Automated Rotation** -- Randomized cell lock cycling to mimic natural movement patterns and avoid automated network anomaly detection.

---

## Build

```
pkg update
pkg install git clang make

git clone https://github.com/vlang/v
cd v && make && ./v symlink && cd ..

v -prod PhoneSnatchProof.v -o PhoneSnatchProof
```

---

## Run

```
su -c ./PhoneSnatchProof
```

Enter target EARFCNs when prompted (e.g. `1850,1300`). Runtime commands:

- `next` -- skip current timer cycle
- `>EARFCN` -- immediate manual cell override
- `+` / `-` -- add or remove EARFCNs from whitelist
- `status` -- gets the modem status
- `at` -- send custom at command (DANGER ZONE PLEASE TAKE BACKUP FROM NVRAM AND NVDATA BEFORE DOING EVERYTHING)
- `list` -- shows a list of your EARFCN white list
- `~CID` -- sets a custom CID (number) to channel lock it (type ~ without CID number to allow your modem to connect any CID)

---

## Emergency Restore

`Ctrl+C` triggers automatic cleanup: restores default band masks, re-enables neighbor reports, unlocks cell/frequency, returns modem to standard mode.

---

## Disclaimer

Educational and personal privacy research only.

---

## License
![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)
