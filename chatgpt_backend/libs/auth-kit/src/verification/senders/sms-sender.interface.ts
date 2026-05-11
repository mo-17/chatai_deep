/** 短信发送接口，预留后续接入阿里云/腾讯云短信服务 */
export interface ISmsSender {
  send(phoneNumber: string, code: string): Promise<void>;
}
