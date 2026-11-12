import 'package:shared_preferences/shared_preferences.dart';

const String languageKey = 'paycross_demo_language';

enum DemoLanguage {
  system(null, 'System'),

  english('en', 'English'),

  french('fr', 'French');

  const DemoLanguage(this.tag, this.label);

  final String? tag;

  final String label;

  static DemoLanguage fromName(String? name) =>
      values.firstWhere((l) => l.name == name, orElse: () => system);
}

abstract interface class LanguageBackend {
  Future<String?> read();
  Future<void> write(String value);
}

class SharedPreferencesLanguageBackend implements LanguageBackend {
  const SharedPreferencesLanguageBackend();

  @override
  Future<String?> read() async =>
      (await SharedPreferences.getInstance()).getString(languageKey);

  @override
  Future<void> write(String value) async =>
      (await SharedPreferences.getInstance()).setString(languageKey, value);
}

class InMemoryLanguageBackend implements LanguageBackend {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String written) async => value = written;
}

class LanguageStore {
  const LanguageStore({
    LanguageBackend backend = const SharedPreferencesLanguageBackend(),
  })
    // ignore: prefer_initializing_formals
    : _backend = backend;

  final LanguageBackend _backend;

  Future<DemoLanguage> read() async {
    try {
      return DemoLanguage.fromName(await _backend.read());
    } catch (_) {
      return DemoLanguage.system;
    }
  }

  Future<void> write(DemoLanguage language) => _backend.write(language.name);
}
