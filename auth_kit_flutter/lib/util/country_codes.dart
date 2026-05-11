/// 国际区号条目
class CountryCode {
  final String code; // ISO 3166-1 alpha-2
  final String dialCode; // E.164 前缀
  final String nameZh;
  final String nameEn;
  final String emoji;

  const CountryCode({
    required this.code,
    required this.dialCode,
    required this.nameZh,
    required this.nameEn,
    required this.emoji,
  });

  String get displayLabel => '$emoji  $nameZh ($dialCode)';
}

/// 常用 30 国/地区国际区号列表
const List<CountryCode> supportedCountries = [
  CountryCode(code: 'CN', dialCode: '+86', nameZh: '中国大陆', nameEn: 'China', emoji: '🇨🇳'),
  CountryCode(code: 'US', dialCode: '+1', nameZh: '美国', nameEn: 'United States', emoji: '🇺🇸'),
  CountryCode(code: 'HK', dialCode: '+852', nameZh: '中国香港', nameEn: 'Hong Kong', emoji: '🇭🇰'),
  CountryCode(code: 'TW', dialCode: '+886', nameZh: '中国台湾', nameEn: 'Taiwan', emoji: '🇹🇼'),
  CountryCode(code: 'SG', dialCode: '+65', nameZh: '新加坡', nameEn: 'Singapore', emoji: '🇸🇬'),
  CountryCode(code: 'GB', dialCode: '+44', nameZh: '英国', nameEn: 'United Kingdom', emoji: '🇬🇧'),
  CountryCode(code: 'JP', dialCode: '+81', nameZh: '日本', nameEn: 'Japan', emoji: '🇯🇵'),
  CountryCode(code: 'KR', dialCode: '+82', nameZh: '韩国', nameEn: 'South Korea', emoji: '🇰🇷'),
  CountryCode(code: 'MY', dialCode: '+60', nameZh: '马来西亚', nameEn: 'Malaysia', emoji: '🇲🇾'),
  CountryCode(code: 'ID', dialCode: '+62', nameZh: '印度尼西亚', nameEn: 'Indonesia', emoji: '🇮🇩'),
  CountryCode(code: 'TH', dialCode: '+66', nameZh: '泰国', nameEn: 'Thailand', emoji: '🇹🇭'),
  CountryCode(code: 'IN', dialCode: '+91', nameZh: '印度', nameEn: 'India', emoji: '🇮🇳'),
  CountryCode(code: 'AU', dialCode: '+61', nameZh: '澳大利亚', nameEn: 'Australia', emoji: '🇦🇺'),
  CountryCode(code: 'CA', dialCode: '+1', nameZh: '加拿大', nameEn: 'Canada', emoji: '🇨🇦'),
  CountryCode(code: 'DE', dialCode: '+49', nameZh: '德国', nameEn: 'Germany', emoji: '🇩🇪'),
  CountryCode(code: 'FR', dialCode: '+33', nameZh: '法国', nameEn: 'France', emoji: '🇫🇷'),
  CountryCode(code: 'IT', dialCode: '+39', nameZh: '意大利', nameEn: 'Italy', emoji: '🇮🇹'),
  CountryCode(code: 'RU', dialCode: '+7', nameZh: '俄罗斯', nameEn: 'Russia', emoji: '🇷🇺'),
  CountryCode(code: 'BR', dialCode: '+55', nameZh: '巴西', nameEn: 'Brazil', emoji: '🇧🇷'),
  CountryCode(code: 'VN', dialCode: '+84', nameZh: '越南', nameEn: 'Vietnam', emoji: '🇻🇳'),
  CountryCode(code: 'PH', dialCode: '+63', nameZh: '菲律宾', nameEn: 'Philippines', emoji: '🇵🇭'),
  CountryCode(code: 'AE', dialCode: '+971', nameZh: '阿联酋', nameEn: 'UAE', emoji: '🇦🇪'),
  CountryCode(code: 'SA', dialCode: '+966', nameZh: '沙特阿拉伯', nameEn: 'Saudi Arabia', emoji: '🇸🇦'),
  CountryCode(code: 'NL', dialCode: '+31', nameZh: '荷兰', nameEn: 'Netherlands', emoji: '🇳🇱'),
  CountryCode(code: 'SE', dialCode: '+46', nameZh: '瑞典', nameEn: 'Sweden', emoji: '🇸🇪'),
  CountryCode(code: 'CH', dialCode: '+41', nameZh: '瑞士', nameEn: 'Switzerland', emoji: '🇨🇭'),
  CountryCode(code: 'NZ', dialCode: '+64', nameZh: '新西兰', nameEn: 'New Zealand', emoji: '🇳🇿'),
  CountryCode(code: 'MX', dialCode: '+52', nameZh: '墨西哥', nameEn: 'Mexico', emoji: '🇲🇽'),
  CountryCode(code: 'ES', dialCode: '+34', nameZh: '西班牙', nameEn: 'Spain', emoji: '🇪🇸'),
  CountryCode(code: 'PT', dialCode: '+351', nameZh: '葡萄牙', nameEn: 'Portugal', emoji: '🇵🇹'),
];
