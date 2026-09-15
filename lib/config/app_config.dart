/// Central API / media / WebSocket URLs for the mobile app.
/// Change [environment] to switch staging ↔ production in one place.
class AppConfig {
  AppConfig._();

  static const AppEnvironment environment = AppEnvironment.production;

  /// Verbose call-lifecycle/ICE logging — temporary diagnostic aid while
  /// investigating call reliability. Safe to leave on in release builds
  /// (debugPrint is a no-op in profile/release unless attached), flip off
  /// once diagnosis is done to cut log noise.
  static const bool CALL_DEBUG_LOGGING = true;

  static String get host => switch (environment) {
    AppEnvironment.staging => 'staging.phoneopia.com',
    AppEnvironment.production => 'phoneopia.com',
  };

  static String get apiBase => 'https://$host/api';
  static String get mediaBase => 'https://$host';

  /// WSS via /realtime/ reverse-proxy — same path the web client uses
  /// (server's .htaccess only proxies /realtime/, NOT /ws/ — that name is
  /// taken by a real on-disk folder, which silently broke every mobile
  /// WebSocket connection attempt until this was caught). Falls back to
  /// direct port only if you set [useDirectWsPort] true for local debugging.
  static const bool useDirectWsPort = false;
  static String get wsUrl => useDirectWsPort
      ? 'ws://$host:8888/'
      : 'wss://$host/realtime/';
}

enum AppEnvironment { staging, production }