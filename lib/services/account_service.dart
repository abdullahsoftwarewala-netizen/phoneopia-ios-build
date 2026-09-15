import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class StoredAccount {
  final int userId;
  final String token;
  final String displayName;
  final String username;
  final String? avatar;
  final String? phone;
  final Map<String, dynamic> userJson;

  const StoredAccount({
    required this.userId,
    required this.token,
    required this.displayName,
    required this.username,
    this.avatar,
    this.phone,
    required this.userJson,
  });

  factory StoredAccount.fromJson(Map<String, dynamic> j) => StoredAccount(
    userId: int.tryParse(j['user_id']?.toString() ?? '0') ?? 0,
    token: j['token']?.toString() ?? '',
    displayName: j['display_name']?.toString() ?? j['username']?.toString() ?? 'Account',
    username: j['username']?.toString() ?? '',
    avatar: j['avatar']?.toString(),
    phone: j['phone']?.toString(),
    userJson: j['user'] is Map
        ? Map<String, dynamic>.from(j['user'] as Map)
        : <String, dynamic>{},
  );

  Map<String, dynamic> toJson() => {
    'user_id': userId,
    'token': token,
    'display_name': displayName,
    'username': username,
    'avatar': avatar,
    'phone': phone,
    'user': userJson,
  };
}

/// Persists multiple Phoneopia accounts on one device.
class AccountService {
  static const _accountsKey = 'phoneopia_accounts_v1';
  static const _activeKey = 'phoneopia_active_account_id';
  static const _lastUnreadKey = 'phoneopia_account_unread_v1';

  Future<List<StoredAccount>> loadAccounts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_accountsKey);
      if (raw == null || raw.isEmpty) return [];
      final list = jsonDecode(raw);
      if (list is! List) return [];
      return list
          .map((e) => StoredAccount.fromJson(Map<String, dynamic>.from(e as Map)))
          .where((a) => a.userId > 0 && a.token.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<int?> activeUserId() async {
    final prefs = await SharedPreferences.getInstance();
    final id = int.tryParse(prefs.getString(_activeKey) ?? '');
    return id != null && id > 0 ? id : null;
  }

  Future<void> setActiveUserId(int userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeKey, userId.toString());
  }

  Future<void> upsertAccount({
    required String token,
    required Map<String, dynamic> user,
  }) async {
    final id = int.tryParse(user['id']?.toString() ?? '0') ?? 0;
    if (id <= 0 || token.isEmpty) return;
    final accounts = await loadAccounts();
    final entry = StoredAccount(
      userId: id,
      token: token,
      displayName: user['display_name']?.toString() ?? user['username']?.toString() ?? 'Account',
      username: user['username']?.toString() ?? '',
      avatar: user['avatar']?.toString(),
      phone: user['phone']?.toString(),
      userJson: user,
    );
    final idx = accounts.indexWhere((a) => a.userId == id);
    if (idx >= 0) {
      accounts[idx] = entry;
    } else {
      accounts.add(entry);
    }
    await _saveAccounts(accounts);
    await setActiveUserId(id);
  }

  Future<void> removeAccount(int userId) async {
    final accounts = await loadAccounts();
    accounts.removeWhere((a) => a.userId == userId);
    await _saveAccounts(accounts);
    final prefs = await SharedPreferences.getInstance();
    final active = await activeUserId();
    if (active == userId) {
      await prefs.remove(_activeKey);
    }
    await _clearUnreadSnapshot(userId);
  }

  Future<StoredAccount?> accountById(int userId) async {
    for (final a in await loadAccounts()) {
      if (a.userId == userId) return a;
    }
    return null;
  }

  Future<void> _saveAccounts(List<StoredAccount> accounts) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _accountsKey,
      jsonEncode(accounts.map((a) => a.toJson()).toList()),
    );
  }

  Future<Map<String, int>> loadUnreadSnapshots() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_lastUnreadKey);
      if (raw == null) return {};
      final m = jsonDecode(raw);
      if (m is! Map) return {};
      return m.map((k, v) => MapEntry(k.toString(), int.tryParse(v.toString()) ?? 0));
    } catch (_) {
      return {};
    }
  }

  Future<void> saveUnreadSnapshot(int userId, int totalUnread) async {
    final prefs = await SharedPreferences.getInstance();
    final map = await loadUnreadSnapshots();
    map[userId.toString()] = totalUnread;
    await prefs.setString(_lastUnreadKey, jsonEncode(map));
  }

  Future<void> _clearUnreadSnapshot(int userId) async {
    final prefs = await SharedPreferences.getInstance();
    final map = await loadUnreadSnapshots();
    map.remove(userId.toString());
    await prefs.setString(_lastUnreadKey, jsonEncode(map));
  }
}