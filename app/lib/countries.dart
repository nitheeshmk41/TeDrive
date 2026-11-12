// Country calling codes for the sign-in screen. Pure data and helpers, so
// it is unit-testable.

typedef Country = ({String iso, String name, String code, String flag});

Country _c(String iso, String name, String code) => (
  iso: iso,
  name: name,
  code: code,
  // Regional indicator letters form the flag emoji.
  flag: String.fromCharCodes(iso.codeUnits.map((c) => c - 65 + 0x1F1E6)),
);

/// Countries, alphabetical by name.
final List<Country> countries = [
  _c('AF', 'Afghanistan', '93'),
  _c('AL', 'Albania', '355'),
  _c('DZ', 'Algeria', '213'),
  _c('AR', 'Argentina', '54'),
  _c('AM', 'Armenia', '374'),
  _c('AU', 'Australia', '61'),
  _c('AT', 'Austria', '43'),
  _c('AZ', 'Azerbaijan', '994'),
  _c('BH', 'Bahrain', '973'),
  _c('BD', 'Bangladesh', '880'),
  _c('BY', 'Belarus', '375'),
  _c('BE', 'Belgium', '32'),
  _c('BT', 'Bhutan', '975'),
  _c('BO', 'Bolivia', '591'),
  _c('BR', 'Brazil', '55'),
  _c('BG', 'Bulgaria', '359'),
  _c('KH', 'Cambodia', '855'),
  _c('CM', 'Cameroon', '237'),
  _c('CA', 'Canada', '1'),
  _c('CL', 'Chile', '56'),
  _c('CN', 'China', '86'),
  _c('CO', 'Colombia', '57'),
  _c('HR', 'Croatia', '385'),
  _c('CU', 'Cuba', '53'),
  _c('CY', 'Cyprus', '357'),
  _c('CZ', 'Czechia', '420'),
  _c('DK', 'Denmark', '45'),
  _c('EC', 'Ecuador', '593'),
  _c('EG', 'Egypt', '20'),
  _c('EE', 'Estonia', '372'),
  _c('ET', 'Ethiopia', '251'),
  _c('FI', 'Finland', '358'),
  _c('FR', 'France', '33'),
  _c('GE', 'Georgia', '995'),
  _c('DE', 'Germany', '49'),
  _c('GH', 'Ghana', '233'),
  _c('GR', 'Greece', '30'),
  _c('HK', 'Hong Kong', '852'),
  _c('HU', 'Hungary', '36'),
  _c('IS', 'Iceland', '354'),
  _c('IN', 'India', '91'),
  _c('ID', 'Indonesia', '62'),
  _c('IR', 'Iran', '98'),
  _c('IQ', 'Iraq', '964'),
  _c('IE', 'Ireland', '353'),
  _c('IL', 'Israel', '972'),
  _c('IT', 'Italy', '39'),
  _c('JP', 'Japan', '81'),
  _c('JO', 'Jordan', '962'),
  _c('KZ', 'Kazakhstan', '7'),
  _c('KE', 'Kenya', '254'),
  _c('KW', 'Kuwait', '965'),
  _c('KG', 'Kyrgyzstan', '996'),
  _c('LV', 'Latvia', '371'),
  _c('LB', 'Lebanon', '961'),
  _c('LT', 'Lithuania', '370'),
  _c('LU', 'Luxembourg', '352'),
  _c('MY', 'Malaysia', '60'),
  _c('MV', 'Maldives', '960'),
  _c('MX', 'Mexico', '52'),
  _c('MD', 'Moldova', '373'),
  _c('MN', 'Mongolia', '976'),
  _c('MA', 'Morocco', '212'),
  _c('MM', 'Myanmar', '95'),
  _c('NP', 'Nepal', '977'),
  _c('NL', 'Netherlands', '31'),
  _c('NZ', 'New Zealand', '64'),
  _c('NG', 'Nigeria', '234'),
  _c('NO', 'Norway', '47'),
  _c('OM', 'Oman', '968'),
  _c('PK', 'Pakistan', '92'),
  _c('PE', 'Peru', '51'),
  _c('PH', 'Philippines', '63'),
  _c('PL', 'Poland', '48'),
  _c('PT', 'Portugal', '351'),
  _c('QA', 'Qatar', '974'),
  _c('RO', 'Romania', '40'),
  _c('RU', 'Russia', '7'),
  _c('SA', 'Saudi Arabia', '966'),
  _c('RS', 'Serbia', '381'),
  _c('SG', 'Singapore', '65'),
  _c('SK', 'Slovakia', '421'),
  _c('SI', 'Slovenia', '386'),
  _c('ZA', 'South Africa', '27'),
  _c('KR', 'South Korea', '82'),
  _c('ES', 'Spain', '34'),
  _c('LK', 'Sri Lanka', '94'),
  _c('SE', 'Sweden', '46'),
  _c('CH', 'Switzerland', '41'),
  _c('TW', 'Taiwan', '886'),
  _c('TJ', 'Tajikistan', '992'),
  _c('TZ', 'Tanzania', '255'),
  _c('TH', 'Thailand', '66'),
  _c('TR', 'Turkey', '90'),
  _c('TM', 'Turkmenistan', '993'),
  _c('UG', 'Uganda', '256'),
  _c('UA', 'Ukraine', '380'),
  _c('AE', 'United Arab Emirates', '971'),
  _c('GB', 'United Kingdom', '44'),
  _c('US', 'United States', '1'),
  _c('UY', 'Uruguay', '598'),
  _c('UZ', 'Uzbekistan', '998'),
  _c('VE', 'Venezuela', '58'),
  _c('VN', 'Vietnam', '84'),
  _c('YE', 'Yemen', '967'),
  _c('ZM', 'Zambia', '260'),
  _c('ZW', 'Zimbabwe', '263'),
];

/// The country for an ISO code such as "IN", or India if unknown.
Country countryForIso(String? iso) {
  final upper = iso?.toUpperCase();
  return countries.firstWhere(
    (c) => c.iso == upper,
    orElse: () => countries.firstWhere((c) => c.iso == 'IN'),
  );
}

/// Countries whose name, ISO code or calling code matches [query].
List<Country> searchCountries(String query) {
  final q = query.trim().toLowerCase().replaceFirst('+', '');
  if (q.isEmpty) return countries;
  return [
    for (final c in countries)
      if (c.name.toLowerCase().contains(q) ||
          c.iso.toLowerCase() == q ||
          c.code.startsWith(q))
        c,
  ];
}

/// The full number Telegram expects, "+<code><digits>". If the user typed a
/// number starting with + or 00, that already includes a country code and
/// wins over [country]. A leading trunk 0 ("098765...") is dropped.
String fullPhoneNumber(Country country, String typed) {
  final t = typed.trim();
  final digits = t.replaceAll(RegExp(r'[^0-9]'), '');
  if (t.startsWith('+')) return '+$digits';
  if (digits.startsWith('00')) return '+${digits.substring(2)}';
  return '+${country.code}${digits.replaceFirst(RegExp(r'^0+'), '')}';
}
