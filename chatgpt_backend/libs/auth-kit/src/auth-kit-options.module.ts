import { Module, type DynamicModule, type Provider } from '@nestjs/common';
import { AUTH_KIT_OPTIONS } from './auth-kit.tokens';
@Module({})
export class AuthKitOptionsModule {
  static forRoot(
    imports: NonNullable<DynamicModule['imports']>,
    provider: Provider,
  ): DynamicModule {
    return {
      module: AuthKitOptionsModule,
      imports,
      providers: [provider],
      exports: [AUTH_KIT_OPTIONS],
    };
  }
}
