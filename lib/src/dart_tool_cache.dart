import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dart_services/src/common_server.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;


Logger _logger = Logger('dart_tool_cache');

class DartToolCache {
  final ServerCache cache;

  DartToolCache(this.cache);

  Future<DartToolCacheEntry> get(Digest dependenciesDigest) async {
    final data = await cache.get(dependenciesDigest.toString());
    if (data == null) return null;

    return new DartToolCacheEntry(dependenciesDigest, data);
  }

  Future<void> store(DartToolCacheEntry entry) async {
    await cache.set(entry.key, entry.value);
  }
}

class DartToolCacheEntry {
  final Digest dependenciesDigest;
  final String value;

  String get key => dependenciesDigest.toString();

  DartToolCacheEntry(this.dependenciesDigest, this.value);

  Future<void> extractTo(String dartToolPath) async {
    if (p.basename(dartToolPath) != '.dart_tool') {
      throw new ArgumentError('Must be downloaded to a .dart_tool directory');
    }

    _logger.info('Extracting .dart_tool to $dartToolPath');


    final dartTool = new Directory(dartToolPath);
    if (dartTool.existsSync()) {
      final watch = new Stopwatch();
      await dartTool.delete(recursive: true);
      _logger.info('Deleting old directory took ${watch.elapsedMilliseconds}ms.');
    }
    await dartTool.create(recursive: true);

    Process decompress;
    try {
      decompress = await Process.start('sh', ['-c', 'bzip2 --decompress - | tar -x -f - -C "$dartToolPath"']);
      decompress.stderr.transform(utf8.decoder).transform(new LineSplitter()).listen(_logger.warning);
      decompress.stdin.add(base64Decode(value));
      await decompress.stdin.flush();
      await decompress.stdin.close();
    } catch (e, st) {
//      if (decompress != null) {
//
//      }
      rethrow;
    }
    if (await decompress.exitCode != 0) {
      throw new Exception('Error extracting .dart_tool ${decompress.stderr}');
    }
  }

  static Future<DartToolCacheEntry> from(Digest dependenciesDigest, String dartToolPath) async {
    if (p.basename(dartToolPath) != '.dart_tool') {
      throw new ArgumentError('Must be uploaded from a .dart_tool directory');
    }

    final compressResult = await Process.run('sh', ['-c', 'tar -c -f - -C "$dartToolPath" . | bzip2 -9 -'], stdoutEncoding: null);
    if (compressResult.exitCode != 0) {
      throw new Exception('Error compressing .dart_tool ${compressResult.stderr}');
    }

    return new DartToolCacheEntry(dependenciesDigest, base64Encode(compressResult.stdout as List<int>));
  }
}


Digest digestPubspec(String pubspecYaml) => utf8.encoder.fuse(sha256).convert(pubspecYaml);
