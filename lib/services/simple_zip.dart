import 'dart:convert';
import 'dart:typed_data';

Uint8List createStoredZip(Map<String, Uint8List> files) {
  final output = BytesBuilder(copy: false);
  final centralDirectory = BytesBuilder(copy: false);
  var offset = 0;
  var count = 0;
  for (final entry in files.entries) {
    final name = Uint8List.fromList(utf8.encode(entry.key));
    final bytes = entry.value;
    final crc = _crc32(bytes);
    final local = BytesBuilder(copy: false)
      ..add(_u32(0x04034b50))
      ..add(_u16(20))
      ..add(_u16(0x0800))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u16(0x0021))
      ..add(_u32(crc))
      ..add(_u32(bytes.length))
      ..add(_u32(bytes.length))
      ..add(_u16(name.length))
      ..add(_u16(0))
      ..add(name)
      ..add(bytes);
    final localBytes = local.takeBytes();
    output.add(localBytes);

    centralDirectory
      ..add(_u32(0x02014b50))
      ..add(_u16(20))
      ..add(_u16(20))
      ..add(_u16(0x0800))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u16(0x0021))
      ..add(_u32(crc))
      ..add(_u32(bytes.length))
      ..add(_u32(bytes.length))
      ..add(_u16(name.length))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u32(0))
      ..add(_u32(offset))
      ..add(name);
    offset += localBytes.length;
    count++;
  }
  final directoryBytes = centralDirectory.takeBytes();
  output
    ..add(directoryBytes)
    ..add(_u32(0x06054b50))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u16(count))
    ..add(_u16(count))
    ..add(_u32(directoryBytes.length))
    ..add(_u32(offset))
    ..add(_u16(0));
  return output.takeBytes();
}

Uint8List _u16(int value) {
  final data = ByteData(2)..setUint16(0, value, Endian.little);
  return data.buffer.asUint8List();
}

Uint8List _u32(int value) {
  final data = ByteData(4)..setUint32(0, value, Endian.little);
  return data.buffer.asUint8List();
}

int _crc32(Uint8List bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) == 1 ? 0xedb88320 ^ (crc >>> 1) : crc >>> 1;
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}
