import 'package:flutter/material.dart';

/// App brand mark. Displays the same PNG that ships as the macOS app icon, so
/// the in-app logo and the Dock/Finder icon stay visually identical.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 32});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/icons/app_logo.png',
      width: size,
      height: size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
    );
  }
}
