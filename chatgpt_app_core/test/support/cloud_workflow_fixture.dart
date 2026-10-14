import 'package:chatgpt_app_core/chat/domain/cloud_workflow.dart';
import 'package:chatgpt_app_core/db/cloud_workflow_dao.dart';
import 'package:chatgpt_app_core/util/uuid_v4.dart';

const cloudFixtureOrigin = 'https://synthetic.invalid';
const cloudFixtureProfile =
    CloudProfileChoice(1, 2, 'synthetic', '合成服务', '合成模型');
CloudConfirmedPayload cloudFixturePayload(CloudSourceSnapshot snapshot,
        {String? key}) =>
    CloudConfirmedPayload(
        key: key ?? generateUuidV4(),
        clientInstanceId: generateUuidV4(),
        source: snapshot.source,
        task: snapshot.task,
        inputs: snapshot.inputs,
        profiles: {for (final r in cloudRoles) r: cloudFixtureProfile});

class CloudFixtureResult {
  final CloudConfirmedPayload payload;
  final String taskId = generateUuidV4(),
      publicationId = generateUuidV4(),
      resultId = generateUuidV4();
  final Map<String, String> steps = {
    for (final r in cloudRoles) r: generateUuidV4()
  };
  CloudFixtureResult(this.payload);
  Map<String, dynamic> receipt({int revision = 4}) => {
        'id': taskId,
        'ownerId': 7,
        'state': 'complete',
        'revision': revision,
        'payloadHash': payload.digest,
        'source': payload.source.toJson(),
        'publicationId': publicationId,
        'finalResultId': resultId
      };
  Map<String, dynamic> detail({int revision = 4, String state = 'complete'}) =>
      {
        'parent': {
          'id': taskId,
          'owner_id': 7,
          'state': state,
          'revision': revision,
          'payload_hash': payload.digest,
          'publication_id': publicationId,
          'final_result_id': resultId,
          'attempts_used': 3,
          'estimated_tokens': 500,
          'payload': payload.toJson()
        },
        'steps': [
          for (final r in cloudRoles)
            {
              'id': steps[r],
              'role': r,
              'revision': 2,
              'result_version': 1,
              'state': 'complete'
            }
        ]
      };
  Map<String, dynamic> result() => {
        'id': resultId,
        'step_id': steps['writing'],
        'version': 1,
        'content': '合成云成果',
        'content_hash': cloudHash('合成云成果'),
        'publication_id': publicationId
      };
  CloudTaskDetail get parsedDetail => CloudTaskDetail.fromJson(detail());
  CloudWritingResult get parsedResult => CloudWritingResult.fromJson(result());
}
