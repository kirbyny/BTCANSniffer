# BTCAN Sniffer

A Flutter app for sniffing, visualizing, and reverse-engineering CAN bus
traffic on Android and iOS. Talks to OBD-II adapters (ELM327) and raw CAN
dongles (slcan) over **BLE**, **Classic SPP**, **WiFi**, or **USB serial**.

Built around two ideas:

1. **Make the bus inspectable.** Live per-ID frames, a pinch-zoomable matrix
   overview of every observed bit, and per-byte rolling graphs for finding
   slow-varying physical signals (coolant temp, RPM, speed).
2. **Make the work re-usable.** Saved signals (bit and byte) with scale /
   offset / unit / endianness export to a **CSV** or a real Vector-style
   **DBC** that opens directly in cantools, CANdb++, and SavvyCAN.

---

## Features

### Transports
| Transport | Platforms | Notes |
|---|---|---|
| BLE GATT | Android, iOS | Tries Vgate (`FFF0/FFF1/FFF2`), HM-10 (`FFE0/FFE1`), Nordic UART UUID sets. |
| Classic SPP (RFCOMM) | Android | iOS forbids non-MFi SPP. Pair the dongle in Android Bluetooth settings first. |
| WiFi (TCP) | Android, iOS, desktop | Default target `192.168.0.10:35000`; configurable. Set TCP_NODELAY so ELM prompts don't get Nagled. |
| USB serial (OTG) | Android | FTDI / CP210x / PL2303 / CH340 chipsets; defaults to 38400-8N1. Plug-in auto-prompts via `usb_device_filter.xml`. |

### Protocol families
| Family | What it does | When to use |
|---|---|---|
| **ELM327** | AT command set + `ATMA` monitor mode. Optional `0100` probe to activate the bus on stubborn gateways. | OBD-II diagnostic adapters (VLinker MC, Veepeak, BAFX, generic v1.5 clones). |
| **slcan** | Lawicel ASCII CAN protocol. Sends only `C`/`Sn`/`L` — **truly listen-only**, never transmits on the bus. | Real CAN sniffers (CANable, Innomaker, candleLight). The right choice on cars with a gateway that blocks OBD-II passthrough of raw frames. |

### Live visualization
- **Tile view** — one row per CAN ID with hex bytes, count, and last timestamp; bytes flash when they change.
- **Matrix view** — every observed ID rendered as a horizontal strip of 64 bit-lanes, drawn as a barcode of "high" intervals over the rolling 30s window. Pinch to zoom into a specific ID or byte block; pinch out to see every ID at once. Adaptive level-of-detail collapses to per-ID activity bars when lanes go subpixel.
- **Tape-transport controls** at the bottom: ▶ Start Monitor / ⏸ Pause, ⏺ Record to log, ⏹ Clear view.

### Per-ID explorer
Tap any row in the live view to open the explorer for that ID. Swipe left/right to move between IDs.

- **Bits mode** — 8 byte cards, each with 8 bit rows. Every bit gets a 30s step-function graph. Double-tap a bit → name and save it to the sniffer log.
- **Bytes mode** — one row per byte (or byte-group). Each row shows a 0–max normalized bar plus a 30s smooth-line graph of the byte's value, plus min/cur/max stats. **Combine right** (🔗) merges adjacent bytes into a multi-byte group; **split right** (✂) undoes it. **LE / BE** toggle on multi-byte groups. Double-tap a card → **Save signal** dialog with **live decoded preview** while you dial in scale, offset, unit, and signed/unsigned.

### Capture
- **Record to log** writes frames continuously to a `.log` file in app documents while monitoring, regardless of whether the viewer screen is open.
- **Capture browser** (menu → Capture logs) lists prior captures with size + timestamp; re-open them in an offline viewer with ID filter, or share / export them.

### Sniffer log
- Both bit and byte signals stored in one CSV (v2 schema: `timestamp,id,byte,length,byte_order,signed,bitmask,scale,offset,unit,name`). v1 files read fine; first append after upgrade auto-migrates.
- **Tap an entry** to edit name, scale, offset, unit, signedness, byte order. Delete from the same dialog.
- **Export…** (top right of the sniffer screen): rename the output file and choose **CSV** or **DBC**.
- **DBC writer** emits real Vector-style signals with correct bit-length, byte order, sign, scale, offset, and computed min/max range. Example:
  ```
  SG_ EngineCoolantTemp : 16|8@1+ (1.0,-40.0) [-40.0|215.0] "°C" Vector__XXX
  SG_ EngineRPM         : 32|16@1+ (0.25,0.0) [0.0|16383.75] "rpm" Vector__XXX
  ```

### Diagnostics
- Menu → Show diagnostics → panel under the controls shows byte counter + the last 30 raw lines from the dongle.
- Status messages also stream to logcat under tag `btcan.status` / `btcan.slcan` for `adb logcat -s btcan` debugging.

---

## Hardware compatibility

### ELM327 OBD-II adapters

| Adapter | Transport(s) | Status |
|---|---|---|
| VLinker MC+ / MC-V / FD | BLE | ✅ Confirmed |
| VLinker MC (original, Classic SPP) | SPP | ✅ Android only |
| Vgate iCar Pro | BLE | ✅ |
| Veepeak OBDCheck BLE / BLE+ | BLE | ✅ |
| ANCEL BD200 | BLE | ✅ |
| OBDLink LX | SPP | ✅ Android only |
| BAFX 34t5 | BLE or SPP variant | ✅ |
| Generic "ELM327 v1.5" Chinese clones | BLE (HM-10) or SPP | Usually works |
| WiFi OBD-II dongles (OBDII-WiFi, ESP-Link, etc.) | WiFi | Default `192.168.0.10:35000` |
| FTDI / CP210x / PL2303 / CH340 USB ELM dongles | USB OTG | Android only |

