import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mdslens/i18n/language_document.dart';
import 'package:mdslens/i18n/language_scope.dart';
import 'package:mdslens/i18n/language_service.dart';
import 'package:mdslens/i18n/localized_material.dart';
import 'package:mdslens/services/system_font_service.dart';
import 'package:mdslens/services/user_data_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('language documents normalize locale tags and reject invalid roots', () {
    final language = LanguageDefinition.parse(
      _languageJson('sr_latn_rs', 'Serbian Latin', {'Hello': 'Hello there'}),
      source: 'test.json',
    );
    expect(language.locale, 'sr-Latn-RS');
    expect(language.messages['Hello'], 'Hello there');
    expect(
      () => LanguageDefinition.parse('[]', source: 'invalid.json'),
      throwsFormatException,
    );
  });

  test('bundled Chinese catalog covers English and preserves placeholders',
      () async {
    final english = LanguageDefinition.parse(
      await File('assets/languages/en.json').readAsString(),
      source: 'assets/languages/en.json',
    );
    final chinese = LanguageDefinition.parse(
      await File('assets/languages/zh-Hans.json').readAsString(),
      source: 'assets/languages/zh-Hans.json',
    );

    expect(chinese.locale, 'zh-Hans');
    expect(chinese.messages.keys.toSet(), english.messages.keys.toSet());
    for (final key in english.messages.keys) {
      expect(
        _placeholders(chinese.messages[key]!),
        _placeholders(key),
        reason: key,
      );
    }
  });

  test('system Simplified Chinese selects the bundled Chinese catalog',
      () async {
    final root = await Directory.systemTemp.createTemp('mdslens-language-');
    final service = LanguageService(
      userDataStore: UserDataStore(rootOverride: root),
    );
    addTearDown(() => _disposeLanguageService(service, root));

    await service.initialize(
      systemLocales: const [
        Locale.fromSubtags(
          languageCode: 'zh',
          scriptCode: 'Hans',
          countryCode: 'CN',
        )
      ],
    );

    expect(service.activeLocale, 'zh-Hans');
    expect(service.translate('Settings'), '设置');
    expect(
      service.translate(
        'Loaded: {value1} ({value2} cols, {value3} panels)',
        {'value1': '164000', 'value2': 3, 'value3': 8},
      ),
      '已加载：164000（3 列，8 个面板）',
    );
  });

  test('system language follows locale changes and explicit choice does not',
      () async {
    final root = await Directory.systemTemp.createTemp('mdslens-language-');
    final store = UserDataStore(rootOverride: root);
    final directory = await store.languageDirectory();
    await File('${directory!.path}/en-gb.json').writeAsString(
      _languageJson('en-GB', 'British English', {'Color': 'Colour'}),
    );
    final service = LanguageService(userDataStore: store);
    addTearDown(() => _disposeLanguageService(service, root));

    await service.initialize(systemLocales: const [Locale('en', 'GB')]);
    expect(service.activeLocale, 'en-GB');
    expect(service.translate('Color'), 'Colour');

    service.updateSystemLocales(const [Locale('en', 'US')]);
    expect(service.activeLocale, 'en');
    expect(service.translate('Hello'), 'Hello');

    service.setPreference('en-GB');
    service.updateSystemLocales(const [Locale('en', 'US')]);
    expect(service.activeLocale, 'en-GB');
  });

  test('native language directory hot-adds and hot-removes files', () async {
    final root = await Directory.systemTemp.createTemp('mdslens-language-');
    final store = UserDataStore(rootOverride: root);
    final service = LanguageService(userDataStore: store);
    addTearDown(() => _disposeLanguageService(service, root));
    await service.initialize();
    final directory = await store.languageDirectory();
    final file = File('${directory!.path}/en-gb.json');

    await file.writeAsString(
      _languageJson('en-GB', 'British English', {'Color': 'Colour'}),
      flush: true,
    );
    await _waitUntil(
      () => service.availableLanguages.any((item) => item.locale == 'en-GB'),
    );
    service.setPreference('en-GB');
    expect(service.translate('Color'), 'Colour');

    await file.writeAsString(
      _languageJson('en-GB', 'British English', {'Color': 'British colour'}),
      flush: true,
    );
    await _waitUntil(() => service.translate('Color') == 'British colour');

    await file.delete();
    await _waitUntil(
      () => service.availableLanguages.every((item) => item.locale != 'en-GB'),
    );
    expect(service.activeLocale, 'en');
  });

  test('font catalog refreshes only when the installed family list changes',
      () async {
    var response = <String>['Arial'];
    final catalog = SystemFontCatalog(
      loader: () async => response,
      refreshInterval: Duration.zero,
    );
    addTearDown(catalog.dispose);
    var notifications = 0;
    catalog.addListener(() => notifications++);

    await catalog.start();
    expect(catalog.families, ['Arial']);
    expect(notifications, 1);
    await catalog.refresh();
    expect(notifications, 1);

    response = <String>['Arial', 'Inter'];
    await catalog.refresh();
    expect(catalog.families, ['Arial', 'Inter']);
    expect(notifications, 2);

    response = <String>['Inter'];
    await catalog.refresh();
    expect(catalog.families, ['Inter']);
    expect(notifications, 3);
  });

  testWidgets('localized Text resolves exact and interpolated source keys',
      (tester) async {
    late Directory root;
    late LanguageService service;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('mdslens-language-');
      final store = UserDataStore(rootOverride: root);
      final directory = await store.languageDirectory();
      await File('${directory!.path}/en-gb.json').writeAsString(
        _languageJson('en-GB', 'British English', {
          'Hello': 'Greetings',
          'Loaded {value1} panels': '{value1} panels ready',
        }),
      );
      service = LanguageService(userDataStore: store);
      await service.initialize(preference: 'en-GB');
    });
    addTearDown(() => _disposeLanguageService(service, root));

    await tester.pumpWidget(
      LanguageScope(
        notifier: service,
        child: const MaterialApp(
          home: Column(
            children: [
              Text('Hello'),
              Text('Loaded 3 panels'),
            ],
          ),
        ),
      ),
    );
    expect(find.text('Greetings'), findsOneWidget);
    expect(find.text('3 panels ready'), findsOneWidget);
  });
}

String _languageJson(
  String locale,
  String nativeName,
  Map<String, String> messages,
) =>
    '''
{
  "version": 1,
  "locale": "$locale",
  "name": "$nativeName",
  "nativeName": "$nativeName",
  "messages": ${_jsonMessages(messages)}
}
''';

String _jsonMessages(Map<String, String> messages) {
  String escape(String value) => value
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('\n', r'\n');
  return '{${messages.entries.map((entry) => '"${escape(entry.key)}":'
      '"${escape(entry.value)}"').join(',')}}';
}

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for the watched language directory to refresh.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
}

List<String> _placeholders(String value) => RegExp(r'\{[A-Za-z0-9_]+\}')
    .allMatches(value)
    .map((match) => match.group(0)!)
    .toList(growable: false)
  ..sort();

Future<void> _disposeLanguageService(
  LanguageService service,
  Directory root,
) async {
  service.dispose();
  Object? lastError;
  for (var attempt = 0; attempt < 20; attempt++) {
    try {
      await root.delete(recursive: true);
      return;
    } catch (error) {
      lastError = error;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
  throw lastError!;
}
