# flutter_app — BTCAN Viewer

The Flutter client. For the user-facing overview, feature list, hardware
compatibility tables, and connection guide, see the
[repo README](../README.md). This document is a code map for working on
the app.

## Run / build

```bash
flutter pub get
flutter run                              # connected phone via adb
flutter build apk --debug                # sideloadable debug APK
flutter build apk --release \            # signed release
  --target-platform=android-arm64        # arm64 only keeps APK ~17 MB
```

`flutter analyze` should be clean. The widget test in
[test/widget_test.dart](test/widget_test.dart) smoke-tests the disconnected
home screen.

## Code layout

```
lib/
├── main.dart                     entry point + theme
├── home_screen.dart              hamburger menu, transport row, view toggle,
│                                 Tile vs Matrix swap, swipe into explorer
├── scan_screen.dart              session-settings card + WiFi quick-tile +
│                                 BLE/SPP/USB device list, returns ScanPick
├── transport.dart                ElmTransport interface +
│                                 sealed DiscoveredDevice variants
├── ble_transport.dart            flutter_blue_plus, three known UUID sets
├── spp_transport.dart            flutter_blue_classic (GPL-3.0)
├── wifi_transport.dart           dart:io Socket + tcpNoDelay
├── usb_transport.dart            usb_serial, 38400-8N1 default
├── vlinker.dart                  VlinkerConnection (ELM327) +
│                                 CanProtocolDriver interface + VlinkerState
├── slcan_driver.dart             SlcanDriver — listen-only `L`, no transmit
├── models.dart                   CanFrame, CanRowModel, CanProtocol,
│                                 ProtocolFamily
├── bit_matrix_view.dart          InteractiveViewer + custom-painted barcode
├── bit_explorer_screen.dart      PageView per-ID; Bits + Bytes modes;
│                                 BitTrace ChangeNotifier (30s window);
│                                 save-signal dialog with live preview
├── capture_log.dart              streaming .log writer in app docs
├── log_browser_screen.dart       lists prior captures, share / export CSV
├── log_viewer_screen.dart        offline replay of a capture, filter by ID
├── sniffer_log.dart              v2 CSV schema (back-compat v1 read);
│                                 DBC writer for byte + bit signals
└── sniffer_log_screen.dart       tap-to-edit, Export… (rename + CSV/DBC)
```

## Architecture

Two abstractions, kept deliberately thin:

1. **`ElmTransport`** ([lib/transport.dart](lib/transport.dart)) — a bytes-in /
   bytes-out pipe. Four implementations: BLE, SPP, WiFi, USB. The name is a
   legacy from when ELM327 was the only protocol; slcan reuses the same
   interface.
2. **`CanProtocolDriver`** ([lib/vlinker.dart](lib/vlinker.dart)) — takes an
   `ElmTransport`, yields a `Stream<CanFrame>`. Two implementations:
   `VlinkerConnection` (ELM327 AT + `ATMA`) and `SlcanDriver` (Lawicel ASCII,
   `L` listen-only).

The UI consumes the driver via the abstract interface, so adding a new
protocol family is one file plus one switch case in
[home_screen.dart](lib/home_screen.dart).

## Adding a transport

1. Implement `ElmTransport` (open / send / incoming / onDisconnected / close).
2. Add a `*DiscoveredDevice` subclass in [transport.dart](lib/transport.dart)
   to the sealed hierarchy.
3. Add an enumeration step in [scan_screen.dart](lib/scan_screen.dart)
   (`_load*Devices` for hardware discovery, or a static tile + dialog for
   user-entered configs like WiFi).
4. Add a `switch` arm in `_scanAndConnect` in
   [home_screen.dart](lib/home_screen.dart).
5. Update [_DeviceTile](lib/scan_screen.dart) to render the new badge.

## Adding a protocol driver

1. Implement `CanProtocolDriver` (frames / state / connect / startMonitor /
   stopMonitor / setProtocol / dispose).
2. Add a `ProtocolFamily` enum entry in [models.dart](lib/models.dart).
3. Add a `ButtonSegment` to the family chooser in `_settingsCard` of
   [scan_screen.dart](lib/scan_screen.dart).
4. In `_scanAndConnect` of [home_screen.dart](lib/home_screen.dart), extend
   the family check so the home screen swaps to the new driver on family
   change.

## Sniffer-log file format (v2)

`<app docs>/sniffer.csv`:

```
timestamp_iso,can_id_hex,byte_index,length,byte_order,signed,bitmask_hex,scale,offset,unit,signal_name
2026-08-01T12:00:00Z,7E8,2,1,le,0,0x00,1.0,-40.0,°C,EngineCoolantTemp
2026-08-01T12:00:01Z,7E0,3,0,le,0,0x04,1.0,0.0,,BrakePressed
```

- `length == 0` → bit signal, identified by `bitmask` over `byte_index`.
- `length > 0` → byte signal at `byte_index` of `length` bytes, with
  `byte_order` (`le`/`be`), `signed` (`0`/`1`), and linear decode
  `value = raw × scale + offset` in `unit`.
- v1 files (5 fields) read fine; the first append after upgrade rewrites
  the file in v2 layout.

## Capture-log file format

`<app docs>/captures/capture_<label>_<stamp>.log`:

```
# BTCAN Sniffer log v1
# columns: timestamp_ms,id_hex,id_decimal,extended,dlc,b0,b1,b2,b3,b4,b5,b6,b7
1738423459123,7E8,2024,0,8,06,41,00,BE,7F,B8,13,00
```

Streamed line-by-line during a recording; replayed by
[log_viewer_screen.dart](lib/log_viewer_screen.dart).

## Release signing

`build.gradle.kts` reads `android/key.properties` to sign release builds. The
file is gitignored. With no `key.properties`, release falls back to the debug
key (sideloadable, not Play-Store eligible). See the
[repo README](../README.md#quick-start) for keystore generation.

## Permissions

| Platform | Permission | Why |
|---|---|---|
| Android 12+ | `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT` | BLE + Classic discovery. `neverForLocation` is **not** set — Classic discovery infers location. |
| Android ≤ 11 | `BLUETOOTH`, `BLUETOOTH_ADMIN`, `ACCESS_FINE_LOCATION` | Legacy Bluetooth + discovery. |
| Android (any) | `USB_DEVICE_ATTACHED` intent filter + `usb_device_filter.xml` | Auto-foreground when a known FTDI/CP210x/PL2303/CH340 chip is plugged in. |
| iOS | `NSBluetoothAlwaysUsageDescription`, `NSBluetoothPeripheralUsageDescription` | BLE. |
| iOS | `NSLocalNetworkUsageDescription` | WiFi adapters on the local network. |

## Third-party licenses

- `flutter_blue_plus` — BSD-3-Clause
- `flutter_blue_classic` — **GPL-3.0** (drives the SPP transport; binary
  distribution requires GPL-3.0 or compatible)
- `usb_serial` — MIT
- `permission_handler` — MIT
- `path_provider`, `share_plus` — BSD-3-Clause
