import 'dart:io';

import 'package:archive/archive.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';

import 'edge_tts.dart';

void main() => runApp(const TtsToolApp());

// ponytail: 1 accent duy nhat (xanh duong pastel), nen giay am.
const _ink = Color(0xFF1C1B1A);
const _muted = Color(0xFF6F6A63);
const _paper = Color(0xFFF7F4EE);
const _card = Colors.white;
const _accent = Color(0xFFA8C3A0);
const _onAccent = Color(0xFF2F4228);
const _accentSoft = Color(0xFFEAF2E6);
const _danger = Color(0xFFB3261E);
const _dangerSoft = Color(0xFFFDECEA);

enum SegStatus { pending, loading, done, error }

class Segment {
  final String text;
  final String voice;
  SegStatus status = SegStatus.pending;
  String? error;
  String? filePath;
  int? fileSize;
  Segment(this.text, this.voice);
}

class TtsToolApp extends StatelessWidget {
  const TtsToolApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: _accent,
      surface: _paper,
    );
    return MaterialApp(
      title: 'Lazy Speech Tool',
      theme: ThemeData(
        colorScheme: scheme,
        scaffoldBackgroundColor: _paper,
        textTheme: GoogleFonts.beVietnamProTextTheme(
          Theme.of(context).textTheme,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: _accent,
            foregroundColor: _onAccent,
            textStyle: const TextStyle(fontWeight: FontWeight.w600),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: _ink,
            side: const BorderSide(color: Color(0xFFD8D2C7)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          ),
        ),
      ),
      home: const TtsHomePage(),
    );
  }
}

class TtsHomePage extends StatefulWidget {
  const TtsHomePage({super.key});

  @override
  State<TtsHomePage> createState() => _TtsHomePageState();
}

class _TtsHomePageState extends State<TtsHomePage> {
  final _controller = TextEditingController();
  final _player = AudioPlayer();
  List<Segment> _segments = [];
  bool _running = false;
  bool _cancelRequested = false;
  String? _outDir;

