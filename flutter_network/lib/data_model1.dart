class DataModel1 {
  int? code;
  Data? data;
  String? msg;

  DataModel1({this.code, this.data, this.msg});

  DataModel1.fromJson(Map<String, dynamic> json) {
    code = json['code'];
    data = json['data'] != null ? Data.fromJson(json['data']) : null;
    msg = json['msg'];
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['code'] = code;
    if (this.data != null) {
      data['data'] = this.data!.toJson();
    }
    data['msg'] = msg;
    return data;
  }
}

class Data {
  int? code;
  String? method;
  JsonParams? jsonParams;

  Data({this.code, this.method, this.jsonParams});

  Data.fromJson(Map<String, dynamic> json) {
    code = json['code'];
    method = json['method'];
    jsonParams = json['jsonParams'] != null
        ? new JsonParams.fromJson(json['jsonParams'])
        : null;
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = new Map<String, dynamic>();
    data['code'] = this.code;
    data['method'] = this.method;
    if (this.jsonParams != null) {
      data['jsonParams'] = this.jsonParams!.toJson();
    }
    return data;
  }
}

class JsonParams {
  String? name;

  JsonParams({this.name});

  JsonParams.fromJson(Map<String, dynamic> json) {
    name = json['name'];
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = new Map<String, dynamic>();
    data['name'] = this.name;
    return data;
  }
}