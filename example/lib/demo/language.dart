import 'package:shared_preferences/shared_preferences.dart';

/// Where the chosen language is written.
///
/// Plain `SharedPreferences`, like History and the presets: a language is not
/// a secret, and the secure store is slower and smaller.
const String _languageKey = 'paycross_demo_language';

/// Which language the native payment sheet is pinned to.
///
/// The two the SDKs ship, plus the absence of a choice. This is the demo's
/// side of `PayCross.configure(locale:)` and nothing else: the demo app's own
/// screens stay in English whatever is chosen here, exactly as a merchant
/// app's do.
enum DemoLanguage {
  /// No override at all.
  ///
  /// Not a request for English: it leaves the payment session's own `locale`
  /// to decide, and the shopper's device after that. A demo left here shows
  /// what a merchant who writes no locale code sees.
  system(null, 'System'),

  english('en', 'English'),

  french('fr', 'French');

  const DemoLanguage(this.tag, this.label);

  /// The BCP 47 tag handed to `PayCross.configure`, or null for no override.
  final String? tag;

  /// What the setting reads as on screen.
  final String label;

  /// The choice stored under [name], or [system] for anything else.
  ///
  /// Anything else includes a store written by a build that shipped a
  /// language this one does not, and a hand-edited one. Falling back beats
  /// throwing: this is read at launch, before `runApp`.
  static DemoLanguage fromName(String? name) =>
      values.firstWhere((l) => l.name == name, orElse: () => system);
}

/// The slice of a key-value store the language setting needs.
abstract interface class LanguageBackend {
  Future<String?> read();
  Future<void> write(String value);
}

class SharedPreferencesLanguageBackend implements LanguageBackend {
  const SharedPreferencesLanguageBackend();

  @override
  Future<String?> read() async =>
      (await SharedPreferences.getInstance()).getString(_languageKey);

  @override
  Future<void> write(String value) async =>
      (await SharedPreferences.getInstance()).setString(_languageKey, value);
}

/// A [LanguageBackend] in a field. Tests only.
class InMemoryLanguageBackend implements LanguageBackend {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String written) async => value = written;
}

/// The language the payment sheet is pinned to, across launches.
class LanguageStore {
  const LanguageStore({
    LanguageBackend backend = const SharedPreferencesLanguageBackend(),
  }) // The lint's own fix does not compile: Dart forbids a private NAMED
    // parameter, so `this._backend` cannot appear in a `{...}` list, and a
    // public backend is not what this class is for.
    // ignore: prefer_initializing_formals
    : _backend = backend;

  final LanguageBackend _backend;

  /// The stored choice, or [DemoLanguage.system].
  ///
  /// Guarded, because `main` awaits this before `runApp`: a store that is
  /// unavailable should cost the sheet its override, not the app its launch.
  Future<DemoLanguage> read() async {
    try {
      return DemoLanguage.fromName(await _backend.read());
    } catch (_) {
      return DemoLanguage.system;
    }
  }

  /// Writes the choice, and lets a failure through.
  ///
  /// Unguarded, unlike [read]: the screen that calls this tells the human
  /// whether their choice will survive the next launch, and it cannot say so
  /// honestly if a failed write looks like a successful one.
  Future<void> write(DemoLanguage language) => _backend.write(language.name);
}
