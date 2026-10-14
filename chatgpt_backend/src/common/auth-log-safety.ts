/** 认证请求日志不保留query、body、原错误或header凭据。 */
export function requestPath(url: string): string {
  return url.split(/[?#]/, 1)[0];
}
export function isAuthPath(url: string): boolean {
  return /^\/(?:uapi|api)\/(?:admin\/)?auth(?:\/|$)/.test(requestPath(url));
}
export function logUrl(url: string): string {
  return isAuthPath(url) ? requestPath(url) : url;
}
