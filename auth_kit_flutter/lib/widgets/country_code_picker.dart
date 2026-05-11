import 'package:flutter/material.dart';
import '../util/country_codes.dart';
import '../theme/auth_kit_theme.dart';
import '../l10n/auth_kit_l10n.dart';

/// 国际区号选择器
class CountryCodePicker extends StatelessWidget {
  final CountryCode selected;
  final ValueChanged<CountryCode> onChanged;
  final AuthKitTheme? theme;

  const CountryCodePicker({
    super.key,
    required this.selected,
    required this.onChanged,
    this.theme,
  });

  AuthKitTheme get _theme => theme ?? AuthKitTheme.defaults();

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => _showPicker(context),
      borderRadius: BorderRadius.circular(_theme.borderRadius),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        decoration: BoxDecoration(
          border: Border.all(color: _theme.borderColor),
          borderRadius: BorderRadius.circular(_theme.borderRadius),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(selected.emoji, style: const TextStyle(fontSize: 18)),
            const SizedBox(width: 4),
            Text(selected.dialCode, style: TextStyle(fontSize: 15, color: _theme.textColor)),
            const SizedBox(width: 2),
            Icon(Icons.arrow_drop_down, size: 18, color: _theme.subtitleColor),
          ],
        ),
      ),
    );
  }

  void _showPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (_) => _CountryCodePickerSheet(
        selected: selected,
        onChanged: (cc) {
          onChanged(cc);
          Navigator.pop(context);
        },
        theme: _theme,
      ),
    );
  }
}

class _CountryCodePickerSheet extends StatefulWidget {
  final CountryCode selected;
  final ValueChanged<CountryCode> onChanged;
  final AuthKitTheme theme;

  const _CountryCodePickerSheet({
    required this.selected,
    required this.onChanged,
    required this.theme,
  });

  @override
  State<_CountryCodePickerSheet> createState() => _CountryCodePickerSheetState();
}

class _CountryCodePickerSheetState extends State<_CountryCodePickerSheet> {
  late List<CountryCode> _filtered;

  @override
  void initState() {
    super.initState();
    _filtered = supportedCountries;
  }

  void _search(String q) {
    setState(() {
      _filtered = supportedCountries.where((c) {
        final lower = q.toLowerCase();
        return c.nameZh.contains(lower) ||
            c.nameEn.toLowerCase().contains(lower) ||
            c.dialCode.contains(lower);
      }).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AuthKitL10n.instance;
    return Container(
      height: 400,
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Text(l10n.countryCodePickerTitle, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          TextField(
            decoration: InputDecoration(
              hintText: '搜索',
              prefixIcon: const Icon(Icons.search, size: 20),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onChanged: _search,
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              itemCount: _filtered.length,
              itemBuilder: (_, i) {
                final cc = _filtered[i];
                return ListTile(
                  leading: Text(cc.emoji, style: const TextStyle(fontSize: 22)),
                  title: Text('${cc.nameZh}  ${cc.dialCode}'),
                  subtitle: Text(cc.nameEn, style: const TextStyle(fontSize: 12)),
                  trailing: cc.code == widget.selected.code
                      ? Icon(Icons.check, color: widget.theme.primaryColor)
                      : null,
                  onTap: () => widget.onChanged(cc),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
