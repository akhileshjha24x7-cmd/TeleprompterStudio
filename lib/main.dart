import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:audio_waveforms/audio_waveforms.dart' as wave;
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
  String? _mergedMp3Path;
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
    final rawLines = _scriptController.text
        .split(RegExp(r'\r?\n'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    // If the pasted script is a numbered list, treat only numbered lines as
    // new items. Wrapped/continued lines belong to the previous numbered item.
    final numberedItem = RegExp(r'^\d{1,3}\s*[.)、:-]\s*\S');
    final numberedLineCount = rawLines.where((line) => numberedItem.hasMatch(line)).length;
    final isNumberedList = rawLines.isNotEmpty &&
        numberedItem.hasMatch(rawLines.first) &&
        numberedLineCount >= 2;

    final List<String> parsed;
    if (isNumberedList) {
      final items = <String>[];
      for (final line in rawLines) {
        if (numberedItem.hasMatch(line) || items.isEmpty) {
          items.add(line);
        } else {
          items[items.length - 1] = '${items.last} ${line}';
        }
      }
      parsed = items;
    } else {
      parsed = rawLines;
    }

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
        _mergedMp3Path = null;
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


  Future<void> _shareMergedMp3() async {
    final path = _mergedMp3Path;
    if (path == null || !await File(path).exists()) {
      if (mounted) setState(() => _status = 'Please merge the takes first.');
      return;
    }
    await SharePlus.instance.share(ShareParams(
      title: 'Teleprompter final audio',
      text: 'Final merged audio',
      files: [XFile(path, mimeType: 'audio/mpeg')],
    ));
  }

  Future<void> _editTake(AudioTake take) async {
    if (_playingPath != null) {
      await _player.stop();
      if (mounted) setState(() => _playingPath = null);
    }
    final edit = await showDialog<_AudioEditCommand>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _AudioEditorDialog(path: take.path, title: take.name),
    );
    if (edit == null) return;

    final source = File(take.path);
    final directory = source.parent;
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final outputPath = directory.path + '/edit_temp_' + stamp.toString() + '.m4a';
    final backupPath = directory.path + '/edit_backup_' + stamp.toString() + '.m4a';
    final startSeconds = (edit.startMs / 1000).toStringAsFixed(3);
    final durationSeconds = ((edit.endMs - edit.startMs) / 1000).toStringAsFixed(3);
    final command = "-ss " + startSeconds + " -i '" + source.path +
        "' -t " + durationSeconds + " -vn -c:a aac -b:a 128k '" + outputPath + "'";

    try {
      if (mounted) setState(() => _status = 'Applying edit to ' + take.name + '…');
      final session = await FFmpegKit.execute(command);
      final code = await session.getReturnCode();
      final output = File(outputPath);
      if (!ReturnCode.isSuccess(code) || !await output.exists() || await output.length() == 0) {
        throw Exception((await session.getOutput()) ?? 'Could not create edited audio.');
      }

      // Swap files using a backup. The take list and its order never change.
      await source.rename(backupPath);
      try {
        await output.rename(source.path);
        await File(backupPath).delete();
      } catch (_) {
        if (await source.exists()) await source.delete();
        await File(backupPath).rename(source.path);
        rethrow;
      }
      if (mounted) {
        setState(() {
          _mergedMp3Path = null;
          _status = take.name + ' updated in place. No new take was added.';
        });
      }
    } catch (e) {
      final temp = File(outputPath);
      if (await temp.exists()) await temp.delete();
      final backup = File(backupPath);
      if (await backup.exists() && !await source.exists()) {
        await backup.rename(source.path);
      }
      if (mounted) setState(() => _status = 'Edit failed; original take was kept. ' + e.toString());
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
        _mergedMp3Path = outputFile.path;
        final bytes = await outputFile.readAsBytes();
        final savedUri = await FilePicker.saveFile(
          dialogTitle: 'Save merged audio',
          fileName: 'teleprompter_export_' + stamp.toString() + '.mp3',
          bytes: bytes,
        );
        if (!mounted) return;
        setState(() => _status = savedUri == null
            ? 'Export cancelled. MP3 remains available in app storage.'
            : 'MP3 saved. You can now share the final audio to WhatsApp.');
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
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete audio take?'),
        content: Text('Delete ' + take.name + '? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    if (_playingPath == take.path) {
      await _player.stop();
      _playingPath = null;
    }
    final file = File(take.path);
    if (await file.exists()) await file.delete();
    if (!mounted) return;
    setState(() {
      _takes.remove(take);
      _mergedMp3Path = null;
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
            if (_mergedMp3Path != null) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _shareMergedMp3,
                  icon: const Icon(Icons.share),
                  label: const Text('Share final merged audio to WhatsApp'),
                ),
              ),
            ],
            const SizedBox(height: 18),
            Row(children: [
              const Expanded(child: Text('2. Audio timeline', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
              Text('${_takes.length} segment(s)', style: const TextStyle(color: Colors.black54)),
            ]),
            const SizedBox(height: 4),
            const Text('Har Take ko Play, Edit ya Delete karein. Drag handle pakadkar order badlein; export isi order mein hoga.',
                style: TextStyle(color: Colors.black54)),
            const SizedBox(height: 8),
            if (_takes.isEmpty)
              const Card(child: Padding(padding: EdgeInsets.all(18), child: Text('No recordings yet. Press Start + Record.')))
            else
              ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                itemCount: _takes.length,
                onReorder: (oldIndex, newIndex) {
                  setState(() {
                    if (newIndex > oldIndex) newIndex -= 1;
                    final item = _takes.removeAt(oldIndex);
                    _takes.insert(newIndex, item);
                    _mergedMp3Path = null;
                    _status = 'Order updated. Export will follow this order.';
                  });
                },
                itemBuilder: (context, index) {
                  final take = _takes[index];
                  final isPlaying = _playingPath == take.path;
                  return Card(
                    key: ValueKey(take.path),
                    margin: const EdgeInsets.symmetric(vertical: 5),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 17,
                            backgroundColor: const Color(0xFFB71C1C),
                            foregroundColor: Colors.white,
                            child: Text((index + 1).toString()),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(take.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                                const SizedBox(height: 3),
                                Text('Drag handle se order badlein', style: TextStyle(fontSize: 11, color: Colors.black54)),
                                const SizedBox(height: 7),
                                Wrap(
                                  spacing: 4,
                                  runSpacing: 2,
                                  children: [
                                    TextButton.icon(
                                      onPressed: () => _playTake(take),
                                      icon: Icon(isPlaying ? Icons.stop : Icons.play_arrow, size: 18),
                                      label: Text(isPlaying ? 'Stop' : 'Play'),
                                    ),
                                    TextButton.icon(
                                      onPressed: () => _editTake(take),
                                      icon: const Icon(Icons.tune, size: 18),
                                      label: const Text('Edit'),
                                    ),
                                    TextButton.icon(
                                      onPressed: () => _deleteTake(take),
                                      style: TextButton.styleFrom(foregroundColor: Colors.red),
                                      icon: const Icon(Icons.delete_outline, size: 18),
                                      label: const Text('Delete'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          ReorderableDragStartListener(
                            index: index,
                            child: const Padding(
                              padding: EdgeInsets.all(10),
                              child: Icon(Icons.drag_handle, size: 28, color: Colors.black54),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            const SizedBox(height: 12),
            const Card(
              child: Padding(
                padding: EdgeInsets.all(14),
                child: Text(
                  'Audio-only recording is available; the camera is never opened. Use Play Silently for text-only playback. Edit changes the selected Take in place; drag Takes into the order you want, then export and share one MP3.',
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


class _AudioEditCommand {
  const _AudioEditCommand({required this.startMs, required this.endMs});
  final int startMs;
  final int endMs;
}

class _AudioEditorDialog extends StatefulWidget {
  const _AudioEditorDialog({required this.path, required this.title});
  final String path;
  final String title;
  @override
  State<_AudioEditorDialog> createState() => _AudioEditorDialogState();
}

class _AudioEditorDialogState extends State<_AudioEditorDialog> {
  late final AudioPlayer _player;
  late final wave.PlayerController _waveController;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration?>? _durationSub;
  StreamSubscription<void>? _completeSub;
  int _durationMs = 0;
  int _positionMs = 0;
  RangeValues _selection = const RangeValues(0, 1);
  bool _ready = false;
  bool _playing = false;
  bool _previewingSelection = false;
  String? _error;

  int get _startMs => (_selection.start * _durationMs).round();
  int get _endMs => (_selection.end * _durationMs).round();

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();
    _waveController = wave.PlayerController();
    _positionSub = _player.onPositionChanged.listen((position) {
      if (!mounted) return;
      final ms = position.inMilliseconds.clamp(0, _durationMs).toInt();
      if (_previewingSelection && ms >= _endMs) {
        _player.pause();
        setState(() {
          _positionMs = _endMs;
          _playing = false;
          _previewingSelection = false;
        });
      } else {
        setState(() => _positionMs = ms);
      }
    });
    _durationSub = _player.onDurationChanged.listen((duration) {
      if (!mounted || _ready) return;
      final ms = duration.inMilliseconds;
      if (ms > 500) {
        setState(() {
          _durationMs = ms;
          _selection = const RangeValues(0, 1);
          _ready = true;
          _error = null;
        });
      }
    });
    _completeSub = _player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playing = false;
          _previewingSelection = false;
        });
      }
    });
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      await _player.setSource(DeviceFileSource(widget.path));
      final duration = await _player.getDuration();
      try {
        await _waveController.preparePlayer(
          path: widget.path,
          shouldExtractWaveform: true,
          noOfSamples: 180,
        );
      } catch (_) {}
      if (!mounted) return;
      final ms = duration?.inMilliseconds ?? 0;
      setState(() {
        _durationMs = ms;
        _selection = const RangeValues(0, 1);
        _ready = ms > 500;
        _error = _ready ? null : 'Audio file could not be loaded.';
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Could not open audio: $e');
      }
    }
  }

  String _time(int ms) {
    final seconds = (ms / 1000).floor();
    return '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  Future<void> _playSelection() async {
    if (!_ready || _endMs - _startMs < 500) return;
    try {
      await _player.stop();
      await _player.seek(Duration(milliseconds: _startMs));
      setState(() {
        _positionMs = _startMs;
        _playing = true;
        _previewingSelection = true;
      });
      await _player.resume();
    } catch (e) {
      if (mounted) {
        setState(() {
          _playing = false;
          _previewingSelection = false;
          _error = 'Preview could not start: $e';
        });
      }
    }
  }

  Future<void> _togglePlay() async {
    if (!_ready) return;
    try {
      if (_playing) {
        await _player.pause();
        if (mounted) {
          setState(() {
            _playing = false;
            _previewingSelection = false;
          });
        }
      } else {
        if (_positionMs >= _durationMs || _positionMs < _startMs || _positionMs >= _endMs) {
          await _player.seek(Duration(milliseconds: _startMs));
          if (mounted) setState(() => _positionMs = _startMs);
        }
        await _player.resume();
        if (mounted) {
          setState(() {
            _playing = true;
            _previewingSelection = true;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Playback failed: $e');
      }
    }
  }

  Future<void> _save() async {
    if (!_ready || _endMs - _startMs < 500) {
      setState(() => _error = 'Select at least half a second to keep.');
      return;
    }
    await _player.stop();
    if (!mounted) return;
    Navigator.pop(context, _AudioEditCommand(startMs: _startMs, endMs: _endMs));
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _durationSub?.cancel();
    _completeSub?.cancel();
    _player.dispose();
    _waveController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width - 64;
    return AlertDialog(
      title: Text('Edit ${widget.title}'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Select the part you want to KEEP. Drag both ends of the selection.',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF171B24),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('WAVEFORM', style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold)),
                        Text(_time(_durationMs), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (_ready)
                      SizedBox(
                        height: 84,
                        width: width,
                        child: wave.AudioFileWaveforms(
                          size: Size(width, 84),
                          playerController: _waveController,
                          waveformType: wave.WaveformType.fitWidth,
                          enableSeekGesture: false,
                          playerWaveStyle: const wave.PlayerWaveStyle(
                            fixedWaveColor: Colors.white38,
                            liveWaveColor: Colors.amber,
                            showSeekLine: false,
                            spacing: 3,
                            waveThickness: 2,
                          ),
                        ),
                      )
                    else
                      const LinearProgressIndicator(),
                    const SizedBox(height: 4),
                    if (_ready)
                      RangeSlider(
                        min: 0,
                        max: 1,
                        divisions: 200,
                        values: _selection,
                        labels: RangeLabels(_time(_startMs), _time(_endMs)),
                        onChanged: (values) {
                          setState(() {
                            _selection = values;
                            _positionMs = _startMs;
                            _playing = false;
                            _previewingSelection = false;
                          });
                        },
                        activeColor: Colors.amber,
                        inactiveColor: Colors.white24,
                      ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('IN  ${_time(_startMs)}', style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold)),
                        Text('OUT  ${_time(_endMs)}', style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton.filledTonal(
                          onPressed: _ready ? _togglePlay : null,
                          icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                          tooltip: _playing ? 'Pause' : 'Play selection',
                        ),
                        const SizedBox(width: 8),
                        Text('${_time(_positionMs)} / ${_time(_durationMs)}',
                          style: const TextStyle(color: Colors.white70)),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _ready ? _playSelection : null,
                icon: const Icon(Icons.hearing),
                label: const Text('Preview selected part'),
              ),
              const SizedBox(height: 8),
              const Text(
                'Save Edit will replace this Take in its current position. It will NOT add another Take. You can still reorder it later.',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton.icon(
          onPressed: _ready ? _save : null,
          icon: const Icon(Icons.save),
          label: const Text('Save Edit'),
        ),
      ],
    );
  }
}
