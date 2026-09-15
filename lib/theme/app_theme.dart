import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Design tokens aligned with web auth — deep red (not candy pink)
class AppColors {
  static const primary       = Color(0xFFFF2D2D);
  static const primaryDark   = Color(0xFFE53935);
  static const primaryDeeper = Color(0xFFD32F2F);
  static const primaryAccent = Color(0xFFFF2D2D);
  static const headerGreen   = Color(0xFFFFFFFF);
  static const headerBorder  = Color(0xFFE9EDEF);
  static const primaryLight  = Color(0xFFD90429);
  static const primaryDim    = Color(0x1AB8002E);

  /// Brighter login/auth gradient — readable white text on top.
  static const brandGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFFFF5A5A), Color(0xFFFF3D3D), Color(0xFFFF2D2D), Color(0xFFE53935)],
    stops: [0.0, 0.35, 0.7, 1.0],
  );

  static const bgLight   = Color(0xFFFFFFFF);
  static const bg2Light  = Color(0xFFFAFAFA);
  static const cardLight = Color(0xFFFFFFFF);
  static const chatBgLight = Color(0xFFFAFAFA);

  static const bgDark    = Color(0xFF0B141A);
  static const bg2Dark   = Color(0xFF111B21);
  static const cardDark  = Color(0xFF1F2C33);
  static const panelDark = Color(0xFF2A3942);

  static const t1Light = Color(0xFF111B21);
  static const t2Light = Color(0xFF3B4A54);
  static const t3Light = Color(0xFF667781);
  static const t4Light = Color(0xFF8696A0);
  static const t1Dark  = Color(0xFFE9EDEF);
  static const t2Dark  = Color(0xFF8696A0);
  static const t3Dark  = Color(0xFF667781);

  static const sentBubbleLight = Color(0xFFFFFFFF);
  static const sentBubbleDark  = Color(0xFF7F1D1D);
  static const recvBubbleLight = Color(0xFFFFFFFF);
  static const recvBubbleDark  = Color(0xFF1F2C33);

  static const borderLight = Color(0xFFD1D7DB);
  static const borderDark  = Color(0xFF2A3942);
  static const dividerLight = Color(0xFFE9EDEF);

  static const online  = Color(0xFFD90429);
  static const away    = Color(0xFFF59E0B);
  static const busy    = Color(0xFFEF4444);
  static const offline = Color(0xFF8696A0);

  static const success = Color(0xFF22C55E);
  static const warning = Color(0xFFF59E0B);
  static const danger  = Color(0xFFEF4444);
  static const info    = Color(0xFF3B82F6);
}

class AppRadii {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double input = 21;
  static const double bubble = 8;
  static const double bubbleTail = 3;
  static const double sheet = 12;
  static const double chip = 8;
  static const double card = 12;
}

class AppShadows {
  static List<BoxShadow> bubble(bool isDark) => [
    BoxShadow(
      color: Colors.black.withOpacity(isDark ? 0.18 : 0.08),
      blurRadius: 0.5,
      offset: const Offset(0, 1),
    ),
  ];

  static List<BoxShadow> card(bool isDark) => [
    BoxShadow(
      color: Colors.black.withOpacity(isDark ? 0.28 : 0.06),
      blurRadius: 8,
      offset: const Offset(0, 2),
    ),
  ];

  static List<BoxShadow> fab() => [
    BoxShadow(
      color: AppColors.primary.withOpacity(0.28),
      blurRadius: 8,
      offset: const Offset(0, 2),
    ),
  ];
}

