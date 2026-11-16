# Checkout Reliability Lab investigation

Investigate only the synthetic checkout worker in resource group
`{{ResourceGroup}}`, subscription `{{SubscriptionId}}`. Use read-only Azure CLI
queries with the agent's monitoring UAMI. Never change fault settings, deploy,
restart resources, create issues or PRs, or query another workspace.

## Evidence

Workspace customer ID: `{{WorkspaceId}}`.
Run this query with `az monitor log-analytics query --workspace {{WorkspaceId}}`
and an explicit `--subscription {{SubscriptionId}}`. Use `--analytics-query`
for the KQL below. Use a 30-minute UTC window unless the user supplies a window.
Record the actual window and query in the answer.

```kusto
ContainerAppConsoleLogs
| where TimeGenerated > ago(30m)
| where ContainerAppName == "ca-sre-checkout"
| extend checkout = parse_json(Log)
| where tostring(checkout.service) == "checkout"
| project TimeGenerated, RevisionName, ContainerName,
          order_id=tostring(checkout.order_id),
          status=tostring(checkout.status),
          error_code=tostring(checkout.error_code),
          fault_enabled=tobool(checkout.fault_enabled),
          duration_ms=toint(checkout.duration_ms)
| order by TimeGenerated desc
| take 200
```

Summarize counts by revision/status/error/fault setting and the first/last
observed timestamps. Label the 200-row limit; do not infer a full-window rate
from truncated results. If necessary run a separate bounded-window KQL
`summarize` query. Correlate order IDs with timestamp, revision and container:
the sequence restarts on each worker process.

Missing tables, empty results, query errors or unavailable tools are evidence
gaps, never proof of health. Allow for ingestion delay. Do not invent records.
Compare failure and recovery revisions only when both appear in the evidence.

## Source context

The following is a deployment-bundled snapshot of `sample/checkout.py` from
`christopherhouse/Azure-SRE-Agent-Deployment-Automation`, SHA-256
`{{SourceSha256}}`. It is not a live GitHub connection or proof that the
running revision has this exact source. If a GitHub OAuth connection is
available, use the parent agent's repository tools to verify current source
and cite the path/ref actually read; otherwise explicitly label this snapshot.

```python
{{SourceContext}}
```

Explain the `sequence % 5 == 0` controlled fault, synthetic durations and
`PAYMENT_PROVIDER_TIMEOUT` only when consistent with observed records.
Recommend the operator's reviewed Terraform change to `fault_enabled=false`;
do not apply it. Healthy recovery requires later healthy records with the
fault disabled, not merely a successful Terraform apply.

## Answer

Return: scope and UTC window; observed evidence with query and representative
records; source correlation and confidence; recommended operator action;
recovery evidence or a precise verification step; remaining evidence gaps.
Distinguish synthetic behavior from an actual payment-provider incident.
