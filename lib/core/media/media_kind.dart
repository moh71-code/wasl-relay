import 'dart:convert';
import '../l10n/s.dart';

/// Classifies WASL message payloads so audio/images/files are not shown as raw text.
class WaslMedia {
  static String typeFromName(String name) {
    final n = _cleanName(name).toLowerCase();
    if (n.endsWith('.m4a') ||
        n.endsWith('.aac') ||
        n.endsWith('.mp3') ||
        n.endsWith('.wav') ||
        n.contains('voice_')) {
      return 'audio';
    }
    if (n.endsWith('.jpg') ||
        n.endsWith('.jpeg') ||
        n.endsWith('.png') ||
        n.endsWith('.webp') ||
        n.endsWith('.gif')) {
      return 'image';
    }
    return 'file';
  }

  static String typeFromContent(String type, String content) {
    final t = type.trim().toLowerCase();
    if (t == 'audio' || t == 'image' || t == 'file') return t;

    final c = content.trim();
    if (c.startsWith('[audio') || c.startsWith('audio:')) return 'audio';
    if (c.startsWith('[image') || c.startsWith('image:')) return 'image';
    if (c.startsWith('[file') || c.startsWith('file:')) {
      return typeFromName(c);
    }

    try {
      final parsed = jsonDecode(c);
      if (parsed is Map && parsed['kind'] == 'wasl_media') {
        return (parsed['media_type'] as String?) ??
            typeFromName(parsed['name']?.toString() ?? '');
      }
    } catch (_) {}
    return 'text';
  }

  /// Sanitizes a REMOTE-supplied file_id before it is spliced into a disk
  /// path. The id travels over the wire, so a hostile peer could otherwise
  /// smuggle `..` or `/` and write outside the media directory.
  static String safeFileId(String raw) {
    final id = raw.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');
    return id.isEmpty ? 'file' : id;
  }

  /// Sanitizes a sender-supplied filename to a safe basename for on-disk
  /// storage — strips path separators and traversal so a peer can never
  /// escape the app documents directory. The original name is still kept
  /// in message metadata for display.
  static String safeFileName(String raw) {
    var name = raw.split(RegExp(r'[\\/]')).last;
    name = name.replaceAll(RegExp(r'[^\w\.\- ()]'), '_').trim();
    while (name.startsWith('.')) {
      name = name.substring(1);
    }
    if (name.isEmpty) name = 'file';
    return name.length > 100 ? name.substring(0, 100) : name;
  }

  static String displayName(String content, {String? fallback}) {
    fallback ??= S.attachedFile;
    var c = content.trim();
    c = c.replaceAll(RegExp(r'^\[(file|image|audio):?', caseSensitive: false), '');
    c = c.replaceAll(RegExp(r'^(file|image|audio):', caseSensitive: false), '');
    c = c.replaceAll(RegExp(r'\]$'), '');
    return c.trim().isEmpty ? fallback : c.trim();
  }

  static String _cleanName(String name) {
    return name
        .replaceAll('[', '')
        .replaceAll(']', '')
        .split(':')
        .last
        .trim();
  }
}
