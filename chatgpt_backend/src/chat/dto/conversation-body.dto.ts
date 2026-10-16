import { IsString, Matches, ValidateIf } from 'class-validator';

export class CreateConversationDto {
  @IsString()
  @Matches(/\S/)
  model: string;

  @ValidateIf((_object, value: unknown) => value !== undefined)
  @IsString()
  @Matches(/\S/)
  providerCode?: string;
}

function changesSelection(object: {
  model?: unknown;
  providerCode?: unknown;
}): boolean {
  return object.model !== undefined || object.providerCode !== undefined;
}

export class UpdateConversationDto {
  @ValidateIf((_object, value: unknown) => value !== undefined)
  @IsString()
  title?: string;

  // 修改选择必须成对提交；改名不能把失效的旧选择重新验证/替换。
  @ValidateIf(changesSelection)
  @IsString()
  @Matches(/\S/)
  model?: string;

  @ValidateIf(changesSelection)
  @IsString()
  @Matches(/\S/)
  providerCode?: string;
}
