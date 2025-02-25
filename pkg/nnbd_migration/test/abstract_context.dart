// Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';

import 'package:analyzer/dart/analysis/analysis_context.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/session.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:analyzer/file_system/overlay_file_system.dart';
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/src/dart/analysis/driver.dart';
import 'package:analyzer/src/dart/analysis/driver_based_analysis_context.dart';
import 'package:analyzer/src/generated/engine.dart' show AnalysisEngine;
import 'package:analyzer/src/generated/source.dart';
import 'package:analyzer/src/test_utilities/mock_sdk.dart';
import 'package:analyzer/src/test_utilities/resource_provider_mixin.dart';

/// TODO(paulberry): this logic is duplicated from other packages.  Find a way
/// share it, or avoid relying on it.
class AbstractContextTest with ResourceProviderMixin {
  OverlayResourceProvider? overlayResourceProvider;

  AnalysisContextCollectionImpl? _analysisContextCollection;
  AnalysisDriver? _driver;

  final Set<String> knownPackages = {};

  /// Whether the test should perform analysis with NNBD enabled.
  ///
  /// `false` by default.  May be overridden in derived test classes.
  bool get analyzeWithNnbd => false;

  AnalysisDriver? get driver {
    if (_driver == null) {
      _createAnalysisContexts();
    }
    return _driver;
  }

  String get homePath => '/home';

  Folder get sdkRoot => newFolder('/sdk');

  AnalysisSession get session => driver!.currentSession;

  String get testsPath => '$homePath/tests';

  /// Makes a mock version of the Angular package available for unit testing.
  ///
  /// If optional argument [internalUris] is `true`, the mock Angular package
  /// will be located in a package called `third_party.dart_src.angular.angular`
  /// (as it is in Google3), and `package:angular` will simply re-export it;
  /// this allows the test to reflect usage in internal sources.
  void addAngularPackage({bool internalUris = false}) {
    addPackageFile(
        internalUris ? 'third_party.dart_src.angular.angular' : 'angular',
        'angular.dart', '''
class ContentChild {
  const ContentChild(Object selector, {Object? read});
}
class ContentChildren {
  const ContentChildren(Object selector, {Object? read});
}
class Optional {
  const Optional();
}
class ViewChild {
  const ViewChild(Object selector, {Object? read});
}
class ViewChildren {
  const ViewChildren(Object selector, {Object? read});
}
''');
    if (internalUris) {
      addPackageFile('angular', 'angular.dart', '''
export 'package:third_party.dart_src.angular.angular/angular.dart';
''');
    }
  }

  void addBuiltValuePackage() {
    addPackageFile('built_value', 'built_value.dart', '''
abstract class Built<V extends Built<V, B>, B extends Builder<V, B>> {}
abstract class Builder<V extends Built<V, B>, B extends Builder<V, B>> {}
const String nullable = 'nullable';
class BuiltValueNullFieldError extends Error {
  static T checkNotNull<T>(T? value, String type, String field) => value!;
}
''');
  }

  void addMetaPackage() {
    addPackageFile('meta', 'meta.dart', r'''
library meta;

const Required required = const Required();

class Required {
  final String reason;
  const Required([this.reason]);
}
''');
  }

  /// Add a new file with the given [pathInLib] to the package with the given
  /// [packageName].  Then ensure that the package under test depends on the
  /// package.
  File addPackageFile(String packageName, String pathInLib, String content) {
    var packagePath = '/.pub-cache/$packageName';
    knownPackages.add(packageName);
    return newFile('$packagePath/lib/$pathInLib', content: content);
  }

  /// Add the quiver package and a library with URI,
  /// "package:quiver/check.dart".
  ///
  /// Then ensure that the package under test depends on the package.
  void addQuiverPackage() {
    addPackageFile('quiver', 'check.dart', r'''
library quiver.check;

T checkNotNull<T>(T reference, {dynamic message}) => T;
''');
  }

  Source addSource(String path, String content, [Uri? uri]) {
    File file = newFile(path, content: content);
    Source source = file.createSource(uri);
    driver!.addFile(file.path);
    driver!.changeFile(file.path);
    return source;
  }

  /// Add the test_core package and a library with URI,
  /// "package:test_core/test_core.dart".
  ///
  /// Then ensure that the package under test depends on the package.
  void addTestCorePackage() {
    addPackageFile('test_core', 'test_core.dart', r'''
library test_core;

void setUp(dynamic callback()) {}
void group(dynamic description, dynamic body()) {}
void test(dynamic description, dynamic body()) {}
''');
    addPackageFile('test', 'test.dart', r'''
library test;
export 'package:test_core/test_core.dart';
''');
  }

  /// Return the existing analysis context that should be used to analyze the
  /// given [path], or throw [StateError] if the [path] is not analyzed in any
  /// of the created analysis contexts.
  AnalysisContext getContext(String path) {
    return _getContext(path);
  }

  /// Return the existing analysis driver that should be used to analyze the
  /// given [path], or throw [StateError] if the [path] is not analyzed in any
  /// of the created analysis contexts.
  AnalysisDriver getDriver(String path) {
    return _getContext(path).driver;
  }

  LineInfo getLineInfo(String path) =>
      (session.getFile(path) as FileResult).lineInfo;

  void setUp() {
    setupResourceProvider();
    overlayResourceProvider = OverlayResourceProvider(resourceProvider);

    createMockSdk(
      resourceProvider: resourceProvider,
      root: sdkRoot,
    );

    newFolder(testsPath);
    newFile('$testsPath/.packages', content: '''
tests:file://$testsPath/lib
''');
    var pubspecPath = '$testsPath/pubspec.yaml';
    // Subclasses may write out a different file first.
    if (!getFile(pubspecPath).exists) {
      newFile(pubspecPath, content: '''
name: tests
version: 1.0.0
environment:
  sdk: '>=2.9.0 <3.0.0'
''');
    }
  }

  void setupResourceProvider() {}

  void tearDown() {
    AnalysisEngine.instance.clearCaches();
  }

  /// Create all analysis contexts in [_homePath].
  void _createAnalysisContexts() {
    var packageConfigJson = {
      'configVersion': 2,
      'packages': [
        for (var packageName in knownPackages)
          {
            'name': packageName,
            'rootUri': toUriStr('/.pub-cache/$packageName'),
            'packageUri': 'lib/',
            'languageVersion': '2.12'
          },
        {
          'name': 'tests',
          'rootUri': '../',
          'packageUri': 'lib/',
          'languageVersion': analyzeWithNnbd ? '2.12' : '2.9'
        }
      ],
      'generated': '2020-10-21T21:13:05.186004Z',
      'generator': 'pub',
      'generatorVersion': '2.10.0'
    };
    newFile('$testsPath/.dart_tool/package_config.json',
        content: JsonEncoder.withIndent('  ').convert(packageConfigJson));
    _analysisContextCollection = AnalysisContextCollectionImpl(
      includedPaths: [convertPath(homePath)],
      enableIndex: true,
      resourceProvider: overlayResourceProvider,
      sdkPath: sdkRoot.path,
    );

    _driver = getDriver(convertPath(testsPath));
  }

  /// Return the existing analysis context that should be used to analyze the
  /// given [path], or throw [StateError] if the [path] is not analyzed in any
  /// of the created analysis contexts.
  DriverBasedAnalysisContext _getContext(String path) {
    if (_analysisContextCollection == null) {
      _createAnalysisContexts();
    }
    path = convertPath(path);
    return _analysisContextCollection!.contextFor(path);
  }
}
