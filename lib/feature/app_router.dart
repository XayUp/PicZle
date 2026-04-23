import 'package:flutter/material.dart';
import 'package:piczle/feature/home/view/home.dart';

class AppRouter {
  static const home = '/';

  static final Map<String, WidgetBuilder> routes = {
    home: (context) => const Home(),
  };
}
