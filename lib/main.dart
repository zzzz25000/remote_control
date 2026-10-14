import 'package:flutter/material.dart';

import 'control/remote_controller.dart';
import 'ui/controller_screen.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key, this.controller});
  final RemoteController? controller;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'ROBOT CONTROL',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0288D1)),
      scaffoldBackgroundColor: const Color(0xFFF4F7FB),
      textTheme: ThemeData.light().textTheme.apply(
        bodyColor: const Color(0xFF1E293B),
        displayColor: const Color(0xFF1E293B),
      ),
      sliderTheme: const SliderThemeData(
        trackHeight: 5,
        activeTrackColor: Color(0xFF0288D1),
        thumbColor: Color(0xFF0288D1),
        thumbShape: RoundSliderThumbShape(
          enabledThumbRadius: 7,
          disabledThumbRadius: 7,
          elevation: 0,
          pressedElevation: 0,
        ),
        inactiveTrackColor: Color(0xFFE6EDF5),
      ),
    ),
    home: ControllerScreen(controller: controller),
  );
}
