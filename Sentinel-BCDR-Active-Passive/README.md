# Sentinel BCDR Active/Passive ADF Deployment

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fsmedin4%2FSecurity-bits%2Fmain%2FSentinel-BCDR-Active-Passive%2Fazuredeploy.json)

This deploys an Azure Data Factory pipeline that converts Azure Monitor Data Export blobs from a source storage account into **Delta tables** — Snappy-compressed Parquet data files plus a `_delta_log/` transaction log — in a target ADLS Gen2 account.

The files generated in target ADLS Gen2 storage account are ready to be consumed by Sentinel data lake federation.

## What It Deploys

- Azure Data Factory with a system-assigned managed identity.
- Source Azure Blob Storage linked service using managed identity authentication.
- Target ADLS Gen2 linked service.
- A generic, schema-drift Mapping Data Flow (`df_json_to_delta`) that converts JSON-lines export blobs to a Delta table.
- A warm data flow Integration Runtime (`ir-dataflow-warm`) that runs the data flow.
- A child pipeline that exports a single container and time window to Delta.
- A master discovery pipeline that lists matching source containers and fans the export out across them.
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

The `Reader` role on the **Log Analytics workspace** is required only if you run the daily schema-refresh pipeline (`pl_refresh_table_schemas`). It lets the managed identity read declared table column types from the Azure Resource Manager Tables API (metadata only — it does not grant access to log data). See [Native column types (schema refresh)](#native-column-types-schema-refresh).

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

## Native column types (schema refresh)

By default the export reads every column as **string** (`inferDriftedColumnTypes: false`), which is the only deterministic choice for a single generic flow: Azure Monitor JSON is schema-on-read, so the same column can infer as different types across files (Short vs Long, Boolean vs String), and `dynamic` columns hold arbitrary JSON. Reading everything as string guarantees the Delta schema never conflicts. The trade-off is that analysts cast at query time (`toint()`, `tolong()`, `tobool()`, `parse_json()`).

To give analysts **native types** without casting, the template includes a schema-refresh path that reads the workspace's **declared** column types (which are stable) and uses them to cast the string columns back. It is built in stages:

1. **Schema collection (included).** `pl_refresh_table_schemas` calls the Azure Resource Manager Tables API for the workspace and writes the response to `_raw/workspace-tables.json` in `metadataFileSystem`. `tr_daily_refresh_table_schemas` runs it daily. This needs **Reader on the workspace** (above). Run it once and confirm the file appears before relying on it.
2. **Bucketing (next).** A data flow reads `_raw/workspace-tables.json` and writes one `_schemas/<table>.json` per table listing which columns are `long`, `double`, `boolean`, and `timestamp` (everything else, including `dynamic`, stays string). This data flow is best authored and validated in a Data Factory Studio debug session.
3. **Cast-back (next).** `df_json_to_delta` looks up `_schemas/<table>.json` for the table being written and casts those columns from string to their native type; `dynamic` columns remain JSON strings (query with `parse_json()`). When no schema file exists yet, the export stays all-string, so the cast-back is safe to add incrementally.

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

The pipeline produces a Delta table from the JSON-lines source in one step (the `df_json_to_delta` data flow). Two things happen:

- **JSON Lines is re-encoded to Parquet.** Each line is parsed into a row and the values are written column by column with Snappy. The flow keeps **native types** (`inferDriftedColumnTypes: true`) so analysts query numbers, booleans, and timestamps directly without casting. Because Azure Monitor JSON is schema-on-read, a column's inferred *width* can vary across hours (a small integer one hour, a long the next), so the flow **widens** all `integer`/`short` to `long` and `float` to `double`, which removes that whole class of Delta merge conflicts while staying numeric. A small number of columns are genuinely polymorphic (the same field is a number in one record and a boolean/string in another — for example `ResultType`); those are pinned to `string` (see the merge-conflict note under Troubleshooting). The `IngestedUtc` column added by the flow is a timestamp. Row-oriented text becomes columnar binary.
- **A `_delta_log/` is written** that names the Parquet data files making up the table (plus protocol, schema, stats, and commit info). The transaction log is what makes the folder a Delta table the connector can read; without it, plain Parquet files are not discovered.

## Viewing the Parquet data files

The Delta table's data files are Parquet, a binary columnar format, so they cannot be read in a text editor. Visual Studio Code shows "The file is not displayed in the text editor because it is either binary or uses an unsupported text encoding." This is expected and is not caused by Snappy compression; uncompressed Parquet is also binary.

To inspect a Parquet data file:

- Install the `dvirtz.parquet-viewer` VS Code extension, which renders Parquet as JSON or CSV (supports Snappy; files up to 50 MB).
- Or use the Azure Storage browser preview, Python (`pandas`/`pyarrow`), `parquet-tools`, or an analytics engine such as Synapse, Fabric, or Azure Data Explorer.

Compression trade-offs:

- Snappy (this template's default): smaller files, faster analytics reads, native support in Sentinel, Spark, and Fabric. Not human-readable as text, but neither is uncompressed Parquet.
- No compression: still binary and unreadable as text, while using more storage and slowing scans. Do not disable compression to make files readable.

## Sentinel Data Lake Federation

To federate this Delta output into the Microsoft Sentinel data lake using the Azure Data Lake Storage Gen2 connector:

- Use the account endpoint as the connector URL, for example `https://<account>.dfs.core.windows.net/`. The connector rejects container or folder paths; it discovers tables from the folder layout inside the account.
- The connector discovers one table per folder. With this layout, each container appears as a table with table path `<filesystem>/<table>`, where `<table>` is the container name with the `am-` prefix removed (for example, `sentinel-bcdr/signinlogs`).
- Federated tables appear in Sentinel as `<table>_<instanceName>`, where `<instanceName>` is the connector instance name. For example, the `am-azuremetrics` container becomes the `azuremetrics` table and federates as `azuremetrics_<instanceName>`.
- If a federated table name contains characters that are not valid KQL identifiers, bracket it in KQL, for example `['azuremetrics_<instanceName>']`.
- Grant the connector's service principal the `Storage Blob Data Reader` role on the target storage account, enable Hierarchical namespace on the account, and grant the Sentinel platform identity (prefixed `msg-resources-`) access to the Key Vault secret.
- The connector requires **Delta Parquet** format: each table folder must contain a `_delta_log/` transaction log alongside its `.snappy.parquet` data files. Plain Parquet with no `_delta_log/` is not discovered and the table shows "No data available". A `TimeGenerated` column enables enhanced lake features and preserves original event times; without it, federated rows are timestamped at query time.

If federation shows "No data available" with zero tables, confirm each table folder is a **Delta** table (it contains a `_delta_log/` subfolder) — plain Parquet alone is never discovered — that each container sits at the top level of the file system, that the connector URL is the account endpoint (not a container or folder path), and that the service principal has `Storage Blob Data Reader` on the account.

### Testing federation with sample Delta tables

The Sentinel data lake federated connector for ADLS gen2 only reads **Delta** tables: a folder is recognized as a table only when it contains a `_delta_log/` transaction log, and the Delta reader serves **only** the data files listed in that log. Plain `.snappy.parquet` files with no `_delta_log/`, or extra Parquet files not referenced by the log, are ignored.

The [federation-samples/](federation-samples) folder contains a generator that produces three ready-to-upload Delta tables under `federation-samples/out/`:

| Folder | Decoy plain Parquet (ignored) | Delta-committed rows | Federation shows |
| --- | --- | --- | --- |
| `fedsample1` | 10 rows | 5 | **5** |
| `fedsample2` | 10 rows | 0 (empty Delta commit) | **0** |
| `fedsample3` | 0 rows (empty) | 10 | **10** |

Each folder contains a `_delta_log/00000000000000000000.json` log plus the `part-00000-<guid>.snappy.parquet` it references, and a decoy `extra_plain_data.parquet` that is deliberately **not** referenced by the log. Because federation returns 5 / 0 / 10 (not 15 / 10 / 10), the decoys prove that only Delta-committed rows are served and stray Parquet is ignored. `fedsample2` also shows that an empty Delta commit still appears as a discoverable, empty table.

The sample schema is `TimeGenerated` (timestamp), `Hostname`, `SourceIP`, `SourcePort` (int), `DestinationIP`, `DestinationPort` (int), and `Action` (`allow`/`deny`).

Generate the samples:

```powershell
cd federation-samples
pip install pyarrow
python generate_federation_samples.py
```

Upload and federate:

1. Upload each `fedsampleN/` folder — including its `_delta_log/` subfolder — to the ADLS Gen2 container (for example, `sentinel-bcdr`). Pre-generated copies are committed under `federation-samples/out/`.
2. Create a federation connector instance pointing at the account endpoint URL `https://<account>.dfs.core.windows.net/` (not a container or folder path).
3. Each folder is discovered as a table named `fedsampleN_<instanceName>`.

Query with an explicit time range rather than `ago()`, because the sample `TimeGenerated` values are fixed to 2026-06-08:

```kusto
fedsample3_<instanceName>
| where TimeGenerated between (datetime(2026-06-08) .. datetime(2026-06-09))
```

Expect 5, 0, and 10 rows from `fedsample1`, `fedsample2`, and `fedsample3` respectively. `fedsample3` returning 10 (while its 0-row decoy is ignored) confirms the Delta-format requirement.

## Troubleshooting

If the discovery pipeline **succeeds but the target container is empty** (no `_delta_log/` or Parquet files appear), the `ForEach` ran zero iterations because discovery found no `am-*` containers. In Monitor, the run shows `ListSourceContainers` and `FilterMatchingContainers` succeeding and `ForEachMatchingContainer` finishing in under a second with **no** `ExportContainerWindowDelta` child. The usual cause is `sourceStorageAccountResourceId` pointing at the wrong account — most often the **target** ADLS Gen2 account instead of the source. It must be the **source** account that holds the `am-*` export containers, the **same account** as `sourceStorageAccountUrl`. Fix the value (keep both pointing at the same account), confirm the Data Factory managed identity has **Reader** on that source account (required for the Azure Resource Manager container listing) plus **Storage Blob Data Reader**, then redeploy and rerun. (A wrong account that the identity cannot read fails loudly with an authorization error instead; a wrong-but-readable account, such as the target, silently lists zero `am-*` containers.)

If some `ExportContainerWindowDelta` activities fail with `DF-Executor-InvalidOutputColumns` ("at Sink 'DeltaSink': The result has 0 output columns. Please ensure at least one column is mapped"), the affected tables had **no `PT5M` files in the processed hour**. The data flow source uses schema drift with no fixed columns, so an empty hour produces a stream with zero columns, and the Delta sink rejects an empty schema. The template avoids this by deriving an always-present `IngestedUtc` column (the UTC time the rows were written) before the sink, so the output schema is never empty: a quiet hour writes an empty (0-row) Delta commit instead of failing. If you still hit this error, redeploy the latest template. `IngestedUtc` is the processing time, not the event time — use the source `TimeGenerated` column for event-time queries.

If a table fails with `Failed to merge incompatible data types` (for example, "Failed to merge fields 'ResultType' and 'ResultType' ... IntegerType and BooleanType", or "'Total' ... IntegerType and LongType"), a column's **inferred type changed between runs**. Azure Monitor JSON is schema-on-read, so a value like `ResultType` can look like a number in one hour (`0`) and a boolean in another (`true`), and `Total` can be a small integer one hour and a long the next. When the Delta sink merges this hour's inferred schema with the existing table, Delta refuses to combine incompatible types. The data flow handles the two classes so analysts keep native types:

- **Width drift (same kind, different size)** — `integer`/`short` are widened to `long`, and `float` to `double`, in the `WidenNums` derive. This removes conflicts like `Total` (Integer vs Long) generically; the column stays a number.
- **True polymorphism (different kinds)** — a column that is a number in one record and a boolean/string in another has no common native type, so it is pinned to `string`. `ResultType` is pinned this way in the `AddMeta` derive (`each(match(name=='ResultType'), $$ = toString($$))`), which is also its real Log Analytics type. Query such columns with `parse_json()`/`tostring()`.

**Playbook for a new conflict:** read the failing field and the two types from the error. If both are numeric (Integer/Long/Short/Float/Double), it is width drift — `WidenNums` already covers it after redeploy; if a new numeric kind appears, extend the `WidenNums` matches. If the two types are different *kinds* (for example Integer vs Boolean, or String vs anything), add a name match for that column to the `AddMeta` derive, for example `each(match(name=='ResultType'||name=='NewCol'), $$ = toString($$))`, then redeploy and reset that table. After changing the typing, **reset the affected table once** — either point `targetFileSystem` at a fresh file system (for example `sentinel-bcdr2`) and re-point federation to it, or delete the existing `<table>/` folder (including `_delta_log/`) so the schedule rebuilds it with the new types.

> **Nested `dynamic` columns and a fully schema-driven option.** Columns that hold a JSON object or array (`dynamic` in Log Analytics — for example `DeviceDetail`, `TargetResources`, `Properties_d`) infer as a struct/array. If their nested shape changes between hours they can also merge-conflict. To stringify them generically, add a `StringifyComplex` derive (`each(match(type=='complex'||type=='map'||type=='array'), $$ = toString($$))`) — **validate in a Data Factory Studio debug session first**, because `toString()` on a struct must produce usable JSON in your runtime. For guaranteed zero-residual native typing across every table, the robust pattern is a small Azure Function or Databricks/Spark step that reads each record against the workspace's declared schema (from the Azure Resource Manager Tables API) and writes Delta with stable types; that adds a compute resource, which this template deliberately avoids.

If a run spends several minutes on **Listing source** while reading only a handful of files, the source is enumerating the whole container. With the default `sourceWildcardFolderPath` (`WorkspaceResourceId=*`) and recursive listing, Data Factory walks every historical five-minute folder in the container before filtering by time, so listing time grows with the container's history. Set `sourceWorkspaceResourceId` to the exact path Azure Monitor writes after `WorkspaceResourceId=` (the workspace ARM ID, lowercased, beginning with `/subscriptions/`). The data flow source then lists only the processed hour's `y=/m=/d=/h=/` folder, so listing stays fast regardless of history. Copy the value from the storage browser to match its casing exactly; if a run lists zero files, clear the parameter to fall back to the wildcard path. This assumes a single workspace per source container.

> **Manual runs of the single-container pipeline.** The discovery pipeline carries your deployed values, but a manual **Debug** of `pl_export_container_window_delta` uses that pipeline's static defaults, where `sourceWorkspaceResourceId` is empty. If you leave it blank there, the source falls back to the `WorkspaceResourceId=*` wildcard and lists the whole container. Type `sourceWorkspaceResourceId` into the dialog, or run the discovery pipeline or the schedule instead. See [Supplying parameters for manual runs](#supplying-parameters-for-manual-runs).

If a later run fails with an authorization error, confirm the Data Factory managed identity has the post-deployment RBAC assignments above. For ADLS Gen2 accounts with hierarchical namespace ACLs, also confirm the identity has execute permission on parent folders and write permission on the target path.

## Testing with a subset of tables

Before running the pipeline for every exported table, you can test it on a few. Set the `tableAllowList` parameter to a comma-separated list of source container names (including the `am-` prefix). Only those containers are processed; everything else is skipped. Leave it empty to process all containers that match `sourceContainerPrefix`.

```jsonc
// azuredeploy.parameters.json
"tableAllowList": { "value": "am-signinlogs" },          // one table
"tableAllowList": { "value": "am-signinlogs,am-azureactivity" }, // a few tables
"tableAllowList": { "value": "" }                        // all tables (default)
```

How to test:

1. Set `tableAllowList` to one or two small tables and keep `enableTrigger` set to `false`.
2. Deploy the template, then run `pl_discover_and_export_azmon_to_delta` manually from the Data Factory Studio (**Author → pipeline → Debug** or **Add trigger → Trigger now**).
3. Confirm only the allow-listed tables produced output in the target container.
4. When you are happy, clear `tableAllowList` (empty) and set `enableTrigger` to `true` to process all tables on the hourly schedule.

Restricting the table list during testing also keeps cost low, because the largest tables (and their cross-region transfer) are excluded until you are ready.

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

## How the Delta output works

The Sentinel data lake connector only reads **Delta** tables (a folder with a `_delta_log/`). This template produces Delta directly with a **Mapping Data Flow**, keeping everything inside Data Factory (no extra Function or Databricks resource) and letting ADF manage the `_delta_log`, file compaction (Optimized Write / Auto Compact), and schema evolution.

The Delta components are:

- **`df_json_to_delta`** — a generic, schema-drift Mapping Data Flow: reads the JSON-lines export and writes a flat (unpartitioned) **Delta** table per `am-`-stripped container. A flat layout matches the table structure the federation connector reads (one `_delta_log/` plus data files at the table root, like the `federation-samples/` tables). Date partitioning is intentionally omitted because the connector does not require it and partitioning a schema-drift stream by only its derived columns is rejected by the Delta sink.
- **`ir-dataflow-warm`** — a custom Azure Integration Runtime (serverless Spark) sized by `dataFlowCoreCount` with a `dataFlowTimeToLiveMinutes` warm pool, so hourly runs reuse one cluster instead of paying the cold-start each time.
- **`pl_export_container_window_delta`** — a pipeline that runs the data flow for one container/window on the warm runtime.
- **`pl_discover_and_export_azmon_to_delta`** — the master pipeline that discovers `am-*` containers and runs the export for each.

### Why a warm Integration Runtime

A Mapping Data Flow runs on a Spark cluster. A **cold** cluster takes about 3–5 minutes to start before any data moves, and you pay for that. With an hourly pipeline that is a lot of wasted startup time. A **warm** runtime keeps the cluster alive for a short time-to-live after each run, so the next run reuses it. Microsoft recommends a custom Azure IR with TTL for operationalized pipelines. Alternatives: cold on-demand `compute` (simplest, most expensive per run); a larger cluster running less often (lower latency tolerance); or a shared factory-level TTL pool (good when many data flows exist).

### Validate the data flow in Studio before using it

A Mapping Data Flow is a Spark job written in ADF's data-flow script language. The definition in this template is a working starting point but **must be validated in a Data Factory Studio debug session** before you rely on it, because the exact source/sink script options can need small adjustments for your data.

1. Deploy the template.
2. In Data Factory Studio, open **Author → Data flows → `df_json_to_delta`**.
3. Turn on the **Data flow debug** slider (top bar). This starts an interactive debug Spark cluster (billed per hour while on — turn it off when done).
4. Use **Data preview** on each step (source → sink) to confirm the schema looks right. Fix any flagged script options.
5. Run `pl_export_container_window_delta` with **Debug** for one small container (for example `am-signinlogs`) and a recent window. In the run dialog, set `sourceWorkspaceResourceId` (so source listing stays fast) and `containerName` to the full `am-` name, then confirm a `_delta_log/` appears in the target folder.
6. Publish, then federate the table to confirm rows are returned end to end.

### Turning data flow debug logging on/off

The `pl_export_container_window_delta` pipeline has a **`dataFlowDebugLogging`** parameter:

- `true` → the data flow runs with trace level **Fine** (verbose, per-partition logging) — use while troubleshooting.
- `false` (default) → trace level **None** (summary only) — use for normal runs; it is cheaper and faster.

This is separate from the interactive **Data flow debug** slider above: the slider is for authoring/preview, while `dataFlowDebugLogging` controls how much detail a real pipeline run records.

### Where to find the debug logs

There are no debug *files* written to the storage account — data flow logs live in Data Factory monitoring:

- **ADF Studio → Monitor → Pipeline runs** → open the run → click the `WriteDeltaTable` activity, then the **eyeglasses** icon for the data flow detail view: execution plan, rows read/written per transformation, partition counts, stage timings, and cluster startup time. With `dataFlowDebugLogging = true` this includes per-partition detail.
- **Activity output JSON** → the activity's output contains `runStatus.metrics` with `rowsWritten` / `rowsRead` per sink and source.
- **Log Analytics** (when `logAnalyticsWorkspaceId` is set) → the existing diagnostic settings send `ADFActivityRun` records to the workspace. Query them with KQL, for example:

  ```kusto
  ADFActivityRun
  | where ActivityType == "ExecuteDataFlow"
  | where Status in ("Failed", "Succeeded")
  | project TimeGenerated, ActivityName, Status, Error, Output
  | order by TimeGenerated desc
  ```

### Running on a permanent hourly schedule

Two resources drive the schedule:

- **`pl_discover_and_export_azmon_to_delta`** discovers the matching `am-*` containers and runs `pl_export_container_window_delta` for each one.
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

To run the schedule for only some tables, set `tableAllowList` to a comma-separated list of source container names (including the `am-` prefix); leave it empty to process every container matching `sourceContainerPrefix`. This is the same parameter described in [Testing with a subset of tables](#testing-with-a-subset-of-tables), and it applies to both manual and scheduled runs.

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
| `dataFlowCoreCount` | No | Spark cores for the warm data flow Integration Runtime. `8` is cheapest; `16` is the recommended production minimum. | `8` |
| `dataFlowTimeToLiveMinutes` | No | Warm-cluster time-to-live in minutes for the data flow Integration Runtime. Keeps the Spark cluster warm between hourly runs. `0` disables the warm pool. | `10` |
| `logAnalyticsWorkspaceId` | No | Optional Log Analytics workspace resource ID for Data Factory diagnostics. Leave empty to disable diagnostics. | `/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.OperationalInsights/workspaces/<workspace-name>` |
| `tags` | No | Tags applied to the Data Factory. | `{ "workload": "sentinel-bcdr" }` |


## Cost estimations

See [COST.md](COST.md) for an estimated monthly cost (about 2 TB/day), a breakdown of the public rates involved (Azure Monitor data export, UAE North → Southeast Asia cross-region egress, ADLS Gen2, and Data Flow compute), and the main cost levers.