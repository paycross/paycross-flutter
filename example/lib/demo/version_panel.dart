import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:paycross_flutter/paycross_flutter.dart';

/// The three version strings a support ticket needs.
typedef DemoVersions = ({String demo, String plugin, String nativeSdk});

const DemoVersions unknownVersions = (
  demo: 'unknown',
  plugin: 'unknown',
  nativeSdk: 'unknown',
);

/// Reads the versions off the running app and the linked SDKs.
///
/// `nativeSdkVersion` is null on Android by design -- that SDK declares no
/// version constant -- so "unknown" there is the correct answer and not a
/// failed read. Both are rendered the same way on purpose: a colleague
/// pasting this into a bug report should not have to know the difference.
Future<DemoVersions> platformVersions() async {
  final package = await PackageInfo.fromPlatform();
  final sdk = await PayCross.versionInfo();
  return (
    demo: '${package.version}+${package.buildNumber}',
    plugin: sdk.pluginVersion,
    nativeSdk: sdk.nativeSdkVersion ?? 'unknown',
  );
}

/// Demo, plugin and native SDK versions, side by side.
class VersionPanel extends StatefulWidget {
  const VersionPanel({super.key, this.readVersions = platformVersions});

  final Future<DemoVersions> Function() readVersions;

  @override
  State<VersionPanel> createState() => _VersionPanelState();
}

class _VersionPanelState extends State<VersionPanel> {
  DemoVersions _versions = unknownVersions;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    DemoVersions read;
    try {
      read = await widget.readVersions();
    } catch (_) {
      // A version panel is never worth an unhandled exception: the app is
      // usable without it, and "unknown" is the honest rendering of a read
      // that did not happen.
      read = unknownVersions;
    }
    if (!mounted) return;
    setState(() => _versions = read);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('Demo ${_versions.demo}'),
      Text('Plugin paycross_flutter ${_versions.plugin}'),
      Text('Native SDK ${_versions.nativeSdk}'),
    ],
  );
}
