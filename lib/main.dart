import 'package:flutter/material.dart';
import 'package:piczle/feature/app_router.dart';

// Notificador global para o modo de tema
final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.system);

void main() {
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (_, ThemeMode currentMode, __) {
        return MaterialApp(
          routes: AppRouter.routes,
          initialRoute: AppRouter.home,
          debugShowCheckedModeBanner: false,
          themeMode: currentMode,
          theme: ThemeData(useMaterial3: true, brightness: Brightness.light),
          darkTheme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
        );
      },
    );
  }
}
