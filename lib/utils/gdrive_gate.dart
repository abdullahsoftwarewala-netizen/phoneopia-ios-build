import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';

/// Legacy compatibility entry point. Google Drive is not required by
/// Phoneopia startup or account setup anymore, so never show an auth gate.
Future<void> ensureGDriveThenGoHome(BuildContext context) async {
  if (!context.mounted || context.read<AppProvider>().isLoggedIn != true) return;
  Navigator.of(context).pushNamedAndRemoveUntil('/home', (_) => false);
}
