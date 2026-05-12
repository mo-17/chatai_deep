import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class BotanicalBg extends StatelessWidget {
  final Color primaryColor;

  const BotanicalBg({super.key, required this.primaryColor});

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: 0.75,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(color: const Color(0xFFFAF7F0)),
          SvgPicture.asset(
            'assets/login_bg_botanical.svg',
            package: 'login_sdk',
            colorFilter: ColorFilter.mode(primaryColor, BlendMode.srcIn),
            fit: BoxFit.cover,
          ),
        ],
      ),
    );
  }
}
