// The account owner supplies a current access token. The test helper never refreshes a host account.
export async function resolveApiKey(provider) {
  if (provider === "openai-codex") return process.env.PI_LIVE_CODEX_ACCESS_TOKEN;
}
