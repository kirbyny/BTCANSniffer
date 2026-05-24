# BTCAN Sniffer

This workspace contains:

- `flutter_app/`: Flutter client that connects to a **VLinker MC** (or other
  ELM327-based OBD-II adapter) over **Bluetooth LE or Classic SPP** to
  display per-ID rows, highlight changed bytes, record captures to local log
  files, and export them. BLE works on Android + iOS; Classic SPP is
  Android-only (iOS doesn't allow non-MFi RFCOMM). See
  [flutter_app/README.md](flutter_app/README.md) for details. T
