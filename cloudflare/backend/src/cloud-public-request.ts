/** Both Worker and DO fetch must enforce this; no public port/control header authority. */
export function cloudPublicRequest(request: Request): Request {
  const headers = new Headers(request.headers);
  const names: string[] = [];
  headers.forEach((_, name) => names.push(name));
  for (const name of names) {
    const key = name.toLowerCase();
    if (
      key === "cf-container-target-port" ||
      key.startsWith("x-chatai-cloud-") ||
      key.startsWith("x-cloud-workflow-") ||
      [
        "x-original-url",
        "x-rewrite-url",
        "x-forwarded-host",
        "x-forwarded-port",
      ].includes(key)
    )
      headers.delete(name);
  }
  return new Request(request, { headers });
}
