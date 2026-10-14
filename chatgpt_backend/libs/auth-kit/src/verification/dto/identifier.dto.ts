import { Transform } from 'class-transformer';
import { IsIn, IsString, MaxLength } from 'class-validator';
import {
  canonicalIdentifier,
  type CodeChannel,
} from '../verification-contract';

export class AuthIdentifierDto {
  @IsIn(['email', 'sms'])
  channel: CodeChannel;

  @Transform(
    ({ value, obj }: { value: unknown; obj: { channel?: CodeChannel } }) =>
      typeof value === 'string' && ['email', 'sms'].includes(obj.channel ?? '')
        ? canonicalIdentifier(obj.channel!, value)
        : value,
  )
  @IsString()
  @MaxLength(320)
  identifier: string;
}
