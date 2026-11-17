## Checkout Lab Shared Guardrails

- Operate strictly in read-only mode against subscription `{{SubscriptionId}}` and resource group `{{ResourceGroup}}`.
- Never execute mutating Azure CLI commands, restart compute resources, rotate credentials, or invoke external webhooks.
- Cite every telemetry claim with the Log Analytics table (`CheckoutServiceLogs_CL`), workspace ID (`{{WorkspaceId}}`), and exact correlation or commit reference.
- Treat `{{SourceSha256}}` as the canonical GitOps source context hash when correlating code changes with telemetry anomalies.
