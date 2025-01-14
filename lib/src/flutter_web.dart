// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';
import 'dart:typed_data' show Uint8List;

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;

import 'sdk_manager.dart';

Logger _logger = Logger('flutter_web');

/// Handle provisioning package:flutter_web and related work.
class FlutterWebManager {
  final String sdkPath;

  Directory _projectDirectory;

  bool _initedFlutterWeb = false;

  FlutterWebManager(this.sdkPath) {
    _projectDirectory = Directory.systemTemp.createTempSync('dartpad');
    _init();
  }

  void dispose() {
    _projectDirectory.deleteSync(recursive: true);
  }

  Directory get projectDirectory => _projectDirectory;

  String get packagesFilePath => path.join(projectDirectory.path, '.packages');

  void _init() {
    // create a pubspec.yaml file
    String pubspec = createPubspec(false);
    File(path.join(_projectDirectory.path, 'pubspec.yaml'))
        .writeAsStringSync(pubspec);

    // create a .packages file
    final String packagesFileContents = '''
$_samplePackageName:lib/
''';
    File(path.join(_projectDirectory.path, '.packages'))
        .writeAsStringSync(packagesFileContents);

    // and create a lib/ folder for completeness
    Directory(path.join(_projectDirectory.path, 'lib')).createSync();
  }

  Future<void> warmup() async {
    try {
      await initFlutterWeb();
    } catch (e, s) {
      _logger.warning('Error initializing flutter web', e, s);
    }
  }

  Future<void> initFlutterWeb() async {
    if (_initedFlutterWeb) {
      return;
    }

    _logger.info('creating flutter web pubspec');
    String pubspec = createPubspec(true);
    await File(path.join(_projectDirectory.path, 'pubspec.yaml'))
        .writeAsString(pubspec);

    await _runPubGet();

    final String sdkVersion = SdkManager.sdk.version;

    // download and save the flutter_web.sum file
    String url = 'https://storage.googleapis.com/compilation_artifacts/'
        '$sdkVersion/flutter_web.sum';
    Uint8List summaryContents = await http.readBytes(url);
    await File(path.join(_projectDirectory.path, 'flutter_web.sum'))
        .writeAsBytes(summaryContents);

    _initedFlutterWeb = true;
  }

  String get summaryFilePath {
    return path.join(_projectDirectory.path, 'flutter_web.sum');
  }

  static final Set<String> _flutterWebImportPrefixes = <String>{
    'package:flutter_web',
    'package:flutter_web_ui',
    'package:flutter_web_test',
  };

  bool usesFlutterWeb(Set<String> imports) {
    return imports.any((String import) {
      return _flutterWebImportPrefixes.any(
        (String prefix) => import.startsWith(prefix),
      );
    });
  }

  bool hasUnsupportedImport(Set<String> imports) {
    return getUnsupportedImport(imports) != null;
  }

  String getUnsupportedImport(Set<String> imports) {
    // TODO(devoncarew): Should we support a white-listed set of package:
    // imports?

    for (String import in imports) {
      // All dart: imports are ok;
      if (import.startsWith('dart:')) {
        continue;
      }

      // Currently we only allow flutter web imports.
      if (import.startsWith('package:')) {
        if (_flutterWebImportPrefixes
            .any((String prefix) => import.startsWith(prefix))) {
          continue;
        }

        return import;
      }

      // Don't allow file imports.
      return import;
    }

    return null;
  }

  Future<void> _runPubGet() async {
    _logger.info('running pub get (${_projectDirectory.path})');

    ProcessResult result = await Process.run(
      path.join(sdkPath, 'bin', 'pub'),
      <String>['get', '--no-precompile'],
      workingDirectory: _projectDirectory.path,
    );

    _logger.info('${result.stdout}'.trim());

    if (result.exitCode != 0) {
      _logger.warning('pub get failed: ${result.exitCode}');
      _logger.warning(result.stderr);

      throw 'pub get failed: ${result.exitCode}';
    }
  }

  static const String _samplePackageName = 'dartpad_sample';

  static String createPubspec(bool includeFlutterWeb) {
    String content = '''
name: $_samplePackageName
''';

    if (includeFlutterWeb) {
      content += '''
dependencies:
  flutter_web:
    git:
      url: https://github.com/flutter/flutter_web
      path: packages/flutter_web
  flutter_web_test:
    git:
      url: https://github.com/flutter/flutter_web
      path: packages/flutter_web_test
  flutter_web_ui:
    git:
      url: https://github.com/flutter/flutter_web
      path: packages/flutter_web_ui
dependency_overrides:
  flutter_web:
    path: ${Directory.current.path}/flutter_web/packages/flutter_web
  flutter_web_test:
    path: ${Directory.current.path}/flutter_web/packages/flutter_web_test
  flutter_web_ui:
    path: ${Directory.current.path}/flutter_web/packages/flutter_web_ui
''';
    }

    return content;
  }
}
