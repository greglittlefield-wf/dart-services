// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// This library is a wrapper around the Dart to JavaScript (dart2js) compiler.
library services.compiler;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bazel_worker/driver.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;

import 'common.dart';
import 'flutter_web.dart';
import 'pub.dart';
import 'sdk_manager.dart';

Logger _logger = Logger('compiler');

/// An interface to the dart2js compiler. A compiler object can process one
/// compile at a time.
class Compiler {
  final String sdkPath;
  final FlutterWebManager flutterWebManager;

  final BazelWorkerDriver _ddcDriver;
  String _sdkVersion;

  Compiler(this.sdkPath, this.flutterWebManager)
      : _ddcDriver = BazelWorkerDriver(
            () => Process.start(path.join(sdkPath, 'bin', 'dartdevc'),
                <String>['--persistent_worker']),
            maxWorkers: 1) {
    _sdkVersion = SdkManager.sdk.version;
  }

  bool importsOkForCompile(Set<String> imports) {
    return !flutterWebManager.hasUnsupportedImport(imports);
  }

  /// The version of the SDK this copy of dart2js is based on.
  String get version {
    return File(path.join(sdkPath, 'version')).readAsStringSync().trim();
  }

  Future<CompilationResults> warmup({bool useHtml = false}) {
    return compile(useHtml ? sampleCodeWeb : sampleCode);
  }

  /// Compile the given string and return the resulting [CompilationResults].
  Future<CompilationResults> compile(
    String input, {
    bool returnSourceMap = false,
  }) async {
    Set<String> imports = getAllImportsFor(input);
    if (!importsOkForCompile(imports)) {
      return CompilationResults(problems: <CompilationProblem>[
        CompilationProblem._(
          'unsupported import: ${flutterWebManager.getUnsupportedImport(imports)}',
        ),
      ]);
    }

    Directory temp = Directory.systemTemp.createTempSync('dartpad');

    try {
      await flutterWebManager.loadDartToolCache();

      List<String> arguments = <String> ['run', 'build_runner',
      'build', '-r', '-o${temp.path}'];
//      if (!returnSourceMap) arguments.add('--no-source-maps');
//      print('The packages are ${flutterWebManager.packagesFilePath}');
//      arguments.add('--packages=${flutterWebManager.packagesFilePath}');
//      arguments.add('-o$kMainDart.js');
//      arguments.add(kMainDart);

      String compileTarget = path.join(flutterWebManager.projectDirectory
          .path, 'web', kMainDart);
      File mainDart = File(compileTarget);
      mainDart.createSync(recursive: true);
      mainDart.writeAsStringSync(input);

      File mainJs = File(path.join(temp.path, 'web', '$kMainDart.js'));
      File mainSourceMap = File(path.join(temp.path, 'web', '$kMainDart.js'
          '.map'));

//      final String dart2JSPath = path.join(sdkPath, 'bin', 'dart2js');

      final String pubPath = path.join(sdkPath, 'bin', 'pub');
      final workingDirectory = flutterWebManager.projectDirectory.path;

      final buildLogger = new Logger(_logger.name + '.build_runner');
      buildLogger.info('Running `$pubPath ${arguments.join(' ')}`'
          ' in $workingDirectory');

      final watch = new Stopwatch()..start();
      final process = await Process.start(pubPath, arguments, workingDirectory:
          workingDirectory);

      final stderr = new StringBuffer();
      process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            buildLogger.warning(line);
            stderr.writeln(line);
      });
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(buildLogger.info);

      watch.stop();

//      ProcessResult result =
//          Process.runSync(dart2JSPath, arguments, workingDirectory: temp.path);

      final exitCode = await process.exitCode;
      buildLogger.info('Exited with code $exitCode');
      buildLogger.info('took ${watch.elapsedMilliseconds}ms');

