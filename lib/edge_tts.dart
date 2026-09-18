import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

// ponytail: port thuat toan tu edge-tts (rany2) sang Dart, chi lay nhung gi
// tool can: GEC token + 1 wss request/response. Khong port word boundary,
// proxy, offset compensation.
//
// Transport dung SecureSocket + WS framing tay thay vi WebSocket.connect:
// dart:io tu chen `Dart/x (dart:io)` vao User-Agent -> Edge tra 403.

const String trustedClientToken = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
const String _baseUrl =
    'speech.platform.bing.com/consumer/speech/synthesize/readaloud';
const String _wssUrl =
    'wss://$_baseUrl/edge/v1?TrustedClientToken=$trustedClientToken';
const String _chromiumFullVersion = '143.0.3650.75';
const String _chromiumMajorVersion = '143';
const String _secMsGecVersion = '1-$_chromiumFullVersion';
const String _edgeUa = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
    'AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/$_chromiumMajorVersion.0.0.0 Safari/537.36 '
    'Edg/$_chromiumMajorVersion.0.0.0';
const String _origin =
    'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold';

/// Voice fix cung theo spec.
const String viVoice = 'vi-VN-HoaiMyNeural';
const String enVoice = 'en-US-AriaNeural';

final _uuid = Uuid();
final _rand = Random.secure();

/// Tach text thanh doan theo xuong dong, trim, bo dong trang.
List<String> splitSegments(String input) => input
    .split('\n')
    .map((s) => s.trim())
    .where((s) => s.isNotEmpty)
    .toList();

/// Co dau tieng Viet -> voice Viet, con lai voice Anh.
String detectVoice(String segment) =>
    RegExp(r'[à-ỹÀ-ỸđĐ]').hasMatch(segment) ? viVoice : enVoice;

/// Service khong chiu cac control char -> thay bang space (giong edge-tts).
String sanitize(String s) => s.split('').map((c) {
      final code = c.codeUnitAt(0);
      if ((code >= 0 && code <= 8) ||
          (code >= 11 && code <= 12) ||
          (code >= 14 && code <= 31)) {
        return ' ';
      }
      return c;
    }).join();

