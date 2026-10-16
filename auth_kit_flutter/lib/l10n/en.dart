import 'auth_kit_l10n.dart';

/// English (placeholder)
class En extends AuthKitL10n {
  @override String get loginCodeTab => 'Code Login';
  @override String get loginPasswordTab => 'Password Login';
  @override String get sendCode => 'Send Code';
  @override String get sendingCode => 'Sending';
  @override String get resendCode => 'Resend';
  @override String get codeSent => 'Code Sent';
  @override String get enterCode => 'Enter verification code';
  @override String get codeVerifyLogin => 'Login with Code';
  @override String get passwordLogin => 'Login with Password';
  @override String get register => 'Register';
  @override String get forgotPassword => 'Forgot Password';
  @override String get resetPassword => 'Reset Password';
  @override String get bindIdentity => 'Bind Account';
  @override String get bindIdentityDesc => 'First time using third-party login. Please bind an email or phone number to complete registration.';
  @override String get confirm => 'Confirm';
  @override String get cancel => 'Cancel';
  @override String get appleSignIn => 'Sign in with Apple';
  @override String get huaweiSignIn => 'Sign in with Huawei';
  @override String get huaweiSignInQuick => 'Huawei Quick Login';
  @override String get countryCodePickerTitle => 'Select Country/Region';
  @override String get identifierHint => 'Enter email or phone';
  @override String get passwordHint => 'Enter password';
  @override String get emailHint => 'Enter email address';
  @override String get phoneHint => 'Enter phone number';
}
