import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// A surface tall enough to build every row of the screen under test.
///
/// The default test view is 800x600 and a `ListView` never builds what is
/// below the fold, so `find.text` reports zero matches for a widget that is
/// merely off-screen -- which reads as "the screen does not render it". Home
/// has eight preset tiles; the editor has a 24-line body field above its
/// buttons. Both need this.
///
/// Shared rather than copied: a third screen that needs it imports this file
/// instead of pasting a third copy.
void useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// A surface the size of an ordinary phone, in logical pixels.
///
/// [useTallSurface] is a testing convenience: it builds every row at once so
/// a finder can see them. It is not a size any phone has, so a screen that
/// only works there is a screen nobody can use. This is the width people
/// actually hold, and it is what catches an overflow and a list that cannot
/// be scrolled to the end.
void usePhoneSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}
