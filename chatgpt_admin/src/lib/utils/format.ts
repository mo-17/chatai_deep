import dayjs from 'dayjs';

export const fmtDate = (s: string) => dayjs(s).format('YYYY-MM-DD HH:mm');

export const fmtNum = (n: number) => n.toLocaleString('zh-CN');

export const fmtTokens = (n: number) =>
  n >= 1e6
    ? (n / 1e6).toFixed(2) + 'M'
    : n >= 1e3
      ? (n / 1e3).toFixed(2) + 'K'
      : String(n);
