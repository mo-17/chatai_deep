import { Type } from 'class-transformer';
import { IsArray, IsIn, IsString, ValidateNested } from 'class-validator';

class SavedMessageDto {
  @IsIn(['user', 'assistant'])
  role: 'user' | 'assistant';

  @IsString()
  content: string;
}

export class SaveMessagesDto {
  @IsArray()
  @ValidateNested({ each: true })
  @Type(() => SavedMessageDto)
  messages: SavedMessageDto[];
}
