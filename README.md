# Logic Mail Receiver

An Azure Logic App Standard that receives email, forwards the question to an
existing Microsoft Foundry prompt agent, and replies to the original sender.

The Logic App owns all mail orchestration. The Foundry agent contains no mail
logic, and the Outlook connector contains no answering logic.

## Contents

- [Status](#status)
- [Architecture](#architecture)
- [PDF Attachment Support](#pdf-attachment-support)
- [Subject Trigger Filter](#subject-trigger-filter)
- [Existing Foundry Resources](#existing-foundry-resources)
- [Repository Layout](#repository-layout)
- [Prerequisites](#prerequisites)
- [Configure the AZD Environment](#configure-the-azd-environment)
- [Validate Locally](#validate-locally)
- [Deploy](#deploy)
- [Authorize Outlook](#authorize-outlook)
- [End-to-End Verification](#end-to-end-verification)
- [Tenant Policy Constraints](#tenant-policy-constraints)
- [Troubleshooting](#troubleshooting)
- [Maintenance](#maintenance)
- [Create a Receiving Email Address](#create-a-receiving-email-address)
- [Security Notes](#security-notes)

## Architecture

1. The Office 365 Outlook connector monitors the authorized work or school
   account's Inbox for mail whose subject contains the configured trigger
   phrase (`MAIL_TRIGGER_PHRASE` app setting). Attachments are fetched with
   the trigger (`includeAttachments: true`).
2. A stateful Logic Apps Standard workflow re-checks the subject and extracts
   the subject and body.
3. If the mail has a PDF attachment (`contentType` is `application/pdf`; the
   first one is used if there are several, any non-PDF attachments are
   ignored), the workflow sends its bytes to the existing Azure AI Content
   Understanding endpoint's `prebuilt-documentSearch` analyzer
   (asynchronous `analyzeBinary` operation, polled via `Operation-Location`)
   and extracts its text as markdown.
4. The workflow calls the existing Foundry project's OpenAI Responses API at
   `{PROJECT_ENDPOINT}/openai/v1/responses`, passing the agent by
   `agent_reference`. The question sent to the agent includes the subject,
   body, and the PDF's extracted text, if any.
5. The Logic App's system-assigned managed identity authenticates to both
   Foundry (`https://ai.azure.com` audience) and Content Understanding
   (`https://cognitiveservices.azure.com` audience). No key or secret is
   involved.
6. The workflow selects the response element of type `message`, and replies to
   the original message through Office 365 Outlook.

### Workflow Actions

| Action | Type | Purpose |
| -------- | ------ | --------- |
| `When_a_new_email_arrives` | `ApiConnectionNotification` | Trigger, `/v3/Mail/OnNewEmail`, filtered by subject, with attachments |
| `Initialize_pdf_extracted_text` | `InitializeVariable` | Holds the PDF's extracted text, empty if none |
| `Check_subject_prefix` | `If` | Re-checks the subject and blocks reply loops |
| `Filter_pdf_attachments` | `Query` | Keeps only attachments where `contentType` is `application/pdf` |
| `Check_has_pdf_attachment` | `If` | Branches on whether a PDF attachment was found |
| `Analyze_pdf_content` | `Http` | POSTs the first PDF's bytes to Content Understanding (`prebuilt-documentSearch`, async) |
| `Until_pdf_analysis_complete` | `Until` | Polls the analysis operation every 2s, up to 1 minute |
| `Delay_before_poll` | `Wait` | 2-second delay before each poll |
| `Get_pdf_analysis_result` | `Http` | GETs the `Operation-Location` URL to check analysis status |
| `Set_pdf_extracted_text` | `SetVariable` | Stores the analyzer's extracted markdown text, empty on failure/timeout |
| `Call_Foundry_agent` | `Http` | Calls the Responses API with managed identity |
| `Filter_response_messages` | `Query` | Keeps only output items where `type` is `message` |
| `Reply_to_email` | `ApiConnection` | `/v3/Mail/ReplyTo/{messageId}`, HTML-escaped answer |

## PDF Attachment Support

Only PDF attachments (`contentType` is `application/pdf`) are processed. Any
other attachment type is silently ignored, and the workflow proceeds as if no
attachment were present — an email without a PDF, or with only non-PDF
attachments, still gets answered from its subject and body alone.

If more than one PDF is attached, only the first one (as returned by the
Office 365 connector) is used; the others are ignored.

PDF text extraction uses the [Content Understanding REST
API](https://learn.microsoft.com/azure/ai-services/content-understanding/quickstart/use-async-rest-api)'s
asynchronous `prebuilt-documentSearch:analyzeBinary` operation against the
existing Foundry resource's Content Understanding endpoint
(`CONTENT_UNDERSTANDING_ENDPOINT` app setting), using the GA API version
`2025-11-01`. `prebuilt-documentSearch` is a RAG-optimized analyzer (markdown
layout, semantic chunking, summaries) that only supports the async pattern:
the workflow POSTs the PDF bytes, then an `Until` loop polls the
`Operation-Location` URL every 2 seconds (up to 1 minute) until the status is
`Succeeded` or `Failed`. If the analysis fails or times out, the extracted
text is left empty and the agent still answers from the subject/body alone.

## Subject Trigger Filter

The workflow only answers mail whose subject contains the configured trigger
phrase, read from the `MAIL_TRIGGER_PHRASE` app setting (set via
`azd env set MAIL_TRIGGER_PHRASE '<your phrase>'`, see
[Configure the AZD Environment](#configure-the-azd-environment)). This is
enforced at two independent layers.

**Connector layer.** `subjectFilter` is set in the trigger's `fetch.queries`,
so the connector never returns unrelated mail. It is deliberately absent from
`subscribe.queries`: `GraphMailSubscriptionPoke` is a bare notification
endpoint, and an unsupported query parameter there can break subscription
registration.

**Workflow layer.** The `Check_subject_prefix` condition re-evaluates the
subject. It is intentionally case-insensitive, so it can never be stricter than
the connector filter and silently drop legitimate mail.

Trigger-level `conditions` are not used. With `splitOn` present they evaluate
against the batch wrapper, where `triggerBody()?['subject']` does not resolve.

### Loop Protection

A reply keeps the original subject, prefixed with `RE:`. That subject still
contains the trigger phrase, so if a reply ever lands back in the monitored
Inbox it would retrigger the workflow and answer itself indefinitely.

`Check_subject_prefix` therefore also requires that the subject does **not**
start with `re:`:

```json
{
  "and": [
    {
      "contains": [
        "@toLower(coalesce(triggerBody()?['subject'], ''))",
        "@toLower(appsetting('MAIL_TRIGGER_PHRASE'))"
      ]
    },
    {
      "not": {
        "startsWith": [
          "@toLower(trim(coalesce(triggerBody()?['subject'], '')))",
          "re:"
        ]
      }
    }
  ]
}
```

Send the first end-to-end test from a different mailbox than the monitored one.

## Existing Foundry Resources

This project does not create or modify a Foundry project, model, or agent.

| Setting | Value |
| --------- | ------- |
| Project endpoint | `https://<foundry-resource-name>.services.ai.azure.com/api/projects/<foundry-project-name>` |
| OpenAI resource endpoint | `https://<foundry-resource-name>.openai.azure.com/openai/v1` |
| Content Understanding endpoint | `https://<foundry-resource-name>.services.ai.azure.com` |
| Prompt agent | `ms-expert` |
| Token audience (Foundry) | `https://ai.azure.com` |
| Token audience (Content Understanding) | `https://cognitiveservices.azure.com` |
| Foundry resource group | `<foundry-resource-group>` |
| Roles granted to the Logic App | `Foundry User` (`53ca6127-db72-4b80-b1b0-d745d6d5456d`), `Cognitive Services User` (`a97b65f3-24c7-4388-baec-2e87135dc908`) |

The `ms-expert` prompt agent was invoked successfully during preparation. The
initially selected `azure-helper` and `ms-expert-new` agents could not run: both
raise `McpProtocolException` because an MCP tool endpoint configured on them
cannot be resolved from the Foundry network path. That is pre-existing agent
configuration, not a fault in this project.

## Repository Layout

```text
.
|-- .github/
|   `-- copilot-instructions.md
|-- .gitignore
|-- .markdownlint-cli2.jsonc
|-- azure.yaml
|-- infra/
|   |-- main.bicep
|   |-- main.parameters.json
|   `-- modules/
|       |-- foundry-rbac.bicep
|       `-- resources.bicep
`-- src/
    `-- logic-app/
        |-- connections.json
        |-- host.json
        |-- package.json
        |-- package-lock.json
        `-- workflows/
            `-- mail-agent/
                `-- workflow.json
```

`src/logic-app/package.json` carries no dependencies. It exists only because
`azure.yaml` declares the service language as `js`, which makes `azd` expect a
manifest when packaging.

`infra/main.bicep` is subscription-scoped: it creates the resource group and
invokes `modules/resources.bicep`. `modules/foundry-rbac.bicep` exists as a
separate module only because the Foundry account lives in a different resource
group, which Bicep cannot target inline.

Infrastructure and application settings are managed in Bicep. Logic Apps
Standard workflow content is version-controlled under `src/logic-app` and is
ZIP-deployed by `azd`. Portal edits must be exported back into this directory.

## Prerequisites

- Azure CLI with access to subscription
  `<YOUR_SUBSCRIPTION_ID>`.
- Azure Developer CLI (`azd`).
- Node.js, used by `azd` to package the service and to validate JSON locally.
- Permission to create resources and role assignments in:
  - The deployment resource group.
  - `<foundry-resource-group>`, for the Logic App's `Foundry User` and
    `Cognitive Services User` assignments.
- A Microsoft 365 work or school account for the receiving mailbox.

### Region Selection

The deployment region is **Sweden Central**. North Europe cannot be used: the
subscription's WS1 quota there is zero. This surfaces only during ARM preflight
validation as `InternalSubscriptionIsOverQuotaForSku`; the quota CLI returns no
records for `Microsoft.Web`. West Europe also passes preflight, but Sweden
Central was selected because it colocates the workflow with the existing
Foundry resource.

Deployment names cannot be reused across regions. Pass a unique `--name` when
invoking `az deployment sub` directly, or `InvalidDeploymentLocation` is
returned.

## Configure the AZD Environment

The local `dev` environment is already configured. To recreate it:

```powershell
$env:AZURE_DEV_USER_AGENT = 'microsoft_foundry_skill'
azd env new dev --no-prompt
azd env set AZURE_SUBSCRIPTION_ID <YOUR_SUBSCRIPTION_ID>
azd env set AZURE_LOCATION swedencentral
azd env set AZURE_AI_PROJECT_ENDPOINT 'https://<foundry-resource-name>.services.ai.azure.com/api/projects/<foundry-project-name>'
azd env set FOUNDRY_AGENT_NAME ms-expert
azd env set AZURE_FOUNDRY_RESOURCE_GROUP <foundry-resource-group>
azd env set AZURE_FOUNDRY_RESOURCE_NAME <foundry-resource-name>
azd env set MAIL_TRIGGER_PHRASE 'Ask the Agent:'
azd env set CONTENT_UNDERSTANDING_ENDPOINT 'https://<foundry-resource-name>.services.ai.azure.com'
```

`MAIL_TRIGGER_PHRASE` is the subject-line phrase that triggers the workflow.
It is read at runtime via `appsetting('MAIL_TRIGGER_PHRASE')`, so it can be
changed with `azd env set` plus a redeploy of infrastructure — no workflow
code change required.

`.azure/` is gitignored because it contains developer-specific environment
state.

## Validate Locally

Compile the complete Bicep deployment:

```powershell
az bicep build --file .\infra\main.bicep --stdout > $null
```

Validate all generated JSON, including the workflow definition:

```powershell
@(
  '.\infra\main.parameters.json',
  '.\src\logic-app\host.json',
  '.\src\logic-app\connections.json',
  '.\src\logic-app\workflows\mail-agent\workflow.json'
) | ForEach-Object {
  Get-Content -Raw $_ | ConvertFrom-Json > $null
  Write-Host "OK $_"
}
```

Both commands must succeed before deploying.

Lint the documentation. Rules live in `.markdownlint-cli2.jsonc`:

```powershell
npx --yes markdownlint-cli2
```

## Deploy

```powershell
$env:AZURE_DEV_USER_AGENT = 'microsoft_foundry_skill'
azd up
```

Use `azd provision` to apply infrastructure changes only, and `azd deploy` to
push workflow changes only. `azd deploy` completes in well under a minute and
is the fast path when editing `workflow.json`.

> `azd deploy` reporting success does not prove the workflow was registered.
> Always run the health check below afterwards.

### Deployed Resources (`dev`)

| Resource | Name |
| ---------- | ------ |
| Resource group | `<resource-group-name>` (Sweden Central) |
| Logic App Standard | `<app-name>` |
| App Service plan | `<app-service-plan-name>` (WS1) |
| Storage account | `<storage-account-name>` |
| Host storage identity | `<host-identity-name>` (user-assigned) |
| Application Insights | `<app-insights-name>` |
| Log Analytics workspace | `<log-analytics-name>` |
| Outlook connection | `<connection-name>` (V2) |

Endpoint: `https://<app-name>.azurewebsites.net`

### Confirm the Host and Workflow

```powershell
$sub = '<YOUR_SUBSCRIPTION_ID>'
$app = '<app-name>'

Invoke-WebRequest "https://$app.azurewebsites.net/" -UseBasicParsing |
  Select-Object StatusCode

az rest --method get --url "https://management.azure.com/subscriptions/$sub/resourceGroups/<resource-group-name>/providers/Microsoft.Web/sites/$app/hostruntime/runtime/webhooks/workflow/api/management/workflows?api-version=2018-11-01" --query "[].{name:name,health:health.state,disabled:isDisabled}" -o table
```

The site must return `200`, and `mail-agent` must report `Healthy` with
`disabled` false. Anything else is covered in
[Troubleshooting](#troubleshooting).

Note that the ARM `hostruntime/host/workflows` path returns `Not Found` for
Logic Apps Standard. Use the `hostruntime/runtime/webhooks/workflow/...` path
shown above.

### Inspect the Deployed Package

SCM basic authentication is disabled, so Kudu must be called with an Entra
token rather than publishing credentials. This reads the workflow definition as
actually deployed:

```powershell
$app = '<app-name>'
$token = az account get-access-token --resource https://management.azure.com/ --query accessToken -o tsv
Invoke-RestMethod `
  -Uri "https://$app.scm.azurewebsites.net/api/vfs/site/wwwroot/workflows/mail-agent/workflow.json" `
  -Headers @{ Authorization = "Bearer $token" } |
  ConvertTo-Json -Depth 40
```

## Authorize Outlook

Office 365 Outlook uses delegated OAuth. A managed identity cannot replace the
mailbox-user sign-in, so this step is manual and must be repeated if the
authorization is ever revoked.

Managed identity covers only the Logic App to connection hop. That is
configured through a `Microsoft.Web/connections/accessPolicies` child resource
and `"authentication": { "type": "ManagedServiceIdentity" }` in
`connections.json`.

1. Open the `<connection-name>` API connection in the Azure portal.
2. Select **Edit API connection**.
3. Select **Authorize** and sign in with the receiving work or school account.
4. Select **Save**.
5. Confirm the connection status is no longer `Unauthenticated`:

   ```powershell
   az resource show -g <resource-group-name> -n <connection-name> `
     --resource-type Microsoft.Web/connections `
     --query "properties.statuses" -o json
   ```

6. Restart the Logic App once, then re-run the health check in
   [Confirm the Host and Workflow](#confirm-the-host-and-workflow).

### Why the Connection Is Keyless

`listConnectionKeys` requires a `validityTimeSpan` argument, and Azure enforces
a value greater than `01:00:00` and less than `31.00:00:00`. Any connection key
would therefore expire within a month.

The connection is instead created with `kind: 'V2'` and paired with an access
policy granting the Logic App's managed identity. Two constraints follow:

- V1 connections reject access policies with
  `InvalidApiConnectionAccessPolicy`.
- A connection's `kind` cannot be changed from V1 to V2 in place; the attempt
  fails with `ConnectionV2KindMismatch`. The resource must be recreated under a
  new name, which is why the connection is named `office365v2-*`.

The access policy resource name must be computable before deployment starts, so
it is derived with `guid(connection.id, logicApp.id)` rather than from
`logicApp.identity.principalId`, which would raise `BCP120`.

## End-to-End Verification

1. From a **different** mailbox, send an email to the authorized mailbox with a
   subject containing the configured trigger phrase (`MAIL_TRIGGER_PHRASE`)
   followed by the question.
2. Confirm a `mail-agent` workflow run starts.
3. Confirm `Check_subject_prefix` evaluates to true and `Call_Foundry_agent`
   succeeds.
4. Confirm the sender receives a reply containing the `ms-expert` response.
5. Send a second email **without** the phrase and confirm no run and no reply.
6. Confirm the reply itself did not trigger a second run.
7. Send a third email, subject containing the trigger phrase, with a PDF
   attached. Confirm `Filter_pdf_attachments` finds it, `Analyze_pdf_content`
   succeeds, and the agent's reply reflects the PDF's content.
8. Send a fourth email with a non-PDF attachment (for example, a `.docx`) and
   confirm the workflow still answers from the subject and body alone, as if
   no attachment were present.
9. Review any failures in Logic App run history and in Application Insights.

## Create a Receiving Email Address

Choose one of the following, depending on how the mailbox will be used. All
options are performed in the [Microsoft 365 Admin
Center](https://admin.microsoft.com).

Required roles, depending on the operation: Global Administrator, User
Administrator, or Exchange Administrator.

### Option 1: A Mailbox for a New User

1. Navigate to **Users** > **Active users**.
2. Select **Add a user**.
3. Enter the name and username. The username becomes the email address, for
   example `john@yourdomain.com`.
4. Assign an Exchange Online license, such as Microsoft 365 E3, E5, or Business
   Premium.
5. Finish the wizard.

The mailbox is created automatically once the license is assigned.

### Option 2: A Shared Mailbox

Use this for addresses owned by a team, such as `support@` or `info@`.

1. Navigate to **Teams & Groups** > **Shared mailboxes**.
2. Select **Add a shared mailbox**.
3. Enter the display name and email address, for example
   `support@yourdomain.com`.
4. Save, then add the members who need access.

### Option 3: An Alias on an Existing Mailbox

Use this to deliver another address into a mailbox that already exists.

1. Navigate to **Users** > **Active users**.
2. Select the user.
3. Select **Manage username and email**.
4. Add an email alias.

For example, with primary address `rafael@contoso.com` and alias
`sales@contoso.com`, both addresses deliver to the same mailbox.

## Security Notes

- No storage keys, connection keys, or Foundry credentials are stored in source
  control, in Bicep parameter files, or in app settings.
- Storage access uses managed identity with data-plane RBAC only.
- Foundry access uses the system-assigned managed identity with the
  `Foundry User` role, scoped to the single Foundry account.
- PDF text extraction uses the same managed identity with the
  `Cognitive Services User` role, scoped to the same Foundry account's Content
  Understanding endpoint. No PDF content is persisted by the workflow beyond
  the run instance's own execution history.
- The only credential in the system is the delegated Outlook OAuth grant, which
  is held by the API connection resource and never leaves Azure.
