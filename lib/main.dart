import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:audio_waveforms/audio_waveforms.dart' as wave;
import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:auto_size_text/auto_size_text.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TeleprompterStudioApp());
}

class TeleprompterStudioApp extends StatelessWidget {
  const TeleprompterStudioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TeleprompterStudio',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFB71C1C)),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF5F6F8),
      ),
      home: const TeleprompterPage(),
    );
  }
}

class AudioTake {
  AudioTake({required this.path, required this.createdAt});
  final String path;
  final DateTime createdAt;
  String get name => 'Take ${createdAt.hour.toString().padLeft(2, '0')}:${createdAt.minute.toString().padLeft(2, '0')}';
}

class TeleprompterPage extends StatefulWidget {
  const TeleprompterPage({super.key});

  @override
  State<TeleprompterPage> createState() => _TeleprompterPageState();
}

class _TeleprompterPageState extends State<TeleprompterPage> {
  final TextEditingController _scriptController = TextEditingController();
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();
  final List<AudioTake> _takes = [];
  Timer? _lineTimer;

  List<String> _lines = [];
  int _lineIndex = 0;
  int _secondsPerLine = 5;
  int _secondsLeft = 5;
  int _lineElapsedMs = 0;
  bool _running = false;
  bool _recording = false;
  bool _silentMode = false;
  bool _hasStarted = false;
  bool _exporting = false;
  bool _showTimeline = false;
  String? _playingPath;
  String _status = 'Paste your script to begin.';

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _lineTimer?.cancel();
    _scriptController.dispose();
    _recorder.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<String> _newAudioPath() async {
    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory('${dir.path}/recordings');
    if (!await folder.exists()) await folder.create(recursive: true);
    return '${folder.path}/take_${DateTime.now().microsecondsSinceEpoch}.m4a';
  }

