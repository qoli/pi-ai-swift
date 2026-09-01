# Custom Provider Runtime

## Current Status

**Landed for static API-key custom providers.**

This is a semantic port of pi upstream's public `createProvider` construction
path. It closes the gap between the bundled provider catalog and requiring a
host to reimplement `ProviderRuntime` from scratch.

## Public construction seam

`CustomProviderRuntime` accepts host-declared `CustomProvider` values and reuses
the same authorization adapter, provider kernel, HTTP transport, and wire
adapters as `BuiltinProviderRuntime`:

```swift
let provider = CustomProvider(
  id: "my-provider",
  name: "My Provider",
  baseURL: URL(string: "https://api.example.com/v1")!,
  api: "openai-completions",
  headers: ["X-Tenant": "example"],
  models: [
    CustomProviderModel(
      id: "my-model-72b",
      capabilities: ProviderCapabilities(
        textInput: true,
        imageInput: false,
        toolCalling: true,
        reasoning: true,
        structuredOutput: true,
        imageGeneration: false
      ),
      contextWindow: 131_072,
      maximumOutputTokens: 8_192
    )
  ]
)

let runtime = try CustomProviderRuntime(
  providers: [provider],
  credentialStore: credentialStore
)
```

The provider-level `api` is the declared default. A model can set its own
`api` to select another existing adapter. This is primary configuration, not a
fallback: an unknown API fails when the runtime is constructed.

Provider and model IDs are established by the declaration. At request time the
kernel still requires the exact `providerID + modelID` pair. It does not infer a
provider from a URL, match a model by display name, or consult the builtin
catalog.

## URL and path ownership

`baseURL` is an API root. The selected wire adapter owns the final path. For
example, an OpenAI Chat Completions provider declared with
`https://api.example.com/v1` sends to
`https://api.example.com/v1/chat/completions`.

Provider- and model-level base URLs are both supported; the model value takes
precedence when present. Provider headers are merged with model headers, with
model values winning on duplicate names. Authentication headers remain owned
by the selected adapter.

The declaration keeps both base URLs optional to match upstream and permit a
host-supplied credential metadata URL. If no source supplies an API root, the
request fails explicitly instead of selecting a default endpoint.

Custom endpoints must use HTTPS. Loopback HTTP is explicitly allowed for local
servers such as Ollama, vLLM, or LM Studio; remote plaintext HTTP is rejected.

## Authentication and storage boundary

Every static custom provider currently exposes the existing `api-key`
authorization method. The key is resolved from the injected
`ProviderCredentialStore`. `CustomProvider` never contains a credential and
the runtime does not select a persistence mechanism.

Consequently this change adds no settings, Keychain, UI, or AIReasoningCore
responsibility. A host can use an in-memory, Keychain, or other conforming store
without changing the provider declaration.

## Compatibility metadata

Model `metadata` is forwarded to the existing adapter. This preserves the
current OpenAI-compatible controls such as `compat.maxTokensField`,
`compat.supportsStore`, and `compat.supportsReasoningEffort` without exposing
the internal kernel or adapters.

## Explicit exclusions

The following upstream behaviors are not part of this static BYOK slice:

- mutable provider registration and deletion after runtime construction;
- dynamic model discovery and filtering;
- host-supplied arbitrary stream implementations;
- custom OAuth factories or provider-specific compound credential forms.

A host with a genuinely new protocol can still implement the public
`ProviderRuntime` protocol. These exclusions must not be implemented as hidden
protocol, endpoint, model, or authentication fallbacks.

## Verification

`CustomProviderRuntimeTests` verifies provider API inheritance, model API
override, exact provider/model catalog projection, API-root path composition,
provider/model headers, injected credentials, compatibility metadata, duplicate
and unknown declarations, loopback HTTP, and rejection of remote HTTP.
It also verifies that a missing API root fails without endpoint fallback.
