# Utilities

- Use `Logger` and `LogRedactor` for app logging; extend redaction tests for new secret-bearing fields.
- `StockbarRuntimeStorage` owns defaults and writable paths. `StockbarAcceptanceRuntime` and `StockbarProviderAccessPolicy` must fail closed for invalid acceptance settings.
- `ConfigurationManager` stores market-data config under bundle Application Support; broker/Folync credentials use their Keychain stores.
- Follow each utility's existing synchronization. New `@unchecked Sendable` conformances need a justification and the validator allowlist update.