  void _loadScript() {
    final parsed = _scriptController.text
        .split(RegExp(r'\r?\n'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (parsed.isEmpty) {
      setState(() => _status = 'Please paste at least one line.');
      return;
    }
    _stopTimer();
    setState(() {
      _lines = parsed;
      _lineIndex = 0;
      _secondsLeft = _secondsPerLine;
      _lineElapsedMs = 0;
      _running = false;
      _silentMode = false;
      _hasStarted = false;
      _status = '${parsed.length} lines loaded.';
    });
  }

  void _startTimer() {
    if (_lines.isEmpty) return;
    _lineTimer?.cancel();
    _lineTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted) return;
      final totalMs = _secondsPerLine * 1000;
      if (_lineElapsedMs + 100 >= totalMs) {
        if (_lineIndex < _lines.length - 1) {
          setState(() {
            _lineIndex++;
            _lineElapsedMs = 0;
            _secondsLeft = _secondsPerLine;
          });
        } else {
          _stopTimer();
          setState(() {
            _lineElapsedMs = totalMs;
            _secondsLeft = 0;
            _running = false;
            _silentMode = false;
            _status = 'Script finished.';
          });
          unawaited(_stopRecordingSegment());
        }
      } else {
        setState(() {
          _lineElapsedMs += 100;
          _secondsLeft = ((_secondsPerLine * 1000 - _lineElapsedMs) / 1000).ceil();
        });
      }
    });
  }

  void _stopTimer() {
    _lineTimer?.cancel();
    _lineTimer = null;
  }

  Future<void> _startRecordingSegment() async {
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      setState(() => _status = 'Microphone permission is required to record audio.');
      return;
    }
    if (!await _recorder.hasPermission()) {
      setState(() => _status = 'Microphone permission was not granted.');
      return;
    }
    final path = await _newAudioPath();
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 128000, sampleRate: 44100),
      path: path,
    );
    if (!mounted) return;
    setState(() {
      _recording = true;
      _status = 'Recording audio…';
    });
  }

  Future<void> _stopRecordingSegment() async {
    if (!_recording) return;
    final path = await _recorder.stop();
    if (!mounted) return;
    setState(() => _recording = false);
    if (path != null && await File(path).exists()) {
      setState(() {
        _takes.add(AudioTake(path: path, createdAt: DateTime.now()));
        _status = 'Audio segment saved.';
      });
    }
  }

  Future<void> _toggleSilentPlayback() async {
    if (_running) {
      if (!_silentMode) {
        setState(() => _status = 'Stop or pause recording before starting silent playback.');
        return;
      }
      _stopTimer();
      setState(() {
        _running = false;
        _status = 'Silent playback paused.';
      });
      return;
    }
    if (_lines.isEmpty) {
      _loadScript();
      if (_lines.isEmpty) return;
    }
    if (!_hasStarted || _lineIndex >= _lines.length - 1 && _lineElapsedMs >= _secondsPerLine * 1000) {
      setState(() {
        _lineIndex = 0;
        _lineElapsedMs = 0;
        _secondsLeft = _secondsPerLine;
      });
    }
    setState(() {
      _hasStarted = true;
      _running = true;
      _recording = false;
      _silentMode = true;
      _status = 'Silent playback — text and seeker only. No audio is played or recorded.';
    });
    _startTimer();
  }

  Future<void> _playPause() async {
    if (_lines.isEmpty) {
      _loadScript();
      if (_lines.isEmpty) return;
    }
    if (_running) {
      _stopTimer();
      await _stopRecordingSegment();
      setState(() {
        _running = false;
        _status = 'Paused. Press Resume to continue.';
      });
      return;
    }
    if (!_hasStarted) {
      setState(() {
        _lineIndex = 0;
        _secondsLeft = _secondsPerLine;
        _lineElapsedMs = 0;
        _hasStarted = true;
      });
    }
    await _startRecordingSegment();
    if (!mounted) return;
    setState(() {
      _silentMode = false;
      _running = true;
      _status = 'Teleprompter running.';
    });
    _startTimer();
  }

  Future<void> _finish() async {
    _stopTimer();
    await _stopRecordingSegment();
    setState(() {
      _running = false;
      _hasStarted = false;
      _status = 'Session stopped. Your audio segments are below.';
    });
  }


  Future<void> _shareTake(AudioTake take) async {
    if (!await File(take.path).exists()) return;
    await SharePlus.instance.share(ShareParams(title: take.name, files: [XFile(take.path)]));
  }

  Future<void> _saveTakeToLocation(AudioTake take) async {
    try {
      final file = File(take.path);
      if (!await file.exists()) return;
      final bytes = await file.readAsBytes();
      final saved = await FilePicker.saveFile(
        dialogTitle: 'Save audio take',
        fileName: take.path.split(Platform.pathSeparator).last,
        bytes: bytes,
      );
      if (mounted) setState(() => _status = saved == null
          ? 'Save cancelled.'
          : 'Audio take saved to your selected location.');
    } catch (e) {
      if (mounted) setState(() => _status = 'Could not save audio: $e');
    }
  }

  Future<void> _editTake(AudioTake take) async {
    final selection = await showDialog<(int, int)>(
      context: context,
      builder: (_) => _AudioEditorDialog(path: take.path, title: take.name),
    );
    if (selection == null) return;
    final startMs = selection.$1;
    final endMs = selection.$2;
    if (endMs <= startMs) return;
    final dir = await getApplicationDocumentsDirectory();
    final output = dir.path + '/trimmed_' + DateTime.now().microsecondsSinceEpoch.toString() + '.m4a';
    final start = (startMs / 1000).toStringAsFixed(3);
    final duration = ((endMs - startMs) / 1000).toStringAsFixed(3);
    setState(() => _status = 'Trimming selected audio…');
    try {
      final command = "-ss " + start + " -i '" + take.path + "' -t " + duration + " -vn -c:a aac -b:a 128k '" + output + "'";
      final session = await FFmpegKit.execute(command);
      final code = await session.getReturnCode();
      if (!ReturnCode.isSuccess(code) || !await File(output).exists()) {
        throw Exception((await session.getOutput()) ?? 'Could not trim audio.');
      }
      if (!mounted) return;
      setState(() {
        _takes.add(AudioTake(path: output, createdAt: DateTime.now()));
        _status = 'Trimmed audio saved as a new take. Original is unchanged.';
      });
    } catch (e) {
      if (mounted) setState(() => _status = 'Trim failed: $e');
    }
  }

  Future<void> _exportAllTakesAsMp3() async {
    if (_takes.isEmpty || _exporting) return;
    setState(() {
      _exporting = true;
      _status = 'Combining audio segments and exporting MP3…';
    });
    try {
      final dir = await getApplicationDocumentsDirectory();
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final listFile = File('${dir.path}/audio_concat_$stamp.txt');
      final outputFile = File('${dir.path}/teleprompter_export_$stamp.mp3');
      final listContent = _takes
          .where((take) => File(take.path).existsSync())
          .map((take) => "file '${take.path}'")
          .join('\n');
      if (listContent.trim().isEmpty) {
        throw Exception('No saved audio files were found.');
      }
      await listFile.writeAsString('$listContent\n');
      final command =
          "-f concat -safe 0 -i '${listFile.path}' -vn -ac 2 -ar 44100 -codec:a libmp3lame -q:a 2 '${outputFile.path}'";
      final session = await FFmpegKit.execute(command);
      final returnCode = await session.getReturnCode();
      if (ReturnCode.isSuccess(returnCode) && await outputFile.exists()) {
        if (!mounted) return;
        final bytes = await outputFile.readAsBytes();
        final savedUri = await FilePicker.saveFile(
          dialogTitle: 'Save merged audio',
          fileName: 'teleprompter_export_' + stamp.toString() + '.mp3',
          bytes: bytes,
        );
        if (!mounted) return;
        setState(() => _status = savedUri == null
            ? 'Export cancelled. MP3 remains available in app storage.'
            : 'MP3 saved to your selected location.');
      } else {
        final details = (await session.getOutput()) ?? '';
        throw Exception(details.isEmpty ? 'Audio conversion failed.' : details);
      }
      if (await listFile.exists()) await listFile.delete();
    } catch (e) {
      if (mounted) setState(() => _status = 'MP3 export failed: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _playTake(AudioTake take) async {
    try {
      if (_playingPath == take.path) {
        await _player.stop();
        setState(() => _playingPath = null);
      } else {
        await _player.stop();
        await _player.play(DeviceFileSource(take.path));
        setState(() => _playingPath = take.path);
      }
    } catch (e) {
      setState(() => _status = 'Could not play this recording: $e');
    }
  }

  Future<void> _deleteTake(AudioTake take) async {
    if (_playingPath == take.path) {
      await _player.stop();
      _playingPath = null;
    }
    final file = File(take.path);
    if (await file.exists()) await file.delete();
    if (!mounted) return;
    setState(() {
      _takes.remove(take);
      _status = 'Audio segment deleted.';
    });
  }

  void _moveLine(int delta) {
    if (_lines.isEmpty) return;
    setState(() {
      _lineIndex = (_lineIndex + delta).clamp(0, _lines.length - 1);
      _secondsLeft = _secondsPerLine;
      _lineElapsedMs = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final currentLine = _lines.isEmpty ? 'Your script will appear here' : _lines[_lineIndex];
    final lineProgress = _lines.isEmpty ? 0.0 : (_lineElapsedMs / (_secondsPerLine * 1000)).clamp(0.0, 1.0);
    return Scaffold(
      appBar: AppBar(
        title: const Text('TeleprompterStudio', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.white,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('1. Paste your script', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _scriptController,
                    minLines: 4,
                    maxLines: 7,
                    decoration: const InputDecoration(
                      hintText: 'Paste your script here. Put each sentence or paragraph on a new line.',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(children: [
                    const Text('Seconds per line'),
                    const SizedBox(width: 12),
                    DropdownButton<int>(
                      value: _secondsPerLine,
                      items: [2, 3, 4, 5, 6, 8, 10, 12, 15].map((v) => DropdownMenuItem(value: v, child: Text('$v sec'))).toList(),
                      onChanged: _running ? null : (v) => setState(() {
                        _secondsPerLine = v ?? 5;
                        _secondsLeft = _secondsPerLine;
                      }),
                    ),
                    const Spacer(),
                    FilledButton(onPressed: _running ? null : _loadScript, child: const Text('Load script')),
                  ]),
                ]),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              color: const Color(0xFF15191F),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(children: [
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Text(_lines.isEmpty ? 'TELEPROMPTER' : 'LINE ${_lineIndex + 1} / ${_lines.length}',
                        style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.bold)),
                    Text('$_secondsLeft s', style: const TextStyle(color: Colors.amber, fontSize: 18, fontWeight: FontWeight.bold)),
                  ]),
                  const SizedBox(height: 16),
                  ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 170, maxHeight: 300),
                    child: Center(
                      child: SingleChildScrollView(
                        child: AutoSizeText(
                          currentLine,
                          textAlign: TextAlign.center,
                          minFontSize: 15,
                          maxFontSize: 30,
                          stepGranularity: 1,
                          maxLines: 14,
                          overflow: TextOverflow.visible,
                          style: const TextStyle(color: Colors.white, height: 1.3, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(children: [
                    const Text('THIS LINE', style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold)),
                    const Spacer(),
                    Text('${(lineProgress * 100).round()}%', style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold)),
                  ]),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      minHeight: 9,
                      value: lineProgress,
                      backgroundColor: Colors.white24,
                      color: Colors.amber,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text('Overall: ${_lines.isEmpty ? 0 : _lineIndex + 1} / ${_lines.length} lines',
                      style: const TextStyle(color: Colors.white60, fontSize: 12)),
                ]),
              ),
            ),
            if (_lines.isNotEmpty) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => setState(() => _showTimeline = !_showTimeline),
                icon: Icon(_showTimeline ? Icons.expand_less : Icons.list),
                label: Text(_showTimeline ? 'Hide line-by-line list' : 'Show line-by-line list'),
              ),
              if (_showTimeline) Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      const Expanded(child: Text('Line-by-line timeline', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold))),
                      Text('${_lines.length} lines', style: const TextStyle(color: Colors.black54, fontSize: 12)),
                    ]),
                    const SizedBox(height: 8),
                    ..._lines.asMap().entries.map((entry) {
                      final i = entry.key;
                      final progress = i < _lineIndex ? 1.0 : (i == _lineIndex ? lineProgress : 0.0);
                      return InkWell(
                        onTap: _running ? null : () => setState(() {
                          _lineIndex = i;
                          _lineElapsedMs = 0;
                          _secondsLeft = _secondsPerLine;
                        }),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 7),
                          child: Row(children: [
                            SizedBox(width: 28, child: Text('${i + 1}.', style: TextStyle(
                              fontWeight: i == _lineIndex ? FontWeight.bold : FontWeight.normal,
                              color: i == _lineIndex ? const Color(0xFFB71C1C) : Colors.black54))),
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(entry.value, maxLines: 2, overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontWeight: i == _lineIndex ? FontWeight.bold : FontWeight.normal)),
                              const SizedBox(height: 4),
                              ClipRRect(borderRadius: BorderRadius.circular(5), child: LinearProgressIndicator(
                                minHeight: 5, value: progress, backgroundColor: Colors.black12,
                                color: i == _lineIndex ? const Color(0xFFB71C1C) : Colors.green)),
                            ])),
                            const SizedBox(width: 8),
                            Text(i < _lineIndex ? 'Done' : '${_secondsPerLine}s',
                              style: const TextStyle(fontSize: 11, color: Colors.black54)),
                          ]),
                        ),
                      );
                    }),
                  ]),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
              OutlinedButton.icon(onPressed: _running ? null : () => _moveLine(-1), icon: const Icon(Icons.skip_previous), label: const Text('Previous')),
              FilledButton.icon(
                onPressed: _playPause,
                icon: Icon(_running ? Icons.pause : Icons.play_arrow),
                label: Text(_running ? 'Pause' : (_hasStarted ? 'Resume' : 'Start + Record')),
              ),
              OutlinedButton.icon(
                onPressed: _toggleSilentPlayback,
                icon: Icon(_running ? Icons.pause : Icons.visibility),
                label: Text(_running ? 'Pause Silent Play' : 'Play Silently'),
              ),
              OutlinedButton.icon(onPressed: _running ? null : () => _moveLine(1), icon: const Icon(Icons.skip_next), label: const Text('Next')),
              OutlinedButton.icon(onPressed: _finish, icon: const Icon(Icons.stop), label: const Text('Stop')),
            ]),
            const SizedBox(height: 8),
            Text(_status, textAlign: TextAlign.center, style: const TextStyle(color: Colors.black54)),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _takes.isEmpty || _exporting ? null : _exportAllTakesAsMp3,
                icon: _exporting
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.library_music),
                label: Text(_exporting ? 'Exporting MP3…' : 'Merge all takes and Export MP3'),
              ),
            ),
            const SizedBox(height: 18),
            Row(children: [
              const Expanded(child: Text('2. Audio timeline', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
              Text('${_takes.length} segment(s)', style: const TextStyle(color: Colors.black54)),
            ]),
            const SizedBox(height: 4),
            const Text('Each pause or stop saves the current audio take. Play or delete individual takes below.',
                style: TextStyle(color: Colors.black54)),
            const SizedBox(height: 8),
            if (_takes.isEmpty)
              const Card(child: Padding(padding: EdgeInsets.all(18), child: Text('No recordings yet. Press Start + Record.')))
            else
              ..._takes.asMap().entries.map((entry) {
                final i = entry.key;
                final take = entry.value;
                return Card(
                  child: ListTile(
                    leading: CircleAvatar(child: Text('${i + 1}')),
                    title: Text(take.name),
                    subtitle: Text(take.path.split(Platform.pathSeparator).last, maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: Wrap(spacing: 0, children: [
                      IconButton(
                        tooltip: 'Move take up',
                        onPressed: i == 0 ? null : () => setState(() {
                          final item = _takes.removeAt(i);
                          _takes.insert(i - 1, item);
                        }),
                        icon: const Icon(Icons.arrow_upward, size: 19),
                      ),
                      IconButton(
                        tooltip: 'Move take down',
                        onPressed: i == _takes.length - 1 ? null : () => setState(() {
                          final item = _takes.removeAt(i);
                          _takes.insert(i + 1, item);
                        }),
                        icon: const Icon(Icons.arrow_downward, size: 19),
                      ),
                      IconButton(
                        tooltip: 'Open waveform editor and trim',
                        onPressed: () => _editTake(take),
                        icon: const Icon(Icons.graphic_eq),
                      ),
                      IconButton(
                        tooltip: 'Share audio',
                        onPressed: () => _shareTake(take),
                        icon: const Icon(Icons.share),
                      ),
                      IconButton(
                        tooltip: 'Save copy to selected folder',
                        onPressed: () => _saveTakeToLocation(take),
                        icon: const Icon(Icons.save_alt),
                      ),
                      IconButton(
                        tooltip: 'Play / stop',
                        onPressed: () => _playTake(take),
                        icon: Icon(_playingPath == take.path ? Icons.stop_circle : Icons.play_circle_fill),
                      ),
                      IconButton(
                        tooltip: 'Delete segment',
                        onPressed: () => _deleteTake(take),
                        icon: const Icon(Icons.delete_outline, color: Colors.red),
                      ),
                    ]),
                  ),
                );
              }),
            const SizedBox(height: 12),
            const Card(
              child: Padding(
                padding: EdgeInsets.all(14),
                child: Text(
                  'Audio-only recording is available; the camera is never opened. Use Play Silently to advance the script on screen with its seeker only; no sound is played and no audio is recorded. The line-by-line list is hidden until you press Show line-by-line list. Recordings are saved as separate M4A takes and can be merged into one MP3. Each take has a waveform editor, trim option, playback and WhatsApp/other-app sharing. Merged MP3 export lets you choose a save location. Original takes remain unchanged when you trim.',
                  style: TextStyle(height: 1.4),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}


class _AudioEditorDialog extends StatefulWidget {
  const _AudioEditorDialog({required this.path, required this.title});
  final String path;
  final String title;
  @override
  State<_AudioEditorDialog> createState() => _AudioEditorDialogState();
}

class _AudioEditorDialogState extends State<_AudioEditorDialog> {
  late final wave.PlayerController _controller;
  StreamSubscription<int>? _durationSub;
  StreamSubscription<wave.PlayerState>? _stateSub;
  int _durationMs = 0;
  int _playheadMs = 0;
  double _startMs = 0;
  double _endMs = 0;
  bool _ready = false;
  bool _playing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = wave.PlayerController();
    _durationSub = _controller.onCurrentDurationChanged.listen((v) {
      if (_playing && v >= _endMs) unawaited(_controller.pausePlayer());
      if (mounted) setState(() => _playheadMs = v);
    });
    _stateSub = _controller.onPlayerStateChanged.listen((v) {
      if (mounted) setState(() => _playing = v.isPlaying);
    });
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      await _controller.preparePlayer(path: widget.path, shouldExtractWaveform: true, noOfSamples: 160);
      if (!mounted) return;
      setState(() {
        _durationMs = _controller.maxDuration > 0 ? _controller.maxDuration : 1;
        _endMs = _durationMs.toDouble();
        _ready = true;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Waveform could not be loaded: $e');
    }
  }

  Future<void> _togglePlay() async {
    if (!_ready) return;
    if (_playing) {
      await _controller.pausePlayer();
    } else {
      if (_playheadMs >= _endMs || _playheadMs < _startMs) {
        await _controller.seekTo(_startMs.round());
      }
      await _controller.startPlayer();
    }
  }

  String _time(double ms) {
    final seconds = (ms / 1000).floor();
    return (seconds ~/ 60).toString().padLeft(2, '0') + ':' + (seconds % 60).toString().padLeft(2, '0');
  }

  @override
  void dispose() {
    _durationSub?.cancel();
    _stateSub?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final max = _durationMs > 0 ? _durationMs.toDouble() : 1.0;
    final safeStart = _startMs.clamp(0.0, max - 1).toDouble();
    final safeEnd = _endMs.clamp(safeStart + 1, max).toDouble();
    return AlertDialog(
      title: Text('Waveform editor — ' + widget.title),
      content: SizedBox(
        width: 520,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
          if (!_ready && _error == null) const Padding(
            padding: EdgeInsets.all(20), child: CircularProgressIndicator()),
          if (_ready) ...[
            Container(
              height: 110,
              decoration: BoxDecoration(color: const Color(0xFF171B24), borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: wave.AudioFileWaveforms(
                size: Size(MediaQuery.of(context).size.width * 0.72, 90),
                playerController: _controller,
                waveformType: wave.WaveformType.fitWidth,
                enableSeekGesture: true,
                playerWaveStyle: const wave.PlayerWaveStyle(
                  fixedWaveColor: Colors.white38,
                  liveWaveColor: Colors.orangeAccent,
                  seekLineColor: Colors.white,
                  showSeekLine: true,
                  spacing: 3,
                  waveThickness: 2,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('Playhead: ' + _time(_playheadMs.toDouble())),
              Text('Total: ' + _time(max)),
              IconButton(onPressed: _togglePlay,
                icon: Icon(_playing ? Icons.pause_circle : Icons.play_circle), iconSize: 34),
            ]),
            const Align(alignment: Alignment.centerLeft,
              child: Text('Select the portion to keep', style: TextStyle(fontWeight: FontWeight.bold))),
            RangeSlider(
              min: 0, max: max,
              divisions: max > 1 ? max.floor().clamp(1, 1000).toInt() : 1,
              values: RangeValues(safeStart, safeEnd),
              labels: RangeLabels(_time(safeStart), _time(safeEnd)),
              onChanged: (v) => setState(() { _startMs = v.start; _endMs = v.end; }),
            ),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('Start ' + _time(safeStart)), Text('End ' + _time(safeEnd)),
            ]),
            const SizedBox(height: 6),
            const Text('Trim creates a new audio take. Your original recording is kept.',
              style: TextStyle(fontSize: 12, color: Colors.black54)),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _ready && safeEnd > safeStart
            ? () => Navigator.pop(context, (safeStart.round(), safeEnd.round()))
            : null,
          child: const Text('Save trimmed take'),
        ),
      ],
    );
  }
}
