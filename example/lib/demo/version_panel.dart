import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:paycross_flutter/paycross_flutter.dart';

typedef DemoVersions = ({String demo, String plugin, String nativeSdk});

const DemoVersions unknownVersions = (
  demo: 'unknown',
  plugin: 'unknown',
  nativeSdk: 'unknown',
);

Future<DemoVersions> platformVersions() async {
  final package = await PackageInfo.fromPlatform();
  final sdk = await PayCross.versionInfo();
  return (
    demo: '${package.version}+${package.buildNumber}',
    plugin: sdk.pluginVersion,
    nativeSdk: sdk.nativeSdkVersion ?? 'unknown',
  );
}

class VersionPanel extends StatefulWidget {
  const VersionPanel({super.key, this.readVersions = platformVersions});

  final Future<DemoVersions> Function() readVersions;

  @override
  State<VersionPanel> createState() => _VersionPanelState();
}

const String _pending = '…';

class _VersionPanelState extends State<VersionPanel> {
  DemoVersions? _versions;

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
      read = unknownVersions;
    }
    if (!mounted) return;
    setState(() => _versions = read);
  }

  @override
  Widget build(BuildContext context) {
    final versions = _versions;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Demo ${versions?.demo ?? _pending}'),
        Text('Plugin paycross_flutter ${versions?.plugin ?? _pending}'),
        Text('Native SDK ${versions?.nativeSdk ?? _pending}'),
      ],
    );
  }
}
