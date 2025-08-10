export function parseSafeJson<T = unknown>(str: string): T | undefined {
  try {
    const json = JSON.parse(str);
    return json;
  } catch (e) {
    return undefined;
  }
}
