# BTCAN Sniffer

This workspace contains:

- `firmware/`: ESP-IDF app for ESP32-C6 that sniffs CAN traffic using TWAI on GPIO 20 (RX), auto-detects bitrate, attempts byte-order detection, and streams frames over BLE.
- `flutter_app/`: Flutter BLE client to display per-ID rows, highlight changed bytes, capture frames, and export CSV.

## Firmware (ESP32-C6)

### Features

- TWAI listen-only mode for passive sniffing.
- CAN RX on GPIO 20, TX configured on GPIO 21 (required by driver/transceiver wiring).
- Auto bitrate detection across common rates: 50k, 100k, 125k, 250k, 500k, 800k, 1M.
- Manual bitrate override via BLE command.
- Auto byte-order inference attempt (LE vs BE heuristic) with manual override.
- BLE custom service:
  - Service UUID: `FFF0`
  - TX Notify characteristic UUID: `FFF1`
  - RX Write characteristic UUID: `FFF2`

### BLE Message Format

Device sends text lines ending in `\n`.

- CAN frame line:
  - `MSG,<timestamp_ms>,<id_hex>,<dlc>,<b0>,<b1>,<b2>,<b3>,<b4>,<b5>,<b6>,<b7>`
- Config / status:
  - `CFG,BITRATE,<rate>,BYTEORDER,<mode>`
- Info and errors:
  - `INFO,...`
  - `ERR,...`

### BLE Commands

Write UTF-8 text to characteristic `FFF2`:

- `GET STATUS`
- `SET BITRATE AUTO`
- `SET BITRATE 500000` (or any supported rate)
- `SET BYTEORDER AUTO`
- `SET BYTEORDER LE`
- `SET BYTEORDER BE`

### Build & Flash

1. Install ESP-IDF (v5.x recommended).
2. In `firmware/`:
   - `idf.py set-target esp32c6`
   - `idf.py build`
   - `idf.py -p <PORT> flash monitor`

## Flutter App

### Features

- Scans for BLE device named `BTCAN-SNIFFER`.
- Connects and subscribes to CAN stream notifications.
- Shows one row per CAN ID, continuously updating latest bytes.
- Highlights bytes that changed from previous update.
- Controls for bitrate and byte-order modes (auto/manual).
- Capture controls:
  - Unlimited capture (blank limit) or set max frame count.
  - Start/stop capture.
  - Export captured frames as CSV via share dialog.

### Run

1. Install Flutter SDK.
2. In `flutter_app/`:
   - `flutter pub get`
   - `flutter run`

### Mobile BLE Permission Notes

Depending on your Flutter/Android/iOS versions, you may need platform BLE permissions in app manifests (especially Android 12+ `BLUETOOTH_SCAN` and `BLUETOOTH_CONNECT`).
