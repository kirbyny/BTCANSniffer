# BTCAN Viewer

Flutter app that connects to a **VLinker MC** (or other ELM327-based OBD-II
adapter) over either **Bluetooth Low Energy** or **Bluetooth Classic SPP** and
displays live CAN bus traffic in read-only mode.

## Features

- Unified device picker that lists nearby BLE adapters *and* paired Classic
  SPP adapters on Android, with a badge so you know which transport you're
  picking.
- Auto-detects VLinker / OBD-II / ELM327 / iCar / OBDII name patterns; toggle
  "Show all" to see other Bluetooth devices.
- BLE: tries multiple known service/characteristic UUID sets (Vgate
  `FFF0/FFF1/FFF2`, HM-10 `FFE0/FFE1`, Nordic UART).
- Selectable CAN format / bitrate:
  - ISO 15765-4 CAN 11-bit @ 500 kbps
  - ISO 15765-4 CAN 29-bit @ 500 kbps
  - ISO 15765-4 CAN 11-bit @ 250 kbps
  - ISO 15765-4 CAN 29-bit @ 250 kbps
  - SAE J1939 29-bit @ 250 kbps
  - ELM327 auto-detect
- Live per-ID view that highlights changed bytes between updates.
- Capture-to-file: writes a `.log` to the app documents directory while
  running; works whether or not the live view is being watched.
- Log browser: re-open prior captures, filter by ID, share the raw `.log`, or
  export as `.csv` via the system share sheet.
- Read-only — the app never writes frames onto the CAN bus.

## Architecture

The protocol layer is transport-agnostic. [lib/vlinker.dart](lib/vlinker.dart)
talks ELM327 (AT commands + `ATMA` monitor mode) to an `ElmTransport`, and
two implementations of that interface ship with the app:

| File | Transport | Platforms |
|---|---|---|
| [lib/ble_transport.dart](lib/ble_transport.dart) | BLE GATT via `flutter_blue_plus` | Android, iOS |
| [lib/spp_transport.dart](lib/spp_transport.dart) | Classic SPP (RFCOMM) via `flutter_blue_classic` | **Android only** |

After connecting, the app runs the standard ELM327 init sequence:

```
ATZ        reset
ATE0       echo off
ATL0       linefeeds off
ATS0       spaces off (compact output)
ATH1       headers on (so we receive CAN IDs)
ATCAF0     CAN auto-format off (raw frames, not ISO-TP)
ATAL       allow long messages
ATSP <n>   set protocol (6 / 7 / 8 / 9 / A / 0)
```

`ATMA` (monitor all) then streams hex frames continuously until the app sends
any byte to stop monitoring.

## Run

1. Install the Flutter SDK (Dart 3.4+).
2. `cd flutter_app && flutter pub get`
3. Power on the VLinker so it advertises (BLE) or is paired (Classic).
4. `flutter run` on a connected phone (Android or iOS).
5. Tap the Bluetooth icon, pick your VLinker, choose a CAN format, then
   **Start Monitor**.

### Pairing a Classic-SPP VLinker (Android)

Classic adapters must be paired in **Settings → Bluetooth** before the app
can connect to them. The default PIN for most Vgate dongles is `1234`. Once
paired, they appear in the picker with an **SPP** badge — typically near the
top of the list since they're already bonded.

## Permissions

- **Android 12+**: `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`. The `SCAN`
  permission deliberately does **not** declare `neverForLocation`, because
  Classic device discovery infers location and the flag would suppress those
  results.
- **Android ≤ 11**: legacy `BLUETOOTH` + `BLUETOOTH_ADMIN` +
  `ACCESS_FINE_LOCATION` (already in the manifest).
- **iOS**: Bluetooth usage descriptions in `Info.plist`. iOS supports BLE
  adapters only; see below.

## VLinker hardware support

| Model | BLE | Classic SPP | Status |
|---|---|---|---|
| VLinker MC+ / MC-V / FD | ✅ | — | Works on Android **and** iOS via BLE |
| VLinker MC (Classic only) | — | ✅ | Works on **Android only** |
| Generic ELM327 BLE dongle | ✅ | — | Usually works; may need a new UUID set |
| Generic ELM327 SPP dongle | — | ✅ | Usually works (Android only) |

**iOS Classic SPP is not possible.** Apple requires MFi (Made for iPhone)
certification + the External Accessory framework to open RFCOMM sockets, and
Vgate does not ship MFi-certified VLinker MC hardware. If your adapter is
Classic-only and you need iOS support, you need a different adapter (MC+,
MC-V, or FD).

## Adding a new BLE UUID set

If your dongle uses a service/characteristic UUID set we don't know about,
add it to `_knownUuidSets` in [lib/ble_transport.dart](lib/ble_transport.dart).

## Third-party licenses

This app depends on
[`flutter_blue_classic`](https://pub.dev/packages/flutter_blue_classic),
which is licensed under **GPL-3.0**. If you redistribute this app, the
combined work must also be licensed under GPL-3.0 (or a compatible license).
Replace it with `bluetooth_classic` (MIT) or `flutter_bluetooth_serial`
(BSD-2-Clause) by editing [lib/spp_transport.dart](lib/spp_transport.dart) if
you need a more permissive license.
