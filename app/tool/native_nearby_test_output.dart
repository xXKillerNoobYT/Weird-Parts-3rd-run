import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

const nativeTestOutputMaxBytes = 65536;
const nativeTestOutputMaxMessageId = 0xffffffff;
const _maxSequence = 9007199254740991;
const _kinds = {
  'command': 'C',
  'info': 'I',
  'configure': 'G',
  'connected': 'N',
  'diagnostic': 'D',
  'launcherExit': 'L',
  'failed': 'F',
  'hostInputClosed': 'X',
};

List<String> nativeTestOutputFrames(
  Map<String, Object> record, {
  required String streamId,
  required int messageId,
  bool allowGeneric = false,
}) {
  if (!RegExp(r'^[0-9a-f]{16}$').hasMatch(streamId) ||
      messageId < 1 ||
      messageId > nativeTestOutputMaxMessageId) {
    throw const FormatException('invalid frame identity');
  }
  final kind = _kinds[record['outcome']] ?? (allowGeneric ? 'J' : null);
  if (kind == null) throw const FormatException('unknown output kind');
  final value = record['value'];
  final sequence = kind == 'C' && value is Map ? value['sequence'] ?? 0 : 0;
  if (sequence is! int || sequence < 0 || sequence > _maxSequence) {
    throw const FormatException('invalid output sequence');
  }
  final source = jsonEncode(record);
  if (source.length > nativeTestOutputMaxBytes) {
    throw const FormatException('output too large');
  }
  final bytes = utf8.encode(source);
  if (bytes.isEmpty || bytes.length > nativeTestOutputMaxBytes) {
    throw const FormatException('output too large');
  }
  final encoded = base64Url.encode(bytes).replaceAll('=', '');
  final count = (encoded.length + 31) ~/ 32;
  final digest = sha256.convert(bytes).toString();
  final prefix = '!W1:$streamId:${messageId.toRadixString(16).padLeft(8, '0')}';
  final lines = <String>[
    '$prefix:H:${bytes.length.toRadixString(16).padLeft(5, '0')}:'
        '${count.toRadixString(16).padLeft(4, '0')}:$kind:'
        '${sequence.toRadixString(16).padLeft(14, '0')}',
    '$prefix:S0:${digest.substring(0, 32)}',
    '$prefix:S1:${digest.substring(32)}',
    for (var index = 0; index < count; index++)
      '$prefix:D:${index.toRadixString(16).padLeft(4, '0')}:'
          '${encoded.substring(index * 32, min((index + 1) * 32, encoded.length))}',
    '$prefix:E',
  ];
  return lines;
}

final class NativeTestOutputEncoding {
  const NativeTestOutputEncoding(this.text, {this.invalidOutput = false});
  final String text;
  final bool invalidOutput;
}

final class NativeTestOutputEncoder {
  NativeTestOutputEncoder({
    required this.framed,
    this.allowGeneric = false,
    String? streamId,
  }) : streamId = streamId ?? (framed ? _newStreamId() : '') {
    if (framed && !RegExp(r'^[0-9a-f]{16}$').hasMatch(this.streamId)) {
      throw const FormatException('invalid stream identity');
    }
  }

  final bool framed, allowGeneric;
  final String streamId;
  var _messageId = 0;

  static String _newStreamId() {
    final random = Random.secure();
    return List.generate(
      8,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  NativeTestOutputEncoding encode(Map<String, Object> record) {
    if (!framed) return NativeTestOutputEncoding('${jsonEncode(record)}\n');
    if (_messageId == nativeTestOutputMaxMessageId) {
      throw StateError('output message identity exhausted');
    }
    final messageId = ++_messageId;
    try {
      return NativeTestOutputEncoding(_encode(record, messageId));
    } catch (_) {
      return NativeTestOutputEncoding(
        _encode({'outcome': 'failed', 'category': 'invalidOutput'}, messageId),
        invalidOutput: true,
      );
    }
  }

  String _encode(Map<String, Object> record, int messageId) =>
      '\r\n${nativeTestOutputFrames(record, streamId: streamId, messageId: messageId, allowGeneric: allowGeneric).join('\r\n')}\r\n';
}