If a BLE dongle uses a service/characteristic UUID set we don't yet know,
add it to `_knownUuidSets` in
[flutter_app/lib/ble_transport.dart](flutter_app/lib/ble_transport.dart).

### slcan raw CAN sniffers

| Adapter | Transport | Notes |
|---|---|---|
| CANable v1 / v2 (slcan firmware) | USB serial | Android OTG |
| Innomaker USB2CAN (slcan mode) | USB serial | Android OTG |
| CANUSB (Lawicel) | USB serial | Android OTG |
| candleLight (slcan build) | USB serial | Android OTG |

These see frames the OBD-II gateway hides. Wire them to the CAN bus
directly (not via the OBD port) when the vehicle blocks raw passthrough.

### Platform matrix
| | Android | iOS | macOS | Windows | Linux |
|---|---|---|---|---|---|
| BLE | ✅ | ✅ | (not scaffolded) | (not scaffolded) | (not scaffolded) |
| SPP | ✅ | ❌ (Apple MFi) | — | — | — |
| WiFi | ✅ | ✅ | runnable, not scaffolded | runnable, not scaffolded | runnable, not scaffolded |
| USB serial | ✅ | ❌ (Apple) | — | — | — |

---

## Quick start

```bash
# Install Flutter (3.x stable, Dart 3.4+)
cd flutter_app
flutter pub get
flutter run                  # phone connected via adb
# or:
flutter build apk --release  # signed via android/key.properties → keystore
```

A `.keystore` and `key.properties` are not committed. To produce a Play
Store–signable APK, generate a keystore and a `flutter_app/android/key.properties`
that points to it — see
[flutter_app/android/app/build.gradle.kts](flutter_app/android/app/build.gradle.kts).
Without `key.properties`, release builds fall back to the debug key, which
is fine for sideloading but not for distribution.

## Connecting

1. **Menu (☰) → Connect**.
2. **Session settings card** at top of the scan screen:
   - **Family**: `ELM327` (default) or `slcan`.
   - **CAN format / bitrate**: 11- or 29-bit at 250 k / 500 k, J1939, or
     ELM auto-detect.
   - **0100 probe** (ELM only): on by default; required on most cars to wake
     the ELM bus interface — without it `ATMA` is silent.
3. **Pick a device** from the list below:
   - **Connect over WiFi…** is always at the top; opens a host:port dialog.
   - **USB** entries appear when an OTG-attached chip is recognized.
   - **SPP** entries are paired Classic devices (Android only).
   - **BLE** entries are live scan results.
   - Toggle **Show all** to lift the name-hint filter.

## Reverse-engineering a signal

1. Connect, hit ▶, watch the **Tile** view fill with IDs.
2. Suspect an ID (e.g. looking for coolant temperature, find one that updates every ~100 ms with one slowly-rising
   byte as vehicle warms up). Tap it. → **Explorer** opens.
3. Flip the top toggle to **Bytes**. The slow-rising byte's graph stands out
   immediately versus its neighbors.
4. Think it's a 2-byte value? Tap **🔗** to combine with the byte to the
   right; the sparkline replots at 16-bit scale. Flip **LE/BE** until the
   curve looks physical.
5. **Double-tap the card** → Save Signal. Type a name; type `-40` into
   Offset; watch the live preview snap from `122` to `82.0 °C`. Save.
6. Menu → Sniffer log. Your signal is there with a `BYTE` badge.
7. **Export…** → DBC. Drop the file into cantools / CANdb++ / SavvyCAN.

---

## Architecture overview

Two abstractions, four transports, two protocol drivers:

```
                       ┌──────────────────────────┐
                       │     ElmTransport         │   (lib/transport.dart)
                       └──────────────────────────┘
                          ▲      ▲       ▲      ▲
                          │      │       │      │
       ble_transport.dart─┘      │       │      └─usb_transport.dart
                spp_transport.dart       └─wifi_transport.dart

                       ┌──────────────────────────┐
                       │   CanProtocolDriver      │   (lib/vlinker.dart)
                       └──────────────────────────┘
                                ▲          ▲
                                │          │
              VlinkerConnection ┘          └ SlcanDriver
              (lib/vlinker.dart)            (lib/slcan_driver.dart)
```

The driver pulls bytes from the transport and yields `CanFrame`s; the UI
consumes the same frame stream regardless of family. Adding a new transport
or driver is a single file plus one line each in the scan screen and the
home-screen switch.

See [flutter_app/README.md](flutter_app/README.md) for the code map and
notes on extending each layer.

---

## Licensing note

This project depends on
[`flutter_blue_classic`](https://pub.dev/packages/flutter_blue_classic),
which is **GPL-3.0**. Distributing a binary build of this app means the
combined work must be GPL-3.0 or compatible. To relax that, swap
`flutter_blue_classic` for `bluetooth_classic` (MIT) or
`flutter_bluetooth_serial` (BSD-2-Clause) in
[flutter_app/lib/spp_transport.dart](flutter_app/lib/spp_transport.dart).
