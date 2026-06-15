# Sentinel BCDR Active/Passive ADF Deployment

> [!WARNING]
> **This is a personal project — not an official Microsoft product**, and is not affiliated with, endorsed by, or supported by Microsoft.
>
> **It deploys billable Azure resources and processes production security data.** — see [Cost estimations](#cost-estimations). **You are solely responsible for all costs incurred.**
>
> Review every parameter, **deploy to a non-production environment first**, validate the data flows in a debug session, and **delete resources you no longer need**. Misconfiguration can incur large charges or affect production systems.
>
> Provided **"AS IS", without warranty of any kind and without support** — use entirely at your own risk.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fsmedin4%2FSecurity-bits%2Fmain%2FSentinel-BCDR-Active-Passive%2Fazuredeploy.json)

This deploys an Azure Data Factory pipeline that converts Azure Monitor Data Export blobs from a source storage account into **Delta tables** — Snappy-compressed Parquet data files plus a `_delta_log/` transaction log — in a target ADLS Gen2 account.

The files generated in target ADLS Gen2 storage account are ready to be consumed by Sentinel data lake federation.

## What It Deploys

- Azure Data Factory with a system-assigned managed identity.
- Source Azure Blob Storage linked service using managed identity authentication.
- Target ADLS Gen2 linked service.
- A generic, schema-drift Mapping Data Flow (`df_json_to_delta`) that converts JSON-lines export blobs to a Delta table, plus a native-typed variant (`df_json_to_delta_native`).
- A warm data flow Integration Runtime (`ir-dataflow-warm`) that runs the data flow.
- A child pipeline that exports a single container and time window to Delta.
- A schema-refresh pipeline (`pl_refresh_table_schemas`) that records the workspace's declared column types for native typing.
- A master discovery pipeline that refreshes the schema, lists matching source containers, and fans the export out across them.
- Optional hourly schedule trigger.
- Optional diagnostic settings to Log Analytics.

## Prerequisites

Before deploying, create or identify:

- A source storage account that receives Azure Monitor Data Export blobs.
- Source containers that match the configured prefix, usually `am-`.
- A target ADLS Gen2 storage account and file system for Delta output.
- Permissions to deploy Azure Data Factory in the target resource group.
- Permissions to grant post-deployment RBAC roles on the source and target storage scopes.

This template does not configure Azure Monitor Data Export. Configure export separately so blobs already land in the source storage account. If in the future you add new datasources in your primary Sentinel workspace, remember to adjust the Data Export rule to include any new table.

## Deploy

Use the Deploy to Azure button above, or deploy with Azure CLI:

```powershell
az deployment group create `
  --resource-group <deployment-resource-group> `
  --template-file azuredeploy.json `
  --parameters @azuredeploy.parameters.json
```

Copy `azuredeploy.parameters.example.json` to `azuredeploy.parameters.json` before adding real values. The local `azuredeploy.parameters.json` file is ignored by this subfolder's `.gitignore`.

For a complete reference of all deployment parameters, go to the section Parameters below.

## Post-Deployment RBAC

After deployment, use the `dataFactoryPrincipalId` output to grant the Data Factory managed identity access to storage.

The `Reader` role is required on the source storage account so the master pipeline can list containers through Azure Resource Manager.

The `Storage Blob Data Reader` role is required to read source blobs.

The `Storage Blob Data Contributor` role is required to write Delta output to the target ADLS Gen2 account or file system.

The `Reader` role on the **Log Analytics workspace** is required because the hourly export refreshes the table schema before each run (`enableNativeTypes` defaults to `true`). It lets the managed identity read declared table column types from the Azure Resource Manager Tables API (metadata only — it does not grant access to log data). It is only optional if you set `enableNativeTypes` to `false`. See [Native column types](#native-column-types).

```powershell
$principalId = "<data-factory-principal-id>"
$sourceScope = "/subscriptions/<subscription-id>/resourceGroups/<source-resource-group>/providers/Microsoft.Storage/storageAccounts/<source-storage-account>"
$targetScope = "/subscriptions/<subscription-id>/resourceGroups/<target-resource-group>/providers/Microsoft.Storage/storageAccounts/<target-storage-account>"
$workspaceScope = "/subscriptions/<subscription-id>/resourceGroups/<workspace-resource-group>/providers/Microsoft.OperationalInsights/workspaces/<workspace-name>"