class AppTheme {
  static ThemeData light() => ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: const ColorScheme.light(
      primary: AppColors.primary,
      secondary: AppColors.primaryDark,
      surface: AppColors.cardLight,
      surfaceContainerHighest: AppColors.bg2Light,
      onPrimary: Colors.white,
      onSurface: AppColors.t1Light,
    ),
    scaffoldBackgroundColor: AppColors.bgLight,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.headerGreen,
      foregroundColor: AppColors.t1Light,
      iconTheme: IconThemeData(color: AppColors.t1Light),
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: TextStyle(
        color: AppColors.t1Light,
        fontSize: 20,
        fontWeight: FontWeight.w700,
      ),
      systemOverlayStyle: SystemUiOverlayStyle(
        statusBarColor: AppColors.headerGreen,
        statusBarIconBrightness: Brightness.dark,
      ),
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: AppColors.cardLight,
      selectedItemColor: AppColors.primary,
      unselectedItemColor: AppColors.t3Light,
      elevation: 0,
    ),
    navigationBarTheme: NavigationBarThemeData(
      elevation: 0,
      height: 64,
      indicatorColor: AppColors.primaryDim,
      backgroundColor: AppColors.cardLight,
      labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
        fontSize: 11,
        fontWeight: states.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w500,
        color: states.contains(WidgetState.selected) ? AppColors.primary : AppColors.t3Light,
      )),
    ),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      minVerticalPadding: 0,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.bg2Light,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.input),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.md)),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        elevation: 0,
      ),
    ),
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.md)),
      elevation: 0,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadii.sheet)),
      ),
      elevation: 0,
    ),
    dividerTheme: const DividerThemeData(
      color: AppColors.dividerLight,
      thickness: 0.5,
      space: 0,
    ),
    textTheme: _textTheme(AppColors.t1Light),
    dividerColor: AppColors.dividerLight,
    fontFamily: 'Inter',
  );

  static ThemeData dark() => ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: const ColorScheme.dark(
      primary: AppColors.primary,
      secondary: AppColors.primaryDark,
      surface: AppColors.cardDark,
      surfaceContainerHighest: AppColors.panelDark,
      onPrimary: Colors.white,
      onSurface: AppColors.t1Dark,
    ),
    scaffoldBackgroundColor: AppColors.bgDark,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.bg2Dark,
      foregroundColor: AppColors.t1Dark,
      elevation: 0,
      scrolledUnderElevation: 0,
      systemOverlayStyle: SystemUiOverlayStyle(
        statusBarColor: AppColors.bg2Dark,
        statusBarIconBrightness: Brightness.light,
      ),
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: AppColors.bg2Dark,
      selectedItemColor: AppColors.primary,
      unselectedItemColor: AppColors.t3Dark,
      elevation: 0,
    ),
    navigationBarTheme: NavigationBarThemeData(
      elevation: 0,
      height: 64,
      indicatorColor: AppColors.primaryDim,
      backgroundColor: AppColors.bg2Dark,
      labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
        fontSize: 11,
        fontWeight: states.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w500,
        color: states.contains(WidgetState.selected) ? AppColors.primary : AppColors.t3Dark,
      )),
    ),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      minVerticalPadding: 0,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.panelDark,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.input),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      hintStyle: const TextStyle(color: AppColors.t3Dark),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.md)),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        elevation: 0,
      ),
    ),
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.md)),
      elevation: 0,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadii.sheet)),
      ),
      elevation: 0,
    ),
    dividerTheme: const DividerThemeData(
      color: AppColors.borderDark,
      thickness: 0.5,
      space: 0,
    ),
    textTheme: _textTheme(AppColors.t1Dark),
    dividerColor: const Color(0x1F8696A0),
    fontFamily: 'Inter',
  );

  static TextTheme _textTheme(Color base) => TextTheme(
    headlineLarge: TextStyle(color: base, fontWeight: FontWeight.w700, fontSize: 24, letterSpacing: -0.5),
    headlineMedium: TextStyle(color: base, fontWeight: FontWeight.w600, fontSize: 20),
    titleLarge: TextStyle(color: base, fontWeight: FontWeight.w600, fontSize: 17),
    titleMedium: TextStyle(color: base, fontWeight: FontWeight.w500, fontSize: 15),
    bodyLarge: TextStyle(color: base, fontSize: 15.5),
    bodyMedium: TextStyle(color: base, fontSize: 14),
    bodySmall: TextStyle(color: base.withOpacity(.65), fontSize: 12.5),
    labelSmall: TextStyle(color: base.withOpacity(.5), fontSize: 11),
  );
}