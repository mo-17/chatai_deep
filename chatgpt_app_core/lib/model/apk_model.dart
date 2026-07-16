///apk更新
class ApkModel {
  String? id;
  String? cid;
  String? versionName;
  String? versionCode;
  String? url;
  String? description;
  bool updateAvailable;
  bool forceUpdate;
  String downloadUrl;
  String storeUrl;
  String sha256;

  ApkModel({
    this.id,
    this.cid,
    this.versionName,
    this.versionCode,
    String? url,
    this.description,
    bool? updateAvailable,
    this.forceUpdate = false,
    String? downloadUrl,
    this.storeUrl = '',
    this.sha256 = '',
  })  : downloadUrl = downloadUrl ?? url ?? '',
        url = downloadUrl ?? url ?? '',
        updateAvailable = updateAvailable ??
            (downloadUrl ?? url ?? storeUrl).trim().isNotEmpty;

  factory ApkModel.fromJson(Map<String, dynamic> json) {
    final legacyUrl = _asString(json['url']);
    final downloadUrl = json.containsKey('downloadUrl')
        ? _asString(json['downloadUrl'])
        : legacyUrl;
    final storeUrl = _asString(json['storeUrl']);
    return ApkModel(
      id: _nullableString(json['id']),
      cid: _nullableString(json['cid']),
      versionName: _nullableString(json['versionName']),
      versionCode: _nullableString(json['versionCode']),
      url: legacyUrl,
      description: _nullableString(json['description']),
      updateAvailable: json['updateAvailable'] is bool
          ? json['updateAvailable'] as bool
          : legacyUrl.isNotEmpty ||
              downloadUrl.isNotEmpty ||
              storeUrl.isNotEmpty,
      forceUpdate: json['forceUpdate'] == true,
      downloadUrl: downloadUrl,
      storeUrl: storeUrl,
      sha256: _asString(json['sha256']),
    );
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['id'] = id;
    data['cid'] = cid;
    data['versionName'] = versionName;
    data['versionCode'] = versionCode;
    data['url'] = url;
    data['description'] = description;
    data['updateAvailable'] = updateAvailable;
    data['forceUpdate'] = forceUpdate;
    data['downloadUrl'] = downloadUrl;
    data['storeUrl'] = storeUrl;
    data['sha256'] = sha256;
    return data;
  }

  static String _asString(Object? value) => value?.toString() ?? '';

  static String? _nullableString(Object? value) => value?.toString();
}