/// Ten file tai xuong: `1 - Hello.mp3`. Loc ky tu cam tren Win/Mac.
String fileNameFor(int index, String text) {
  var name = text
      .replaceAll(RegExp(r'[\\/:*?"<>|;\x00-\x1f]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (name.length > 80) name = name.substring(0, 80).trim();
  if (name.isEmpty) name = 'segment';
  return '$index - $name.mp3';
}

String _generateSecMsGec() {
  // Giong het float ops cua edge-tts (Python float = IEEE754 double).
  double ticks = DateTime.now().toUtc().millisecondsSinceEpoch / 1000;
  ticks += 11644473600; // WIN_EPOCH
  ticks -= ticks % 300; // tron xuong 5 phut
  ticks *= 1e9 / 100; // 100-nanosecond intervals
  final strToHash = '${ticks.toStringAsFixed(0)}$trustedClientToken';
  return sha256.convert(ascii.encode(strToHash)).toString().toUpperCase();
}

String _generateMuid() => List.generate(16, (_) => _rand.nextInt(256))
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join()
    .toUpperCase();

/// JS-style date string, giu bug `+ "Z"` giong edge-tts.
String _dateToString() {
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final now = DateTime.now().toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${days[now.weekday - 1]} ${months[now.month - 1]} '
      '${two(now.day)} ${now.year} ${two(now.hour)}:${two(now.minute)}:${two(now.second)} '
      'GMT+0000 (Coordinated Universal Time)';
}

String _escapeXml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

Map<String, String> _parseHeaders(String raw) {
  final out = <String, String>{};
  for (final line in raw.split('\r\n')) {
    final idx = line.indexOf(':');
    if (idx > 0) out[line.substring(0, idx)] = line.substring(idx + 1);
  }
  return out;
}

class EdgeTtsException implements Exception {
  final String message;
  EdgeTtsException(this.message);
  @override
  String toString() => 'EdgeTtsException: $message';
}

/// WS client toi gian: handshake + text/binary, khong compression.
class _RawWs {
  final SecureSocket _socket;
  final StreamIterator<List<int>> _it;
  final List<int> _buf = [];

  _RawWs(this._socket) : _it = StreamIterator(_socket);

  /// Nap _buf cho den khi co it nhat n bytes. False khi socket dong/timeout.
  Future<bool> _fill(int n) async {
    while (_buf.length < n) {
      bool hasNext;
      try {
        hasNext = await _it.moveNext()
            .timeout(const Duration(seconds: 90));
      } catch (_) {
        return false;
      }
      if (!hasNext) return false;
      _buf.addAll(_it.current);
    }
    return true;
  }

  List<int> _take(int n) {
    final out = _buf.sublist(0, n);
    _buf.removeRange(0, n);
    return out;
  }

  static Future<_RawWs> connect(String url, Map<String, String> headers) async {
    final uri = Uri.parse(url);
    final socket = await SecureSocket.connect(
      uri.host,
      uri.port == 0 ? 443 : uri.port,
      timeout: const Duration(seconds: 10),
    );
    final key = base64Encode(
        List.generate(16, (_) => _rand.nextInt(256)));
    final req = StringBuffer('GET ${uri.path}?${uri.query} HTTP/1.1\r\n'
        'Host: ${uri.host}\r\n'
        'Upgrade: websocket\r\n'
        'Connection: Upgrade\r\n'
        'Sec-WebSocket-Key: $key\r\n'
        'Sec-WebSocket-Version: 13\r\n');
    headers.forEach((k, v) => req.write('$k: $v\r\n'));
    req.write('\r\n');
    socket.write(req.toString());
    await socket.flush();

    final ws = _RawWs(socket);
    final marker = utf8.encode('\r\n\r\n');
    var headerEnd = -1;
    while (headerEnd < 0) {
      if (!await ws._fill(ws._buf.length + 1)) {
        socket.destroy();
        throw EdgeTtsException('Handshake không có phản hồi.');
      }
      headerEnd = _indexOf(ws._buf, marker);
    }
    final headerStr = utf8.decode(
        ws._take(headerEnd + marker.length),
        allowMalformed: true);
    if (!headerStr.startsWith('HTTP/1.1 101')) {
      final firstLine = headerStr.split('\r\n').firstOrNull ?? headerStr;
      socket.destroy();
      throw EdgeTtsException('Handshake thất bại: $firstLine');
    }
    return ws;
  }

  static int _indexOf(List<int> data, List<int> marker) {
    outer:
    for (var i = 0; i + marker.length <= data.length; i++) {
      for (var j = 0; j < marker.length; j++) {
        if (data[i + j] != marker[j]) continue outer;
      }
      return i;
    }
    return -1;
  }

  void sendText(String data) {
    final payload = utf8.encode(data);
    final frame = BytesBuilder();
    frame.addByte(0x81); // FIN + text
    final mask = List.generate(4, (_) => _rand.nextInt(256));
    if (payload.length < 126) {
      frame.addByte(0x80 | payload.length);
    } else if (payload.length < 65536) {
      frame.addByte(0x80 | 126);
      frame.addByte((payload.length >> 8) & 0xFF);
      frame.addByte(payload.length & 0xFF);
    } else {
      frame.addByte(0x80 | 127);
      for (var i = 7; i >= 0; i--) {
        frame.addByte((payload.length >> (8 * i)) & 0xFF);
      }
    }
    frame.add(mask);
    for (var i = 0; i < payload.length; i++) {
      frame.addByte(payload[i] ^ mask[i % 4]);
    }
    _socket.add(frame.toBytes());
  }

  void _sendPong(List<int> payload) {
    final frame = BytesBuilder()..addByte(0x8A)..addByte(0x80 | payload.length);
    final mask = List.generate(4, (_) => _rand.nextInt(256));
    frame.add(mask);
    for (var i = 0; i < payload.length; i++) {
      frame.addByte(payload[i] ^ mask[i % 4]);
    }
    _socket.add(frame.toBytes());
  }

  /// Doc message WS tiep theo. Tra ve (isText, payload). Null khi dong.
  Future<(bool, List<int>)?> nextMessage() async {
    var opcode = -1;
    final textBuf = BytesBuilder();
    final binBuf = BytesBuilder();
    while (true) {
      final header = await _readBytes(2);
      if (header == null) return null;
      final fin = (header[0] & 0x80) != 0;
      final op = header[0] & 0x0F;
      final masked = (header[1] & 0x80) != 0;
      var len = header[1] & 0x7F;
      if (len == 126) {
        final ext = await _readBytes(2);
        if (ext == null) return null;
        len = (ext[0] << 8) | ext[1];
      } else if (len == 127) {
        final ext = await _readBytes(8);
        if (ext == null) return null;
        len = 0;
        for (final b in ext) {
          len = (len << 8) | b;
        }
      }
      List<int> mask = const [];
      if (masked) {
        final m = await _readBytes(4);
        if (m == null) return null;
        mask = m;
      }
      final payload = await _readBytes(len);
      if (payload == null) return null;
      if (masked) {
        for (var i = 0; i < payload.length; i++) {
          payload[i] ^= mask[i % 4];
        }
      }
      if (op == 0x8) return null; // close
      if (op == 0x9) {
        _sendPong(payload); // ping
        continue;
      }
      if (op == 0xA) continue; // pong
      if (op == 0x1 || op == 0x2) opcode = op;
      if (opcode == 0x1) {
        textBuf.add(payload);
      } else {
        binBuf.add(payload);
      }
      if (fin) {
        return opcode == 0x1
            ? (true, textBuf.toBytes())
            : (false, binBuf.toBytes());
      }
    }
  }

  Future<List<int>?> _readBytes(int n) async {
    if (!await _fill(n)) return null;
    return _take(n);
  }

  void close() => _socket.destroy();
}

/// Tao mp3 cho 1 doan text. Throw [EdgeTtsException] khi loi.
Future<Uint8List> synthesize(
    {required String text, required String voice}) async {
  final clean = sanitize(text);
  if (clean.isEmpty) throw EdgeTtsException('Đoạn text rỗng.');
  if (clean.length > 2000) {
    throw EdgeTtsException('Đoạn quá dài (>2000 ký tự), bị skip.');
  }

  final connectionId = _uuid.v4().replaceAll('-', '');
  final url = '$_wssUrl&ConnectionId=$connectionId'
      '&Sec-MS-GEC=${_generateSecMsGec()}'
      '&Sec-MS-GEC-Version=$_secMsGecVersion';

  late _RawWs ws;
  try {
    ws = await _RawWs.connect(url, {
      'User-Agent': _edgeUa,
      'Accept-Encoding': 'gzip, deflate, br, zstd',
      'Accept-Language': 'en-US,en;q=0.9',
      'Pragma': 'no-cache',
      'Cache-Control': 'no-cache',
      'Origin': _origin,
      'Cookie': 'muid=${_generateMuid()};',
    });
  } on EdgeTtsException {
    rethrow;
  } catch (e) {
    throw EdgeTtsException('Không nối được Edge TTS: $e');
  }

  final audio = BytesBuilder();
  var audioReceived = false;

  try {
    ws.sendText('X-Timestamp:${_dateToString()}\r\n'
        'Content-Type:application/json; charset=utf-8\r\n'
        'Path:speech.config\r\n\r\n'
        '{"context":{"synthesis":{"audio":{"metadataoptions":{'
        '"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"'
        '},"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}\r\n');

    final ssml = "<speak version='1.0' "
        "xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'>"
        "<voice name='$voice'>"
        "<prosody pitch='+0Hz' rate='+0%' volume='+0%'>"
        '${_escapeXml(clean)}'
        '</prosody></voice></speak>';
    ws.sendText('X-RequestId:${_uuid.v4().replaceAll('-', '')}\r\n'
        'Content-Type:application/ssml+xml\r\n'
        'X-Timestamp:${_dateToString()}Z\r\n'
        'Path:ssml\r\n\r\n'
        '$ssml');

    while (true) {
      final msg = await ws.nextMessage().timeout(
          const Duration(seconds: 90),
          onTimeout: () => throw EdgeTtsException('Timeout chờ audio.'));
      if (msg == null) break;
      if (msg.$1) {
        final text2 =
            utf8.decode(msg.$2, allowMalformed: true);
        final sep = text2.indexOf('\r\n\r\n');
        if (sep < 0) continue;
        if (_parseHeaders(text2.substring(0, sep))['Path'] == 'turn.end') {
          break;
        }
      } else {
        final data = Uint8List.fromList(msg.$2);
        if (data.length < 2) continue;
        final headerLen = (data[0] << 8) | data[1];
        if (headerLen > data.length) continue;
        final headerStr = utf8.decode(data.sublist(2, 2 + headerLen),
            allowMalformed: true);
        if (_parseHeaders(headerStr)['Path'] != 'audio') continue;
        final body = data.sublist(2 + headerLen);
        if (body.isEmpty) continue;
        audioReceived = true;
        audio.add(body);
      }
    }
  } on EdgeTtsException {
    rethrow;
  } catch (e) {
    throw EdgeTtsException('Lỗi khi nhận audio: $e');
  } finally {
    ws.close();
  }

  if (!audioReceived) {
    throw EdgeTtsException('Edge không trả audio. Thử lại sau.');
  }
  return audio.toBytes();
}
