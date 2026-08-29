# D1 — release builds

Notes for the campaign report. What a merchant's release pipeline does to this
SDK, and what survives it.

## Why the dimension exists

The Android SDK returns its outcome across an `Intent`: `PayCrossResult` and its
`Success` / `Failure` / `Cancelled` subclasses, plus the `Recovery` enum, are
parcelled by `PaymentActivity` and unparcelled by `PayCrossContract.parseResult`
in the merchant's process. Only the SDK's own `consumer-rules.pro` keeps those
names through R8:

```proguard
-keep class com.paycross.sdk.PayCrossResult { *; }
-keep class com.paycross.sdk.PayCrossResult$* { *; }
-keep enum com.paycross.sdk.Recovery { *; }
```

If those rules ever stop being applied, R8 renames the classes, the payload
never unmarshals, and the plugin answers `error:resultUnknown` for every
payment — a *correct* answer (`PayCrossPlugin.deliver` checks
`data.hasExtra(EXTRA_RESULT)` and catches whatever `parseResult` throws, and its
message tells the merchant to reconcile) but a useless one. A debug build cannot
show that, because nothing is minified in it.

iOS has no equivalent transformation: the result crosses a Swift call, not a
`Parcelable`. That asymmetry is why the Android half is a live run and the iOS
half is a build.

## What the example now does

`example/android/app/build.gradle.kts` turns on `isMinifyEnabled` and
`isShrinkResources` for `release` and points `proguardFiles` at
`proguard-android-optimize.txt` plus a local `proguard-rules.pro` that is
**deliberately empty**: every rule this build needs comes from the libraries, and
a rule appearing in that file would be a finding to file against the SDK rather
than a line to add.

## Android — the release APK

`flutter build apk --release --dart-define=PAYCROSS_E2E=true`

| build | bytes | |
|---|---|---|
| `app-debug.apk` | 154,241,136 | 147 MiB |
| `app-release.apk` | 48,002,203 | 45.8 MiB |

A 69% drop: R8, resource shrinking, and icon tree-shaking (MaterialIcons-Regular
1,645,184 → 1,420 bytes).

### The keep rules reached the build

From `example/build/app/outputs/mapping/release/mapping.txt`. The classes that
cross the `Intent` map to **themselves**; everything around them is renamed,
which is what proves the rules were applied rather than that R8 did nothing:

```
com.paycross.sdk.PayCrossResult            -> com.paycross.sdk.PayCrossResult:
com.paycross.sdk.PayCrossResult$Success    -> com.paycross.sdk.PayCrossResult$Success:
com.paycross.sdk.PayCrossResult$Failure    -> com.paycross.sdk.PayCrossResult$Failure:
com.paycross.sdk.PayCrossResult$Cancelled  -> com.paycross.sdk.PayCrossResult$Cancelled:
com.paycross.sdk.Recovery                  -> com.paycross.sdk.Recovery:

com.paycross.sdk.PayCrossConfig            -> n5.a:
com.paycross.sdk.PayCrossEnvironment       -> n5.b:
com.paycross.flutter.PayCrossPlugin        -> l5.b:
```

`com.paycross.sdk.PayCrossContract` maps to `R8$$REMOVED$$CLASS$$419`. That is
R8 inlining both of its methods into their call sites in `PayCrossPlugin` —
`createIntent` at the launch (`:163`) and `parseResult` in `deliver` (`:200`) —
which it can do because the class holds no state and is instantiated fresh at
each use. The classes the consumer rules name are the ones that must survive an
`Intent`, and they did.

### The live run

The D0 set, on the release APK, through the runner:

```
--build-id android-0.3.3-release-r8
--evidence-root .../evidence/d1-release-android      run 20260829-174420-android
6 cells, 6 passed, 0 failed, 0 skipped, 0 control checks, aborted: no      exit 0
```

| cell | label | session | txn | txn status | 3DS |
|---|---|---|---|---|---|
| `control` | `result:success:db4e688d-027a-4ea6-9fa7-39be447de68e` | completed | 1 | succeeded | none |
| `frictionless` | `result:success:612bccc9-6c6e-43e0-acdc-1dbfd20dd7ff` | completed | 1 | succeeded | authenticated / frictionless / shifted |
| `challenge_approve` | `result:success:76ba239a-7322-44e1-bf52-1a8de37e06b0` | completed | 1 | succeeded | authenticated / challenge / shifted |
| `challenge_fraud_suspected` | `result:failure:do_not_retry:ac73ebc4-ed03-4f0d-9c8e-ae54d13de8fd` | open | 1 | failed | not_authenticated / challenge / not shifted |
| `challenge_authentication_failed_rearm` | `result:cancelled` (after `rearmed`) | open | 1 | failed | not_authenticated / challenge / not shifted |
| `cancel_mid_challenge` | `result:cancelled` | open | 1 | threeds_challenge_requested | none |

