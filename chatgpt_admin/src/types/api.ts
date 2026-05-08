export interface ApiResp<T> {
  code: number;
  data: T;
  message?: string;
}

export interface Paged<T> {
  list: T[];
  total: number;
  page: number;
  pageSize: number;
}
