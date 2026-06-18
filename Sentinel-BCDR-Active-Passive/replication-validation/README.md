# BCDR replication validation

> [!WARNING]
> **This is a personal project — not an official Microsoft product**, and is not affiliated with, endorsed by, or supported by Microsoft.
>
> It runs against **production security data** and deploys billable resources (a Logic App playbook and a Microsoft Sentinel analytic rule, plus Spark notebook-job compute). **You are solely responsible for all costs incurred.** Test in a non-production workspace first. Provided **"AS IS", without warranty of any kind**.

Automatically validates the cross-region log replication performed by the
[Sentinel BCDR Active/Passive ADF deployment](../README.md). Once a day it counts every
table's events for the **full previous 24 h** in the **primary Sentinel workspace** and in the
**federated Delta tables** (the ADF output), compares them, records any gap, and emails the SOC
team when the numbers don't match.

## What it does

1. A **Jupyter notebook** ([validation-notebook.ipynb](validation-notebook.ipynb)) runs on the
   Microsoft Sentinel **data lake** and writes one row per table to the analytics-tier table
   `ReplicationValidation_CL`:

   | Table | NumEventsInPrimaryWorkspace | NumEventsInParquetFiles | GapPercentage | Mismatch |
   | --- | --- | --- | --- | --- |
   | SigninLogs | 1000 | 1000 | 0.0 | false |
   | DeviceEvents | 2000 | 1900 | 5.0 | true |

2. A **scheduled analytic rule** (Informational severity, lowest priority) runs every 24 h and
   creates an incident whenever a row has `Mismatch == true`.
3. An **automation rule + Logic App playbook** emails the SOC team for each such incident.

## Prerequisites

- The BCDR ADF pipeline from the [parent folder](../README.md) is deployed and producing
  federated Delta tables.
- You are **onboarded to the Microsoft Sentinel data lake** and the federation connector exposes
  the Delta tables (federated tables are named `<table>_<instanceName>`).
- **VS Code** with the **Microsoft Sentinel** extension, signed in.
- The data lake managed identity (`msg-resources-<guid>`) has **Log Analytics Contributor** on the
  workspace that will hold `ReplicationValidation_CL` (required to create the custom table).
- Azure CLI, and permission to deploy a Logic App + Microsoft Sentinel analytic/automation rules
  in the target resource group.
- An Office 365 / Exchange mailbox or distribution list for the SOC team.

## Step-by-step (about 5 minutes)

### 1. Run and schedule the notebook

1. Open [validation-notebook.ipynb](validation-notebook.ipynb) in VS Code.
2. In the first cell, set `PRIMARY_WORKSPACE_NAME`, `ANALYTICS_TIER_WORKSPACE_NAME`, and
   `FEDERATION_INSTANCE_NAME` (the federation connector instance name). Leave the rest at defaults.
3. Run all cells once on the **Medium** runtime pool to confirm it writes `ReplicationValidation_CL`.
   (The first run also creates the table in the analytics tier.)
4. Schedule it: in the notebook toolbar choose **Create schedule Job** → **Daily**, set a start time
   a couple of hours after midnight UTC, and **Set job to run indefinitely**. Submit.

### 2. Deploy the alert + email

1. Copy the example parameters and fill in your values:

   ```powershell
   Copy-Item azuredeploy.parameters.example.json azuredeploy.parameters.json
   ```

   Set at least `sentinelWorkspaceName` and `socEmailAddress`.

2. Deploy:

   ```powershell
   az deployment group create `
     --resource-group <sentinel-resource-group> `
     --template-file azuredeploy.json `
     --parameters @azuredeploy.parameters.json
   ```

## Post-deployment (required)

1. **Authorize the API connections.** In the Azure portal open the resource group, find the two
   API connections (`office365-bcdr-validation` and `azuresentinel-bcdr-validation`), and click
   **Edit API connection → Authorize → Save** for each. The Office 365 one signs in as the mailbox
   that sends the email.
2. **Let Sentinel run the playbook.** In the Microsoft Defender portal: **Sentinel → Configuration →
   Automation → Active playbooks**, open `pb-bcdr-replication-mismatch-email`, and if prompted grant
   **Microsoft Sentinel** permissions on the playbook's resource group (one-time "Grant permissions").
3. **Confirm the result table name.** After the first notebook run, open **Logs** and verify the table
   is `ReplicationValidation_CL`. If your tenant names it differently, update the `resultTableName`
   parameter and redeploy.

## Verify it works

1. Force a mismatch: set `TABLE_ALLOWLIST` in the notebook to one table you know is currently lagging
   (or temporarily lower its data), run the notebook, and confirm a `Mismatch == true` row appears.
2. Within 24 h (or run the analytic rule manually) an **Informational** incident is created and the SOC
   mailbox receives an email.

For cost notes, the count/matching logic, tuning, and troubleshooting, see
[ADDITIONAL-INFORMATION.md](ADDITIONAL-INFORMATION.md).
