import {
  ArrayMaxSize,
  ArrayMinSize,
  ArrayUnique,
  IsArray,
  IsString,
  Length,
  Matches,
} from 'class-validator';

export class ImportModelsDto {
  @IsString()
  @Matches(/^[a-f0-9]{48}$/)
  previewId: string;

  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(1000)
  @ArrayUnique()
  @IsString({ each: true })
  @Length(1, 255, { each: true })
  modelIds: string[];
}
