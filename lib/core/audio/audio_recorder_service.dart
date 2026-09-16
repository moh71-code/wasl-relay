import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

class AudioRecorderService {
  static final AudioRecorderService _instance =
      AudioRecorderService._internal();
  factory AudioRecorderService() => _instance;
  AudioRecorderService._internal();

  // التحديث للإصدار الحديث باستخدام AudioRecorder
  final AudioRecorder _audioRecorder = AudioRecorder();
  String? _currentFilePath;

  Future<bool> hasPermission() => _audioRecorder.hasPermission();

  Future<String> startRecording({String? fileName}) async {
    final tmp = await getTemporaryDirectory();
    final name =
        fileName ?? 'wasl_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    final path = p.join(tmp.path, name);
    _currentFilePath = path;

    // في الإصدارات الحديثة يتم استخدام RecordConfig لتمرير الإعدادات والترميز
    await _audioRecorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 128000,
        sampleRate: 44100, // المسمى أصبح sampleRate في الإصدار الجديد
      ),
      path: path,
    );
    return path;
  }

  Future<Uint8List?> stopRecording() async {
    try {
      final outPath = await _audioRecorder.stop();
      final filePath = outPath ?? _currentFilePath;
      if (filePath == null) return null;
      final f = File(filePath);
      if (!await f.exists()) return null;
      final bytes = await f.readAsBytes();
      await f.delete();
      _currentFilePath = null;
      return bytes;
    } catch (_) {
      return null;
    }
  }
}