az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --role Reader --scope $sourceScope
az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --role "Storage Blob Data Reader" --scope $sourceScope
az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --role "Storage Blob Data Contributor" --scope $targetScope
az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --role Reader --scope $workspaceScope
```

## Next steps after deployment

After deploying and granting the RBAC roles above, the usual path is:

1. **Test two tables first** — run the export for a couple of tables and confirm Delta output appears. See [Testing with tables](#testing-with-tables).
2. **Run all tables once** — clear the allow-list and run the full export manually. See [Testing with tables](#testing-with-tables).
3. **Turn on the hourly schedule** — start the trigger so the export runs every hour, unattended. See [Running on a permanent hourly schedule](#running-on-a-permanent-hourly-schedule).

By default the export writes **native column types** (numbers, booleans, timestamps), so analysts query without casting — see [Native column types](#native-column-types). Output lands as Delta tables ready for [Sentinel data lake federation](#sentinel-data-lake-federation).

## Testing with tables

Run the export manually before relying on the schedule. The `tableAllowList` parameter — a comma-separated list of source container names including the `am-` prefix, empty for all tables — controls how many tables are processed.

### Test two tables first

1. Set `tableAllowList` to one or two small tables and keep `enableTrigger` at `false`:

   ```jsonc
   // azuredeploy.parameters.json
   "tableAllowList": { "value": "am-signinlogs,am-azureactivity" }
   ```

2. Deploy, then run `pl_discover_and_export_azmon_to_delta` from Data Factory Studio (**Author → pipeline → Add trigger → Trigger now**, or **Debug**).
3. Confirm only those tables produced a `<table>/` Delta folder in the target container.

Restricting the list keeps the test cheap, because the largest tables and their cross-region transfer are excluded until you are ready.

### Run all tables

1. Clear the allow-list so every matching container is processed:

   ```jsonc
   // azuredeploy.parameters.json
   "tableAllowList": { "value": "" }
   ```

2. Redeploy (or set the parameter in the run dialog) and run `pl_discover_and_export_azmon_to_delta` again.
3. To check the whole run at a glance, open the run, expand `ForEachMatchingContainer`, and filter the child activities by **Status = Failed**. Zero failures means every discovered table exported.

### Supplying parameters for manual runs

At deployment, the parameter-file values are baked into the discovery pipeline (`pl_discover_and_export_azmon_to_delta`) as its parameter defaults, and the schedule trigger passes nothing. So both the scheduled run and a manual **Debug** or **Trigger now** of the discovery pipeline use your deployed values automatically — including `sourceWorkspaceResourceId` and `tableAllowList` — with nothing to type.

The single-container pipeline `pl_export_container_window_delta` keeps static defaults so it can be run ad hoc. If you Debug it directly, set `sourceWorkspaceResourceId` (so source listing stays fast), `containerName` (the full `am-` name), and the window in the run dialog. Leave `sourceFolderPath` at its default `WorkspaceResourceId=*` — it is ignored when `sourceWorkspaceResourceId` is set.

### Manual runs and duplicate rows

The Delta sink is **append-only** (it inserts rows; it does not update, delete, or upsert). Each run re-reads the `PT5M` source files for the container and window it is given and **appends** them to the table. So reprocessing the **same table and the same hour** writes those rows **again, as duplicates**. This happens if you:

- run a manual export for an hour the hourly schedule also processes, or
- run the same manual export (or rerun an activity) more than once for the same window.

The scheduled runs do not duplicate each other, because each hourly run processes a different one-hour window exactly once. Duplicates only come from **reprocessing the same window**. Note that `VACUUM` and the `skipDuplicateMap*` sink options do **not** remove duplicate rows — they manage files and column mapping, not row de-duplication.

Easy ways to test without polluting your real tables:

- **Use a separate target file system.** Set `targetFileSystem` to something like `sentinel-bcdr-test` for the test run, then delete it afterward. Your production `sentinel-bcdr` tables are untouched.
- **Test a throwaway table.** Set `tableAllowList` to one low-value table, and delete that table's folder from the target when you are done.
- **Pick an old window the schedule will not run**, then delete the affected `<table>/` Delta folder afterward.
- **If a table did get duplicates**, the simplest reset is to delete that table's folder (including its `_delta_log/`) in the target and let the next scheduled run rebuild from that hour onward.

For true idempotency (so reruns never duplicate), the sink would need to **upsert keyed on `_ItemId`** — the unique per-record ID that Azure Monitor stamps on every exported row — instead of appending. That is a larger change (it makes Delta match and overwrite existing rows, which is heavier and needs the key validated against your tables), so it is intentionally not enabled by default; treat each window as processed once and avoid reprocessing.

To change any deployed value, edit `azuredeploy.parameters.json` and redeploy.

## Running on a permanent hourly schedule

Two resources drive the schedule:

- **`pl_discover_and_export_azmon_to_delta`** refreshes the schema, discovers the matching `am-*` containers, and runs `pl_export_container_window_delta` for each one.
- **`tr_hourly_discover_and_export_azmon_to_delta`** runs that pipeline on the hourly schedule.

To run the export every hour, permanently:

1. Set `enableTrigger` to `true` to create the hourly trigger.
2. *(Optional)* Limit the run to specific tables with `tableAllowList` — see [Limiting the scheduled run to specific tables](#limiting-the-scheduled-run-to-specific-tables).
3. Redeploy the template.
4. **Start the trigger.** Resource Manager deploys triggers in a stopped state, so start it once after deployment:
   - Studio: **Manage → Triggers → `tr_hourly_discover_and_export_azmon_to_delta` → Start**, then **Publish**.
   - Or Azure CLI:

     ```bash
     az datafactory trigger start \
       --resource-group <resource-group> \
       --factory-name <data-factory-name> \
       --name tr_hourly_discover_and_export_azmon_to_delta
     ```
5. Verify in **Monitor → Trigger runs** that it fires each hour, that `_delta_log/` updates in each table folder, and that the federated tables refresh in the Sentinel data lake.

Each run processes the previous complete hour: at run time *T* it reads the window *[T − 2h, T − 1h)* (with `processingDelayHours: 1`), which gives Azure Monitor time to finish exporting that hour. Scheduled runs pass `sourceWorkspaceResourceId` automatically, so source listing stays fast — unlike a manual run, where you must type it (see [Supplying parameters for manual runs](#supplying-parameters-for-manual-runs)).

The discovery pipeline fans out with a `ForEach` `batchCount` of 4, because each export runs a Spark data flow on the warm Integration Runtime and a high concurrency would start many Spark clusters at once. Adjust it in the `pl_discover_and_export_azmon_to_delta` pipeline definition to trade compute cost against how quickly the hourly run completes.

### Limiting the scheduled run to specific tables

To run the schedule for only some tables, set `tableAllowList` to a comma-separated list of source container names (including the `am-` prefix); leave it empty to process every container matching `sourceContainerPrefix`. This is the same parameter described in [Testing with tables](#testing-with-tables), and it applies to both manual and scheduled runs.

```jsonc
// azuredeploy.parameters.json
"tableAllowList": { "value": "am-signinlogs,am-microsoftgraphactivitylogs" }, // only these tables
"tableAllowList": { "value": "" }                                              // all tables (default)
```

## Parameters

| Parameter | Required | Description | Example |
| --- | --- | --- | --- |
| `dataFactoryName` | Yes | Name of the Azure Data Factory to create. Must be globally unique for Data Factory. | `<data-factory-name>` |
| `location` | No | Azure region for the Data Factory. Defaults to the deployment resource group's location when omitted. | `eastus` |
| `sourceStorageAccountUrl` | Yes | Blob service endpoint for the Azure Monitor Data Export source account. | `https://<source-storage-account>.blob.core.windows.net` |
| `sourceStorageAccountResourceId` | Yes | ARM resource ID of the **source** storage account — the one that holds the `am-*` export containers, the same account as `sourceStorageAccountUrl` (not the target). The master pipeline uses it to list containers, so it must be the source account or discovery finds nothing. | `/subscriptions/<subscription-id>/resourceGroups/<source-resource-group>/providers/Microsoft.Storage/storageAccounts/<source-storage-account>` |
| `targetStorageAccountUrl` | Yes | DFS endpoint for the target ADLS Gen2 account. | `https://<target-storage-account>.dfs.core.windows.net` |
| `targetFileSystem` | No | Target ADLS Gen2 file system/container name. | `sentinel-bcdr` |
| `sourceContainerPrefix` | No | Prefix used to select source containers. Azure Monitor export containers commonly use `am-`. | `am-` |
| `sourceWildcardFolderPath` | No | Wildcard folder path below each source container. Used when `sourceWorkspaceResourceId` is empty. | `WorkspaceResourceId=*` |
| `sourceWorkspaceResourceId` | No | Exact value Azure Monitor writes after `WorkspaceResourceId=` in the source path (the workspace ARM ID, lowercased, beginning with `/subscriptions/`). When set, sources list only the processed hour folder instead of the whole container, keeping listing fast as history grows. Leave empty to scan the whole container. Single-workspace assumption; casing must match the storage browser exactly. | `/subscriptions/<subscription-id>/resourcegroups/<resource-group>/providers/microsoft.operationalinsights/workspaces/<workspace-name>` |
| `sourceFilePattern` | No | File pattern for source export blobs. | `PT5M*.json` |
| `triggerFrequency` | No | Schedule trigger frequency. Allowed values: `Minute`, `Hour`, `Day`, `Week`. | `Hour` |
| `triggerInterval` | No | Schedule trigger interval. Must be at least `1`. | `1` |
| `triggerStartTimeUtc` | No | UTC start time for the schedule trigger. Leave empty to use a default anchor (the trigger still fires on the next hour boundary). | `2026-06-04T00:00:00Z` |
| `enableTrigger` | No | Set to `true` to create the hourly schedule trigger. Leave `false` to deploy without a schedule and run the pipeline manually (recommended while testing). The trigger is deployed stopped; start it once after deployment. | `false` |
| `processingDelayHours` | No | Hours to wait before processing. Default processes the previous complete hour. | `1` |
| `tableAllowList` | No | Comma-separated source container names to process. Leave empty to process all containers matching `sourceContainerPrefix`. Use it to test on a few tables before running everything. | `am-signinlogs,am-microsoftgraphactivitylogs` |
| `enableNativeTypes` | No | Cast columns to native types (`long`, `double`, `boolean`, `timestamp`) using the schema map from `pl_refresh_table_schemas`, which the hourly export refreshes before each run. Default `true`. Set `false` for the all-string export (no workspace access needed). Switching an already-exported table between string and native is an incompatible Delta change, so empty its Delta folder when you change this. See [Native column types](#native-column-types). | `true` |
| `metadataFileSystem` | No | Target ADLS Gen2 file system where the schema-refresh pipeline writes `_raw/workspace-tables.json` and `_schemas/workspace-schemas.json`. Defaults to the same file system as the Delta output. | `sentinel-bcdr` |
| `dataFlowCoreCount` | No | Spark cores for the warm data flow Integration Runtime. `8` is cheapest; `16` is the recommended production minimum. | `8` |
| `dataFlowTimeToLiveMinutes` | No | Warm-cluster time-to-live in minutes for the data flow Integration Runtime. Keeps the Spark cluster warm between hourly runs. `0` disables the warm pool. | `10` |
| `logAnalyticsWorkspaceId` | No | Optional Log Analytics workspace resource ID for Data Factory diagnostics. Leave empty to disable diagnostics. | `/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.OperationalInsights/workspaces/<workspace-name>` |
| `tags` | No | Tags applied to the Data Factory. | `{ "workload": "sentinel-bcdr" }` |

## Native column types

By default the export casts each column to its **declared native type** (`long`, `double`, `boolean`, `timestamp`), so analysts query without casting. The types come from the workspace's **declared** schema (which is stable), not from per-file inference — Azure Monitor JSON is schema-on-read, so inferring types per file is non-deterministic (Short vs Long, Boolean vs String) and would conflict at the Delta merge. `string`, `guid`, and `dynamic` columns stay string (`dynamic` holds arbitrary JSON — query with `parse_json()`).

It works in three stages:

1. **Schema collection.** `pl_refresh_table_schemas` calls the Azure Resource Manager Tables API for the workspace and writes the response to `_raw/workspace-tables.json` in `metadataFileSystem`. This needs **Reader on the workspace** (above).
2. **Bucketing.** In the same pipeline, the `BuildSchemas` data flow (`df_build_schemas`) reads `_raw/workspace-tables.json`, flattens every table's declared columns, and writes a single compact map `_schemas/workspace-schemas.json`. Each line is keyed by the lowercase table name and lists which columns are `long` (`int`/`long`), `double` (`real`), `boolean`, and `timestamp` (`datetime`); everything else stays string.
3. **Cast-back.** The export looks up the table's entry in `_schemas/workspace-schemas.json` and runs `df_json_to_delta_native`, which casts those columns from string to their native type before writing Delta.

### Schema refresh runs before every export

`pl_discover_and_export_azmon_to_delta` runs `pl_refresh_table_schemas` as its **first activity** (a hard dependency: if the refresh fails, the export does not run). This closes a race: a source container `am-<table>` only exists after the table is **declared** in the workspace, and the refresh reads the declared schema — so by the time discovery sees a table, the just-run refresh already has its column types. Every table is therefore written with native types from its first export, with no string→native transition (which would otherwise be an incompatible Delta change). There is no separate daily schema trigger; the refresh is part of the hourly run.

> **`enableNativeTypes = false` falls back to all-string.** Setting the parameter to `false` routes the export through the unchanged `df_json_to_delta`, which writes every column as string (analysts cast at query time with `toint()`, `tolong()`, `tobool()`, `parse_json()`). The all-string path is deterministic and needs no workspace access.

### Switching an existing table between string and native

Changing a column from string to a native type (or back) is an incompatible Delta schema change. If you flip `enableNativeTypes` for tables that already have Delta folders, **delete those folders first** so they are recreated with the new types. A clean run against an empty target file system needs no resets.

> **Timestamp and boolean parsing.** Timestamps are parsed as UTC and truncated to milliseconds (Azure Monitor writes ISO 8601 with 7 fractional digits, beyond the millisecond limit of `toTimestamp`); JSON booleans parse with `toBoolean()`. Values that do not parse become null rather than failing the run. To inspect the cast logic, open `df_json_to_delta_native` in a Data Factory Studio debug session.

The declared types do not change between runs, so this produces native types with no schema-merge conflicts — and it stays entirely within Data Factory (no Azure Function or Databricks).

## Output Layout

Each source container becomes a top-level **Delta table** folder directly under the target file system. This matches what the Sentinel data lake federation connector discovers (one table per folder). The `sourceContainerPrefix` (default `am-`) is stripped from the folder name, so the `am-signinlogs` container is written as the `signinlogs` table folder.

A Delta table is a folder that holds a `_delta_log/` transaction log alongside the `.snappy.parquet` data files it references:

```text
<table>/_delta_log/00000000000000000000.json
<table>/part-00000-<guid>-c000.snappy.parquet
```

For example, `am-signinlogs` is written as a `signinlogs/` table containing `signinlogs/_delta_log/...` and one or more `signinlogs/part-*.snappy.parquet` data files.

The layout is flat: the data files sit at the table root with no date-partition folders. The federation connector does not require partitioning, and the `TimeGenerated` column is preserved in every row so time filtering still works in queries. The data flow enables Optimized Write and Auto Compact, so Spark sizes the Parquet data files automatically (around a 128 MB target) without any row-count setting.

> **Single-workspace assumption.** The export reads one Log Analytics workspace per source container (through `sourceWorkspaceResourceId`). If more than one workspace exported the same table into the same source container, their rows would be combined in one table with no workspace dimension. Revisit this if you onboard additional workspaces.

### Parallelism

The master pipeline discovers all matching `am-*` containers and exports them in parallel. The degree of parallelism is set by the `ForEach` activity's `batchCount` (4 in this template), which is the upper bound; the actual number of concurrent exports is the smaller of `batchCount` and the number of matching containers. It is kept low because each export runs a Spark data flow on the warm Integration Runtime, and a high concurrency would start many Spark clusters at once. Adjust `batchCount` in the `pl_discover_and_export_azmon_to_delta` pipeline definition to trade compute cost against how quickly the hourly run completes.

### Source and output formats

Three data formats are involved, and it helps to be precise about how each one relates to the others:

| Format | Where | What it is |
| --- | --- | --- |
| **JSON Lines** (NDJSON) | Source (Azure Monitor export) | One JSON object per line, with no enclosing array and no commas between records. Row-oriented text, human-readable. Written as `PT5M.json` blobs. |
| **Parquet** | Delta data files | Columnar **binary** format. Stores data column by column with per-column compression (Snappy) and encoding (dictionary/RLE). Not human-readable; compact and fast to scan. |
| **Delta** | Output (the table) | **Not a new file format.** A folder of Parquet data files **plus** a `_delta_log/` transaction log (JSON commit files that record which Parquet files belong to the table, the schema, and statistics). In short, **Delta = Parquet + a transaction log.** The federation connector requires that log. |

The pipeline produces a Delta table from the JSON-lines source in one step (the export data flow). Two things happen:

- **JSON Lines is re-encoded to Parquet.** Each line is parsed into a row and the values are written column by column with Snappy. Column types come from the workspace's **declared** schema (see [Native column types](#native-column-types)): numbers, booleans, and timestamps are written as native types so analysts query them without casting, while `string`, `guid`, and `dynamic` columns stay string. The `IngestedUtc` column added by the flow is a timestamp. Row-oriented text becomes columnar binary.
- **A `_delta_log/` is written** that names the Parquet data files making up the table (plus protocol, schema, stats, and commit info). The transaction log is what makes the folder a Delta table the connector can read; without it, plain Parquet files are not discovered.

## Sentinel Data Lake Federation

Follow the official guide to set up the connector: [Set up federated data connectors in Microsoft Sentinel data lake](https://learn.microsoft.com/en-us/azure/sentinel/datalake/data-federation-setup?tabs=adls). It covers creating the ADLS Gen2 connector instance, the service principal role grant, hierarchical namespace, and the Key Vault secret.

A few specifics for this template's output:

- Use the **account endpoint** as the connector URL, for example `https://<account>.dfs.core.windows.net/` — not a container or folder path. The connector discovers one table per top-level folder.
- Each container federates as `<table>_<instanceName>` — the container name with the `am-` prefix removed, plus the connector instance name (for example `am-azuremetrics` → `azuremetrics_<instanceName>`). Bracket names that are not valid KQL identifiers, for example `['azuremetrics_<instanceName>']`.
- **Delta Parquet is required.** Each table folder must contain a `_delta_log/` transaction log alongside its `.snappy.parquet` data files. Plain Parquet with no `_delta_log/` is not discovered and shows "No data available". A `TimeGenerated` column preserves original event times; without it, federated rows are timestamped at query time. This template always writes a `_delta_log/`, so its output is federation-ready.

To prove the Delta-format requirement with throwaway tables before federating real data, see [Testing federation with sample Delta tables](ADDITIONAL-INFORMATION.md#testing-federation-with-sample-delta-tables).

## How the Delta output works

The Sentinel data lake connector only reads **Delta** tables (a folder with a `_delta_log/`). This template produces Delta directly with a **Mapping Data Flow**, keeping everything inside Data Factory (no extra Function or Databricks resource) and letting ADF manage the `_delta_log`, file compaction (Optimized Write / Auto Compact), and schema evolution.

The Delta components are:

- **`df_json_to_delta`** / **`df_json_to_delta_native`** — generic, schema-drift Mapping Data Flows that read the JSON-lines export and write a flat (unpartitioned) **Delta** table per `am-`-stripped container. `df_json_to_delta_native` adds the native-type casts (see [Native column types](#native-column-types)); `df_json_to_delta` writes all-string. A flat layout matches the table structure the federation connector reads (one `_delta_log/` plus data files at the table root). Date partitioning is intentionally omitted because the connector does not require it and partitioning a schema-drift stream by only its derived columns is rejected by the Delta sink.
- **`pl_refresh_table_schemas`** — records the workspace's declared column types to `_schemas/workspace-schemas.json`, used by the native cast.
- **`ir-dataflow-warm`** — a custom Azure Integration Runtime (serverless Spark) sized by `dataFlowCoreCount` with a `dataFlowTimeToLiveMinutes` warm pool.
- **`pl_export_container_window_delta`** — runs the data flow for one container/window on the warm runtime.
- **`pl_discover_and_export_azmon_to_delta`** — the master pipeline that refreshes the schema, discovers `am-*` containers, and runs the export for each.

### Why a warm Integration Runtime

A Mapping Data Flow runs on a Spark cluster. A **cold** cluster takes about 3–5 minutes to start before any data moves, and you pay for that. A **warm** runtime keeps the cluster alive for a short time-to-live after each run, so a following run within that window reuses it. Microsoft recommends a custom Azure IR with TTL for operationalized pipelines. At an hourly cadence with the default 10-minute TTL, runs are too far apart to reuse the cluster, so each hour cold-starts — see the cost note in [ADDITIONAL-INFORMATION.md](ADDITIONAL-INFORMATION.md#cost-estimations). Shorten the interval below the TTL to reuse clusters, or accept the cold start.

For data flow validation, debug logging, and where to find run logs, see [Troubleshooting](ADDITIONAL-INFORMATION.md#troubleshooting).

## Cost estimations

See [ADDITIONAL-INFORMATION.md](ADDITIONAL-INFORMATION.md#cost-estimations) for the estimated monthly cost (about 2 TB/day), the breakdown of public rates (Azure Monitor export, UAE North → Southeast Asia cross-region egress, ADLS Gen2, and Data Flow compute), and the main cost levers.