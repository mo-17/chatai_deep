import 'package:cached_network_image/cached_network_image.dart';
import 'package:chatgpt_app_core/dao/notice_dao.dart';
import 'package:chatgpt_app_core/model/notice_model.dart';
import 'package:chatgpt_app_core/util/hi_utils.dart';
import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';
import 'package:openai_flutter/utils/ai_logger.dart';

///精彩课程
class StudyPage extends StatefulWidget {
  const StudyPage({Key? key}) : super(key: key);

  @override
  State<StudyPage> createState() => _StudyPageState();
}

class _StudyPageState extends State<StudyPage> {
  List<BannerMo> noticeList = [];

  get _listView => ListView.builder(
      padding: const EdgeInsets.only(left: 5, right: 5),
      itemCount: noticeList.length,
      itemBuilder: (BuildContext context, int index) => _bannerWidget(index));

  get _body => noticeList.isEmpty ? _loading : _listView;

  get _loading => Center(
        child: Lottie.asset("assets/lottie/loading.json.zip", height: 200,
            package: 'chatgpt_app_core',
            errorBuilder: (_, __, ___) =>
                const CircularProgressIndicator()),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('精彩课程'),
      ),
      body: _body,
    );
  }

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  _bannerWidget(int index) {
    BannerMo model = noticeList[index];
    return InkWell(
      onTap: () => HiUtils.openH5(model.url),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Card(
          child: CachedNetworkImage(
            imageUrl: model.cover.isNotEmpty ? model.cover : 'https://o.devio.org/images/bg_cover/robot.webp',
            height: 190,
            fit: BoxFit.cover,
          ),
        ),
      ),
    );
  }

  void _loadData() async {
    var mo = await NoticeDao.noticeList(
        hitCache: (NoticeModel model) => {
              AILogger.log('hiCache:${DateTime.now().millisecondsSinceEpoch}'),
              setState(() {
                noticeList = model.list ?? [];
              })
            });
    setState(() {
      noticeList = mo.list;
    });
  }
}