      if (exitCode != 0) {
        final CompilationResults results =
            CompilationResults(problems: <CompilationProblem>[
          CompilationProblem._(stderr.toString()),
        ]);
        return results;
      } else {
        // Run a second time so to work around https://github.com/dart-lang/build/pull/2436
        Process.runSync(pubPath, arguments, workingDirectory: workingDirectory);

        String sourceMap;
        if (returnSourceMap && mainSourceMap.existsSync()) {
          sourceMap = mainSourceMap.readAsStringSync();
        }
        final CompilationResults results = CompilationResults(
          compiledJS: mainJs.readAsStringSync(),
          sourceMap: sourceMap,
        );

        await flutterWebManager.storeDartToolCache();

        return results;
      }
    } catch (e, st) {
      _logger.warning('Compiler failed: $e\n$st');
      rethrow;
    } finally {
      temp.deleteSync(recursive: true);
      _logger.info('temp folder removed: ${temp.path}');
    }
  }

  /// Compile the given string and return the resulting [DDCCompilationResults].
  Future<DDCCompilationResults> compileDDC(String input) async {
    Set<String> imports = getAllImportsFor(input);
    if (!importsOkForCompile(imports)) {
      return DDCCompilationResults.failed(<CompilationProblem>[
        CompilationProblem._(
          'unsupported import: ${flutterWebManager.getUnsupportedImport(imports)}',
        ),
      ]);
    }

    Directory temp = Directory.systemTemp.createTempSync('dartpad');

    try {
      List<String> arguments = <String>[
        '--modules=amd',
      ];

      if (flutterWebManager.usesFlutterWeb(imports)) {
        arguments.addAll(<String>['-s', flutterWebManager.summaryFilePath]);
      }

      String compileTarget = path.join(temp.path, kMainDart);
      File mainDart = File(compileTarget);
      mainDart.writeAsStringSync(input);

      arguments.addAll(<String>['-o', path.join(temp.path, '$kMainDart.js')]);
      arguments.add('--single-out-file');
      arguments.addAll(<String>['--module-name', 'dartpad_main']);
      arguments.add(compileTarget);
      arguments.addAll(<String>['--library-root', temp.path]);

      File mainJs = File(path.join(temp.path, '$kMainDart.js'));

      _logger.info('About to exec dartdevc with:  $arguments');

      final WorkResponse response =
          await _ddcDriver.doWork(WorkRequest()..arguments.addAll(arguments));

      if (response.exitCode != 0) {
        return DDCCompilationResults.failed(<CompilationProblem>[
          CompilationProblem._(response.output),
        ]);
      } else {
        final DDCCompilationResults results = DDCCompilationResults(
          compiledJS: mainJs.readAsStringSync(),
          modulesBaseUrl: 'https://storage.googleapis.com/'
              'compilation_artifacts/$_sdkVersion/',
        );
        return results;
      }
    } catch (e, st) {
      _logger.warning('Compiler failed: $e\n$st');
      rethrow;
    } finally {
      temp.deleteSync(recursive: true);
      _logger.info('temp folder removed: ${temp.path}');
    }
  }

  Future<void> dispose() => _ddcDriver.terminateWorkers();
}

/// The result of a dart2js compile.
class CompilationResults {
  final String compiledJS;
  final String sourceMap;
  final List<CompilationProblem> problems;

  CompilationResults({
    this.compiledJS,
    this.problems = const <CompilationProblem>[],
    this.sourceMap,
  });

  bool get hasOutput => compiledJS != null && compiledJS.isNotEmpty;

  /// This is true if there were no errors.
  bool get success => problems.isEmpty;

  @override
  String toString() => success
      ? 'CompilationResults: Success'
      : 'Compilation errors: ${problems.join('\n')}';
}

/// The result of a DDC compile.
class DDCCompilationResults {
  final String compiledJS;
  final String modulesBaseUrl;
  final List<CompilationProblem> problems;

  DDCCompilationResults({this.compiledJS, this.modulesBaseUrl})
      : problems = const <CompilationProblem>[];

  DDCCompilationResults.failed(this.problems)
      : compiledJS = null,
        modulesBaseUrl = null;

  bool get hasOutput => compiledJS != null && compiledJS.isNotEmpty;

  /// This is true if there were no errors.
  bool get success => problems.isEmpty;
  @override
  String toString() => success
      ? 'CompilationResults: Success'
      : 'Compilation errors: ${problems.join('\n')}';
}

/// An issue associated with [CompilationResults].
class CompilationProblem implements Comparable<CompilationProblem> {
  final String message;

  CompilationProblem._(this.message);

  @override
  int compareTo(CompilationProblem other) => message.compareTo(other.message);

  @override
  String toString() => message;
}
