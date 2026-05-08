///apk更新
class ApkModel {
  String? id;
  String? cid;
  String? versionName;
  String? versionCode;
  String? url;
  String? description;

  ApkModel(
      {this.id,
      this.cid,
      this.versionName,
      this.versionCode,
      this.url,
      this.description});

  ApkModel.fromJson(Map<String, dynamic> json) {
    id = json['id'];
    cid = json['cid'];
    versionName = json['versionName'];
    versionCode = json['versionCode'];
    url = json['url'];
    description = json['description'];
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['id'] = id;
    data['cid'] = cid;
    data['versionName'] = versionName;
    data['versionCode'] = versionCode;
    data['url'] = url;
    data['description'] = description;
    return data;
  }
}