  @override
  void dispose() {
    _controller.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<String> _outputDir() async {
    if (_outDir != null) return _outDir!;
    final downloads = await getDownloadsDirectory();
    final dir = Directory(
        '${downloads?.path ?? Directory.systemTemp.path}/lazy-speech-tool');
    if (!await dir.exists()) await dir.create(recursive: true);
    return _outDir = dir.path;
  }

  Future<void> _generate() async {
    final segs = splitSegments(_controller.text)
        .map((t) => Segment(t, detectVoice(t)))
        .toList();
    if (segs.isEmpty) {
      _snack('Paste text, cách nhau bằng dấu ; trước.');
      return;
    }
    if (segs.length > 100) {
      _snack('Tối đa 100 đoạn/lần.');
      return;
    }
    setState(() {
      _segments = segs;
      _running = true;
      _cancelRequested = false;
    });
    try {
      final dir = await _outputDir();
      for (var i = 0; i < _segments.length; i++) {
        if (_cancelRequested) break;
        final seg = _segments[i];
        if (!mounted) return;
        setState(() => seg.status = SegStatus.loading);
        String? bytesErr;
        for (var attempt = 0; attempt < 2; attempt++) {
          if (_cancelRequested) break;
          try {
            final bytes =
                await synthesize(text: seg.text, voice: seg.voice);
            final path = '$dir/${fileNameFor(i + 1, seg.text)}';
            await File(path).writeAsBytes(bytes);
            if (!mounted) return;
            setState(() {
              seg.status = SegStatus.done;
              seg.filePath = path;
              seg.fileSize = bytes.length;
              seg.error = null;
            });
            bytesErr = null;
            break;
          } catch (e) {
            // ponytail: bat moi loai loi (Socket, timeout...), khong rieng
            // EdgeTtsException — loi la phai hien dong do, khong kẹt nút.
            bytesErr = e is EdgeTtsException ? e.message : e.toString();
          }
        }
        if (bytesErr != null) {
          if (!mounted) return;
          setState(() {
            seg.status = SegStatus.error;
            seg.error = bytesErr;
          });
        }
      }
      if (_cancelRequested) {
        _snack('Đã hủy.');
      } else {
        _snack('Xong: ${_segments.where((s) => s.status == SegStatus.done).length}/${_segments.length} đoạn.');
      }
    } catch (e) {
      _snack('Lỗi: $e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _retryOne(int i) async {
    final seg = _segments[i];
    setState(() {
      seg.status = SegStatus.loading;
      seg.error = null;
    });
    try {
      final bytes = await synthesize(text: seg.text, voice: seg.voice);
      final dir = await _outputDir();
      final path = '$dir/${fileNameFor(i + 1, seg.text)}';
      await File(path).writeAsBytes(bytes);
      setState(() {
        seg.status = SegStatus.done;
        seg.filePath = path;
        seg.fileSize = bytes.length;
      });
    } on EdgeTtsException catch (e) {
      setState(() {
        seg.status = SegStatus.error;
        seg.error = e.message;
      });
    } catch (e) {
      setState(() {
        seg.status = SegStatus.error;
        seg.error = e.toString();
      });
    }
  }

  Future<void> _play(String? path) async {
    if (path == null) return;
    await _player.stop();
    await _player.play(DeviceFileSource(path));
  }

  Future<void> _downloadZip() async {
    final done =
        _segments.where((s) => s.status == SegStatus.done).toList();
    if (done.isEmpty) {
      _snack('Chưa có đoạn nào xong.');
      return;
    }
    final archive = Archive();
    for (final seg in done) {
      final bytes = await File(seg.filePath!).readAsBytes();
      final name = fileNameFor(_segments.indexOf(seg) + 1, seg.text);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }
    final dir = await _outputDir();
    final zipPath = '$dir/lazy-speech-tool.zip';
    await File(zipPath).writeAsBytes(ZipEncoder().encode(archive));
    _snack('Zip xong: $zipPath');
  }

  Future<void> _openFolder() async {
    final dir = await _outputDir();
    if (Platform.isMacOS) {
      await Process.run('open', [dir]);
    } else if (Platform.isWindows) {
      await Process.run('explorer', [dir]);
    } else {
      _snack(dir);
    }
  }

  Future<void> _reveal(String? path) async {
    if (path == null) return;
    if (Platform.isMacOS) {
      await Process.run('open', ['-R', path]);
    } else if (Platform.isWindows) {
      await Process.run('explorer', ['/select,', path]);
    } else {
      _snack(path);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final doneCount =
        _segments.where((s) => s.status == SegStatus.done).length;
    final loadingIdx =
        _segments.indexWhere((s) => s.status == SegStatus.loading);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
            children: [
              Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.asset(
                      'assets/images/logo.png',
                      width: 44,
                      height: 44,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Lazy Speech Tool',
                          style: TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.5,
                            height: 1.2,
                            color: _ink,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Edge TTS — mỗi đoạn cách nhau bằng dấu chấm phẩy',
                          style:
                              TextStyle(fontSize: 13.5, color: _muted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Container(
                decoration: BoxDecoration(
                  color: _card,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFE5DFD3)),
                ),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _controller,
                      builder: (context, value, _) {
                        final n = splitSegments(value.text).length;
                        return TextField(
                          controller: _controller,
                          maxLines: 5,
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            hintText:
                                'Hello; My name is Matthew; Xin chào bạn',
                            hintStyle: const TextStyle(color: Color(0xFFB4ADA0)),
                              helperText: n == 0
                                ? 'Paste text vào đây'
                                : '$n đoạn • tự động chọn giọng Anh/Việt',
                            helperStyle: const TextStyle(color: _muted),
                          ),
                          style: const TextStyle(fontSize: 15, height: 1.5),
                        );
                      },
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (!_running)
                          FilledButton.icon(
                            onPressed: _generate,
                            icon: const Icon(Icons.graphic_eq, size: 18),
                            label: const Text('Tạo audio'),
                          ),
                      ],
                    ),
                    if (_running && loadingIdx >= 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                                    'Đang tạo ${loadingIdx + 1}/${_segments.length}…',
                              style: const TextStyle(
                                fontSize: 12.5,
                                color: _muted,
                                fontFeatures: [
                                  FontFeature.tabularFigures()
                                ],
                              ),
                            ),
                            const SizedBox(height: 6),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Expanded(
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(4),
                                    child: LinearProgressIndicator(
                                      value: loadingIdx / _segments.length,
                                      backgroundColor:
                                          const Color(0xFFEDE8DD),
                                      color: _accent,
                                      minHeight: 6,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                SizedBox(
                                  width: 28,
                                  height: 28,
                                  child: IconButton(
                                    tooltip: 'Hủy',
                                    padding: EdgeInsets.zero,
                                    icon:
                                        const Icon(Icons.close, size: 18),
                                    color: _muted,
                                    onPressed: () => setState(
                                        () => _cancelRequested = true),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              if (_segments.isEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 48),
                  child: const Column(
                    children: [
                      Icon(
                        Icons.audio_file_outlined,
                        size: 44,
                        color: Color(0xFFC9C2B4),
                      ),
                      SizedBox(height: 12),
                      Text(
                        'Chưa có đoạn nào',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: _muted,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Nhập text ở trên, bấm Tạo audio',
                        style: TextStyle(fontSize: 13, color: _muted),
                      ),
                    ],
                  ),
                )
              else
                for (var i = 0; i < _segments.length; i++)
                  _SegmentRow(
                    index: i,
                    segment: _segments[i],
                    onPlay: () => _play(_segments[i].filePath),
                    onReveal: () => _reveal(_segments[i].filePath),
                    onRetry: () => _retryOne(i),
                  ),
              if (doneCount > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _downloadZip,
                          icon: const Icon(Icons.download_outlined, size: 18),
                          label: Text(
                            'Tải tất cả ($doneCount)',
                            style: const TextStyle(
                                fontFeatures: [
                                  FontFeature.tabularFigures()
                                ]),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: _openFolder,
                        icon: const Icon(
                            Icons.folder_open_outlined, size: 18),
                        label: const Text('Mở thư mục'),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SegmentRow extends StatelessWidget {
  final int index;
  final Segment segment;
  final VoidCallback onPlay;
  final VoidCallback onReveal;
  final VoidCallback onRetry;

  const _SegmentRow({
    required this.index,
    required this.segment,
    required this.onPlay,
    required this.onReveal,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final seg = segment;
    final failed = seg.status == SegStatus.error;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: failed ? _dangerSoft : _card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: failed ? const Color(0xFFF0C6C2) : const Color(0xFFE5DFD3),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: failed ? Colors.white : _accentSoft,
              borderRadius: BorderRadius.circular(10),
            ),
            child: seg.status == SegStatus.loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: _accent,
                    ),
                  )
                : Text(
                    '${index + 1}',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: failed ? _danger : _accent,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  seg.text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w500,
                    color: _ink,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _metaLine(),
                  style: TextStyle(
                    fontSize: 12,
                    color: failed ? _danger : _muted,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          if (seg.status == SegStatus.done) ...[
            IconButton(
                                    tooltip: 'Nghe thử',
              icon: const Icon(Icons.play_arrow),
              color: _accent,
              onPressed: onPlay,
            ),
            IconButton(
              tooltip: 'Xem file mp3',
              icon: const Icon(Icons.download_outlined),
              color: _muted,
              onPressed: onReveal,
            ),
          ],
          if (failed)
            IconButton(
                              tooltip: 'Thử lại',
              icon: const Icon(Icons.refresh),
              color: _danger,
              onPressed: onRetry,
            ),
        ],
      ),
    );
  }

  String _metaLine() {
    final voice = segment.voice == viVoice ? 'Giọng Việt' : 'Giọng Anh';
    return switch (segment.status) {
      SegStatus.pending => voice,
      SegStatus.loading => 'Đang tạo…',
      SegStatus.done =>
        '$voice • ${_kb(segment.fileSize)} • ${fileNameFor(index + 1, segment.text)}',
      SegStatus.error => 'Lỗi: ${segment.error}',
    };
  }

  String _kb(int? bytes) {
    if (bytes == null) return '';
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
}
