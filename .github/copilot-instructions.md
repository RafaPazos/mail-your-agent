# Copilot instructions — Logic Mail Receiver

## Current repository state

The solution is implemented and deployed. `infra/` holds the Bicep templates and
`src/logic-app/` holds the Logic Apps Standard workflow project. There is still
no git history and no automated test suite.

Read `README.md` first. It documents the deployed resources, the tenant policy
constraints that shape the design, and a troubleshooting table. Do not fabricate
references to files that do not exist; verify with a directory listing.

## Architecture

A mail-triggered Azure Logic App Standard that proxies questions to a Microsoft
Foundry prompt agent and replies to the original sender:

1. The Office 365 Outlook connector watches an Inbox for subjects containing
   the configured trigger phrase (`MAIL_TRIGGER_PHRASE` app setting).
2. The `mail-agent` workflow re-checks the subject and blocks `RE:` replies so
   the app cannot answer itself in a loop.
3. It calls the existing Foundry project's Responses API at
   `{PROJECT_ENDPOINT}/openai/v1/responses` using `agent_reference`.
4. The Logic App's system-assigned managed identity authenticates with the
   `https://ai.azure.com` audience.
5. The agent's answer is sent back as a reply through Office 365 Outlook.

The Logic App is the orchestrator; the Foundry agent holds no mail logic, and the
mail connector holds no answering logic. Keep that separation when adding code.

Never create or modify a Foundry project, model, or agent. Use the existing
endpoints recorded in `README.md`.

## Layout

- `infra/main.bicep` — subscription-scoped; creates the resource group.
- `infra/modules/resources.bicep` — all workload resources and app settings.
- `infra/modules/foundry-rbac.bicep` — cross-resource-group role assignment.
- `src/logic-app/` — the `azd` service; `workflows/mail-agent/workflow.json` is
  the workflow definition.
- `azure.yaml` — points at `infra/` for provisioning and `src/logic-app` for
  deployment.

## Commands

Verified in this repository:

```powershell
az bicep build --file .\infra\main.bicep --stdout > $null   # compile infra
npx --yes markdownlint-cli2                                  # lint docs
azd provision --no-prompt                                    # infra only
azd deploy --no-prompt                                       # workflow only
azd up                                                       # both
```

There is no test suite, so there is no single-test command. After any
`azd deploy`, run the health check in the README's "Confirm the Host and
Workflow" section. `azd deploy` reporting success does not prove the workflow
was registered.

## Conventions

- Infrastructure and app settings belong in Bicep. Workflow definitions belong
  in `src/logic-app/workflows/`. Portal edits must be exported back into the
  repository.
- No secrets in source, in Bicep parameter files, or in app settings. Use
  managed identity everywhere, and Key Vault references if a secret ever becomes
  unavoidable.
- The storage account must keep `allowSharedKeyAccess: false`. Never reintroduce
  a storage connection string, `WEBSITECONTENTAZUREFILECONNECTIONSTRING`, or
  `WEBSITECONTENTSHARE`.
- Host storage uses the **user-assigned** identity; Foundry and the API
  connection use the **system-assigned** identity. Do not collapse the two.
- Do not remove the `SecurityControl=Ignore` tag or set the storage account's
  `publicNetworkAccess` to `Disabled`. Tenant policy otherwise breaks the host.
  See the README's "Tenant Policy Constraints" section.
- Deploy to Sweden Central. North Europe has zero WS1 quota.
- Destructive actions, such as deleting connections or resource groups, require
  explicit user approval.
