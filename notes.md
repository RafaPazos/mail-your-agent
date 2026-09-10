# NOTES

## Tenant Policy Constraints

Three tenant controls shape this design. Each one blocked the deployment before
it was addressed, and each fix is captured in Bicep so it survives
re-provisioning.

### 1. Shared-Key Storage Authentication Is Disabled

`MCAPSGovDeployPolicies` includes `StorageAccount_DisableLocalAuth_Modify`,
which forces `allowSharedKeyAccess` to `false`. The Bicep templates therefore:

- Set `allowSharedKeyAccess` to `false` explicitly and
  `defaultToOAuthAuthentication` to `true`.
- Configure `AzureWebJobsStorage` through account-name and managed-identity
  settings rather than a connection string.
- Omit `WEBSITECONTENTAZUREFILECONNECTIONSTRING` and `WEBSITECONTENTSHARE`.
- Set `functionAppScaleLimit` to 20, as required by the documented
  no-Azure-Files deployment pattern.
- Grant blob, queue, and table data-plane roles to both identities.

| Role | ID |
| ------ | ----- |
| Storage Blob Data Owner | `b7e6dc6d-f1e8-4753-8033-0f276bb0955b` |
| Storage Queue Data Contributor | `974c5e8b-45b9-4653-ba55-5f855dd0fb88` |
| Storage Table Data Contributor | `0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3` |

### 2. Host Storage Requires a User-Assigned Identity

The Logic Apps Standard runtime supports **only** a user-assigned managed
identity for host storage. With a system-assigned identity the host refuses to
start with:

```text
The authentication credential type for the storage account isn't valid.
```

The Logic Apps runtime and the Functions SDK use different setting
conventions, so both are set:

| Setting | Value | Consumer |
| --------- | ------- | ---------- |
| `AzureWebJobsStorage__accountName` | `<storage-account-name>` | Both |
| `AzureWebJobsStorage__credentialType` | `managedIdentity` | Logic Apps runtime |
| `AzureWebJobsStorage__managedIdentityResourceId` | Resource ID of `<host-identity-name>` | Logic Apps runtime |
| `AzureWebJobsStorage__credential` | `managedidentity` | Functions SDK component factory |
| `AzureWebJobsStorage__clientId` | Client ID of `<host-identity-name>` | Functions SDK component factory |
| `AzureWebJobsStorage__blobServiceUri` | Blob endpoint | Both |
| `AzureWebJobsStorage__queueServiceUri` | Queue endpoint | Both |
| `AzureWebJobsStorage__tableServiceUri` | Table endpoint | Both |
| `AzureWebJobsSecretStorageType` | `Files` | Functions host |

`AzureWebJobsSecretStorageType` must be `Files`. The blob-backed secret
repository still demands a storage connection string or SAS, which cannot exist
while shared-key access is disabled, and fails with
`Secret initialization from Blob storage failed`.

`AzureWebJobsStorage__credential` and `AzureWebJobsStorage__clientId` are kept
defensively for the Functions SDK component factory. Adding them alone did not
resolve the startup failure; `Files` secret storage did. Removing them has not
been tested.

The Logic App keeps its system-assigned identity as well. Foundry access, the
API connection access policy, and `connections.json` all resolve to it, so the
site uses identity type `SystemAssigned, UserAssigned`.

### 3. Storage Public Network Access Is Force-Disabled

`MCAPSGovDeployPolicies` also includes a `modify` policy,
`StorageAccount_PublicNetwork_Modify`, that sets `publicNetworkAccess` to
`Disabled` with `bypass: None`. The Logic App host then cannot reach its own
storage, every request returns `503 Function host is not running`, and
Application Insights records `Unexpected HTTP status code 'Forbidden'`.

The policy assignment is scoped above the subscription, so a policy exemption
cannot be created here even with subscription Owner rights. The storage account
therefore carries the documented `SecurityControl=Ignore` tag and sets
`publicNetworkAccess` to `Enabled`. Both are declared in
`infra/modules/resources.bicep`.

### Policy Exemption Tag

Do not apply this exemption preemptively. If an MCAPS policy blocks a required
resource, the documented temporary resource-level exemption is:

- Tag name: `SecurityControl`
- Tag value: `Ignore`
- Apply only to the affected resource or resource group.
- Valid for 14 days, and available once per resource or resource group.

Longer exclusions require the MCAPS Azure Policy Enforcement process. See
[Maintenance](#maintenance) for what this means for this deployment.

## Maintenance

**The `SecurityControl=Ignore` tag expires 14 days after it is applied.** When
it does, `StorageAccount_PublicNetwork_Modify` will disable storage public
network access again and the Logic App will stop working with no other warning
than a `503`.

| Event | Date |
| --- | --- |
| Tag applied to `<storage-account-name>` | 2026-09-09 |
| Tag expires | **2026-09-23** |

Before that date, either:

- Request a permanent exclusion through the MCAPS Azure Policy Enforcement
  process. **This is the chosen path for this deployment.**
- Or move the Logic App onto VNet integration with private endpoints for blob,
  queue, and table. This requires a subnet delegated to
  `Microsoft.Web/serverFarms`, private DNS zones linked before the site is
  wired to the subnet, and `WEBSITE_DNS_SERVER` set to `168.63.129.16`.

Other recurring checks:

- Re-run the health check after any `azd deploy`.
- Confirm the Outlook connection is still authorized if the trigger stops
  firing.
- Reflect any portal edit of the workflow back into
  `src/logic-app/workflows/mail-agent/workflow.json`.

  ## Troubleshooting

| Symptom | Cause | Fix |
| --------- | ------- | ----- |
| `503 Function host is not running` | Storage `publicNetworkAccess` reverted to `Disabled` by policy | Re-apply the `SecurityControl=Ignore` tag, set `publicNetworkAccess` to `Enabled`, restart |
| `403` on the site root | The app is stopped | `az webapp start`; `azd` has left the site stopped after interrupted operations |
| `The authentication credential type for the storage account isn't valid` | Host storage is using the system-assigned identity | Use the user-assigned identity settings listed above |
| `Secret initialization from Blob storage failed` | Blob secret repository needs a key or SAS | Set `AzureWebJobsSecretStorageType` to `Files` |
| `Unexpected HTTP status code 'Forbidden'` at startup | Host cannot reach storage | Check `publicNetworkAccess`, then the data-plane role assignments |
| `Encountered an error (Forbidden) from extensions API` | The host is not running | Resolve the underlying startup error first |
| `InternalSubscriptionIsOverQuotaForSku` | WS1 quota is zero in the region | Deploy to Sweden Central |
| `ConnectionV2KindMismatch` | A V1 connection already exists under that name | Recreate the connection under a new name |
| `This connection is not authenticated` | Outlook OAuth consent is missing | See [Authorize Outlook](#authorize-outlook) |
| Trigger never fires | Connection unauthorized, or the subject lacks the phrase | Check the connection status, then the subject |

Read host startup failures from Application Insights:

```powershell
$appId = az monitor app-insights component show `
  -g <resource-group-name> -a <app-insights-name> --query appId -o tsv

az monitor app-insights query --app $appId --analytics-query `
  "union traces,exceptions | where timestamp > ago(30m) | where severityLevel >= 2 | project timestamp, m=substring(coalesce(outerMessage,message),0,350) | order by timestamp desc | take 10" `
  --query "tables[0].rows" -o json
```