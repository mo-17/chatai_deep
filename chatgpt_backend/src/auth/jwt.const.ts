export const JWT_SECRET =
  process.env.JWT_SECRET || 'chatgpt-flutter-secret-key';

export interface JwtPayload {
  userId: number;
  userName: string;
  role?: string;
}