Identical to the debug run, which is the point: **a release build must not change
behaviour, and it did not.** No control check was spent, nothing aborted, and
`report.json` carries no warnings.

**No finding.** The signature D1 exists to catch is `error:resultUnknown` on a
cell that expected a real outcome — the plugin's honest answer when the `Intent`
payload is gone. It appears nowhere. Its narrower cousin, a `result:cancelled`
that `PayCrossContract.parseResult` fell through to, appears only on the two
cells that expect a cancellation. R8 and resource shrinking do not break the
SDK's result contract at 0.3.3.

Both redaction scans over the evidence root print nothing.

## iOS — build only, and why

Flutter refuses **any** non-debug build for the iOS simulator. Re-verified on the
Mac's own Flutter 3.47.0, which is newer than WSL's 3.44.8:

```
packages/flutter_tools/lib/src/build_info.dart:307
  bool get supportsSimulator => isEmulatorBuildMode(mode);
packages/flutter_tools/lib/src/build_info.dart:619-621
  bool isEmulatorBuildMode(BuildMode mode) { return mode == BuildMode.debug; }
packages/flutter_tools/lib/src/commands/build_ios.dart:966
  throwToolExit('${buildInfo.mode.uppercaseName} mode is not supported for simulators.');
```

and confirmed by running it rather than only reading it:

```
$ flutter build ios --simulator --release --dart-define=PAYCROSS_E2E=true
Release mode is not supported for simulators.        # exit 1
```

Profile is refused for the same reason. So the D0 set can only ever execute
against a **debug** iOS binary, and the iOS half of D1 is a build-and-link proof.

### Pod provenance

Both frameworks come from the CocoaPods CDN (`trunk`), not from a local path:

```
PODS:
  - PayCross (0.1.1):
    - PayCrossCore (= 0.1.1)
  - PayCrossCore (0.1.1)
  - paycross_flutter (0.1.0)

SPEC REPOS:
  trunk:
    - PayCross
    - PayCrossCore

SPEC CHECKSUMS:
  Flutter:           71a624a5bc0c04062bf19101d501e466baf2fb47
  PayCross:          50a347660d1f6d9396d37957e2602ed2eb733607
  paycross_flutter:  513c419dc32608c398130e1e7e9aa424df5dec94
  PayCrossCore:      c3f5bb13e56722a543a1166c23d5d217ec64300c

COCOAPODS: 1.17.0
```

### The artifact

`flutter build ios --release --no-codesign --dart-define=PAYCROSS_E2E=true`,
Xcode build 26.5 s:

```
✓ Built build/ios/iphoneos/Runner.app (17.2MB)
```

Both SDK frameworks are embedded and linked into the release binary:

```
Runner.app/Frameworks/
  App.framework  Flutter.framework  PayCross.framework
  PayCrossCore.framework  paycross_flutter.framework

$ otool -L Runner.app/Runner
  @rpath/PayCross.framework/PayCross                   (current version 1.0.0)
  @rpath/PayCrossCore.framework/PayCrossCore           (current version 1.0.0)
  @rpath/paycross_flutter.framework/paycross_flutter   (current version 1.0.0)
  @rpath/Flutter.framework/Flutter                     (current version 0.0.0)
```

So Swift 6 strict concurrency, dead-stripping and the module maps all survive an
optimised whole-module build. That is the whole of what the iOS half proves.

Two build-time notes, neither of them an SDK defect and neither filed:

* **`paycross_flutter` has no Swift Package Manager support.** Flutter warns
  *"This will become an error in a future version of Flutter"*. It is a plugin
  packaging item, not a payment defect, and it belongs to a release-plumbing
  task rather than to D1.
* **`Missing build name (CFBundleShortVersionString)` / `Missing build number
  (CFBundleVersion)`** on the *example*, which is never submitted anywhere.

### Signing on this rig

The Mac has **0 valid codesigning identities** (`security find-identity -v -p
codesigning`). Every device build therefore needs `--no-codesign`, and that
includes `flutter build ios --config-only`, which defaults to a signed device
build and fails with *"No development certificates available to code sign app
for device deployment"* without it.

## The gap, stated plainly

> iOS release behaviour is proven only as far as **building and linking**.
> Flutter refuses any non-debug build for the iOS simulator, so no cell has ever
> executed against an optimised iOS binary. Closing this needs a physical device
> through TestFlight, which the campaign's non-goals put out of scope. The
> Android half — where the real risk lives, because R8 rewrites bytecode and iOS
> has no equivalent transformation of the SDK's Intent payload — **is** fully
> exercised.
