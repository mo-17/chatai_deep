import 'package:chatgpt_flutter/provider/theme_provider.dart';
import 'package:flutter/material.dart';

const _colorShades = [50, 100, 200, 300, 400, 500, 600, 700, 800, 900];

class ThemeWidget extends StatelessWidget {
  final ValueChanged<String> onThemeChange;

  const ThemeWidget({Key? key, required this.onThemeChange}) : super(key: key);

  get _listView => ListView.builder(
      padding: const EdgeInsets.only(left: 15, right: 15),
      itemCount: ThemeProvider.themes.length,
      itemBuilder: (_, int index) => _itemWidget(ThemeProvider.themes[index]));

  @override
  Widget build(BuildContext context) {
    return Expanded(child: _listView);
  }

  _itemWidget(String colorName) {
    return InkWell(
      onTap: () => onThemeChange(colorName),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: _colorView(colorName),
      ),
    );
  }

  _colorView(String colorName) {
    MaterialColor materialColor = ThemeProvider.getThemeColor(colorName);
    return ClipRRect(
      borderRadius: BorderRadius.circular(5),
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
            gradient: LinearGradient(
                colors: _colorShades.reversed
                    .map((e) => materialColor[e]!)
                    .toList(),
                begin: Alignment.centerLeft,
                end: Alignment.centerRight)),
        height: 80,
        child: Text(
          colorName,
          style: const TextStyle(
              color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}
