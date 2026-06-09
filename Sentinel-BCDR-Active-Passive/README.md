# Sentinel BCDR Active/Passive ADF Deployment

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fsmedin4%2FSecurity-bits%2Fmain%2FSentinel-BCDR-Active-Passive%2Fazuredeploy.json)

This mini-project deploys an Azure Data Factory pipeline that copies Azure Monitor Data Export blobs from a source storage account into static Snappy-compressed Parquet files in a target ADLS Gen2 account.

The deployment is intentionally parameter-driven for public use. Do not commit real subscription IDs, resource group names, storage account names, workspace names, tenant IDs, user identities, or other environment-specific values.

## What It Deploys

- Azure Data Factory with a system-assigned managed identity.
- Source Azure Blob Storage linked service using managed identity authentication.
- Target ADLS Gen2 linked service.
- Source JSON-lines and target Parquet datasets.
- A child copy pipeline for a single container and time window.
- A master discovery pipeline that lists matching source containers.
- Optional schedule trigger.
- Optional diagnostic settings to Log Analytics.

## Prerequisites

Before deploying, create or identify:

- A source storage account that receives Azure Monitor Data Export blobs.
- Source containers that match the configured prefix, usually `am-`.
- A target ADLS Gen2 storage account and file system for Parquet output.
- Permissions to deploy Azure Data Factory in the target resource group.
- Permissions to grant post-deployment RBAC roles on the source and target storage scopes.

This template does not configure Azure Monitor Data Export. Configure export separately so blobs already land in the source storage account.

## Deploy

Use the Deploy to Azure button above, or deploy with Azure CLI:

```powershell
az deployment group create `
  --resource-group <deployment-resource-group> `
  --template-file azuredeploy.json `
  --parameters @azuredeploy.parameters.json
```

Copy `azuredeploy.parameters.example.json` to `azuredeploy.parameters.json` before adding real values. The local `azuredeploy.parameters.json` file is ignored by this subfolder's `.gitignore`.

## Parameters

| Parameter | Required | Description | Example |
| --- | --- | --- | --- |
| `dataFactoryName` | Yes | Name of the Azure Data Factory to create. Must be globally unique for Data Factory. | `<data-factory-name>` |
| `location` | No | Azure region for the Data Factory. Defaults to the deployment resource group's location when omitted. | `eastus` |
| `sourceStorageAccountUrl` | Yes | Blob service endpoint for the Azure Monitor Data Export source account. | `https://<source-storage-account>.blob.core.windows.net` |
| `sourceStorageAccountResourceId` | Yes | ARM resource ID of the source storage account. Used by the master pipeline to list containers. | `/subscriptions/<subscription-id>/resourceGroups/<source-resource-group>/providers/Microsoft.Storage/storageAccounts/<source-storage-account>` |
| `targetStorageAccountUrl` | Yes | DFS endpoint for the target ADLS Gen2 account. | `https://<target-storage-account>.dfs.core.windows.net` |
| `targetFileSystem` | No | Target ADLS Gen2 file system/container name. | `sentinel-bcdr` |
| `targetRootPath` | No | Optional root folder prefix below the target file system. Leave empty so each source container becomes a top-level table folder (required for Sentinel data lake federation discovery). | `` (empty) |
| `sourceContainerPrefix` | No | Prefix used to select source containers. Azure Monitor export containers commonly use `am-`. | `am-` |
| `sourceWildcardFolderPath` | No | Wildcard folder path below each source container. | `WorkspaceResourceId=*` |
| `sourceFilePattern` | No | File pattern for source export blobs. | `PT5M*.json` |
| `triggerFrequency` | No | Schedule trigger frequency. Allowed values: `Minute`, `Hour`, `Day`, `Week`. | `Hour` |
| `triggerInterval` | No | Schedule trigger interval. Must be at least `1`. | `1` |
| `triggerStartTimeUtc` | No | UTC start time for the schedule trigger. Leave empty to skip trigger creation. | `2026-06-04T00:00:00Z` |
| `processingDelayHours` | No | Hours to wait before processing. Default processes the previous complete hour. | `1` |
| `hourlyTables` | No | Comma-separated source container names to partition by hour instead of day. All other tables use day partitioning. Use the full container name including the `am-` prefix. | `am-microsoftgraphactivitylogs,am-azurediagnostics` |
| `logAnalyticsWorkspaceId` | No | Optional Log Analytics workspace resource ID for Data Factory diagnostics. Leave empty to disable diagnostics. | `/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.OperationalInsights/workspaces/<workspace-name>` |
| `tags` | No | Tags applied to the Data Factory. | `{ "workload": "sentinel-bcdr" }` |

## Post-Deployment RBAC

After deployment, use the `dataFactoryPrincipalId` output to grant the Data Factory managed identity access to storage.

```powershell
$principalId = "<data-factory-principal-id>"
$sourceScope = "/subscriptions/<subscription-id>/resourceGroups/<source-resource-group>/providers/Microsoft.Storage/storageAccounts/<source-storage-account>"
$targetScope = "/subscriptions/<subscription-id>/resourceGroups/<target-resource-group>/providers/Microsoft.Storage/storageAccounts/<target-storage-account>"

az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --role Reader --scope $sourceScope
az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --role "Storage Blob Data Reader" --scope $sourceScope
az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --role "Storage Blob Data Contributor" --scope $targetScope
```

The `Reader` role is required on the source storage account so the master pipeline can list containers through Azure Resource Manager. `Storage Blob Data Reader` is required to read source blobs. `Storage Blob Data Contributor` is required to write Parquet output to the target ADLS Gen2 account or file system.

## Output Layout

Each source container becomes a top-level table folder directly under the target file system, with Hive-style date partitions. This matches what the Sentinel data lake federation connector discovers (one folder per table). The `sourceContainerPrefix` (default `am-`) is stripped from the folder name, so the `am-signinlogs` container is written as the `signinlogs` table folder.

By default, tables are partitioned by day. Containers listed in `hourlyTables` are partitioned by hour instead, which improves time-range pruning for very high-volume tables.

```text
[<targetRootPath>/]<table>/year=<yyyy>/month=<MM>/day=<dd>/[hour=<HH>/]<file>.parquet
```

Here `<table>` is the source container name with the `am-` prefix removed.

- Day-partitioned (default): `signinlogs/year=2026/month=06/day=08/<file>.parquet`
- Hour-partitioned (listed in `hourlyTables`): `signinlogs/year=2026/month=06/day=08/hour=05/<file>.parquet`

Leave `targetRootPath` empty so the container is the top-level table folder. A non-empty `targetRootPath` adds a prefix that the federation connector does not expect.

The copy activity uses `copyBehavior: FlattenHierarchy`, so the source blob's own folder hierarchy is not mirrored into the target. Azure Monitor continuous export writes each blob under a deep `WorkspaceResourceId=/subscriptions/.../workspaces/<name>/y=/m=/d=/h=/m=/` path; flattening drops all of those source segments and writes the Parquet files directly into the descriptive `year=/month=/day=/[hour=/]` folders above. File names are auto-generated by Data Factory.

> **Single-workspace limitation.** Flattening discards the source `WorkspaceResourceId` path, so all data for a table is merged into one table folder with no workspace dimension. This template assumes a single Log Analytics workspace per target container. If more than one workspace exports the same table into the same container, their rows are combined in one folder with no way to tell them apart. To support multiple workspaces, add a `WorkspaceResourceId` column (or a workspace-level root prefix) before flattening. Revisit this if you onboard additional workspaces.

Full timestamps are preserved in the `TimeGenerated` column, so sub-partition (hour, minute, second) filtering still works in queries even when data is partitioned by day.

### Partitioning and file size

The pipeline runs hourly, so the number of files is the same whether you partition by day or hour; only the folder layout and query pruning change.

- Day partitioning: fewer folders, coarser time pruning. Good default for most tables.
- Hour partitioning: more folders, finer time pruning. Use `hourlyTables` for very high-volume tables (for example, a table approaching hundreds of GB per day) so time-bounded queries scan one hour instead of a whole day.

Individual Parquet file size is bounded by the source export window, not by a row cap. Azure Monitor continuous export writes one `PT5M` blob per five-minute window, and the copy uses `FlattenHierarchy`, so each source blob becomes one auto-named Parquet file. Even the largest tables (hundreds of GB/day) produce sub-gigabyte Parquet files per window, which keeps file sizes in the efficient range without any row-count setting. (`maxRowsPerFile` is intentionally not set: Data Factory rejects it together with `FlattenHierarchy`, and it is unnecessary here because the five-minute windows already bound file size.)

Approximate size relationship for the same records: Sentinel-billed raw bytes are about 25 percent smaller than the incoming JSON, and Parquet+Snappy is typically 4-6x smaller than the raw volume. For example, a table at 800 GB/day of raw Sentinel volume lands at roughly 120-215 GB/day as Parquet+Snappy, or about 0.4-0.7 GB per five-minute Parquet file.

### Parallelism

The master pipeline discovers all matching `am-*` containers and copies them in parallel. The degree of parallelism is set by the `ForEach` activity's `batchCount` (16 in this template), which is the upper bound; the actual number of concurrent copies is the smaller of `batchCount` and the number of matching containers. Raising it speeds up the hourly run when there are many tables, at the cost of higher peak load on the storage accounts. If you see `503 ServerBusy` throttling, lower `batchCount` in the `pl_discover_and_export_azmon_to_parquet` pipeline definition (it is an integer literal on the `ForEach` activity, not a deployment parameter).

## Viewing Parquet Output

Parquet is a binary columnar format, so the output files cannot be read in a text editor. Visual Studio Code shows "The file is not displayed in the text editor because it is either binary or uses an unsupported text encoding." This is expected and is not caused by Snappy compression; uncompressed Parquet is also binary.

To inspect a Parquet file:

- Install the `dvirtz.parquet-viewer` VS Code extension, which renders Parquet as JSON or CSV (supports Snappy; files up to 50 MB).
- Or use the Azure Storage browser preview, Python (`pandas`/`pyarrow`), `parquet-tools`, or an analytics engine such as Synapse, Fabric, or Azure Data Explorer.

Compression trade-offs:

- Snappy (this template's default): smaller files, faster analytics reads, native support in Sentinel, Spark, and Fabric. Not human-readable as text, but neither is uncompressed Parquet.
- No compression: still binary and unreadable as text, while using more storage and slowing scans. Do not disable compression to make files readable.
- Optional JSON/CSV debug copy: readable, but adds pipeline cost, extra storage, duplicate data, and loses the columnar benefits. Only consider this for targeted debugging.

## Sentinel Data Lake Federation

To federate this Parquet output into the Microsoft Sentinel data lake using the Azure Data Lake Storage Gen2 connector:

- Use the account endpoint as the connector URL, for example `https://<account>.dfs.core.windows.net/`. The connector rejects container or folder paths; it discovers tables from the folder layout inside the account.
- The connector discovers one table per folder. With this layout, each container appears as a table with table path `<filesystem>/<table>`, where `<table>` is the container name with the `am-` prefix removed (for example, `sentinel-bcdr/signinlogs`).
- Federated tables appear in Sentinel as `<table>_<instanceName>`, where `<instanceName>` is the connector instance name. For example, the `am-azuremetrics` container becomes the `azuremetrics` table and federates as `azuremetrics_<instanceName>`.
- If a federated table name contains characters that are not valid KQL identifiers, bracket it in KQL, for example `['azuremetrics_<instanceName>']`.
- Grant the connector's service principal the `Storage Blob Data Reader` role on the target storage account, enable Hierarchical namespace on the account, and grant the Sentinel platform identity (prefixed `msg-resources-`) access to the Key Vault secret.
- The connector requires **Delta Parquet** format: each table folder must contain a `_delta_log/` transaction log alongside its `.snappy.parquet` data files. Plain Parquet with no `_delta_log/` is not discovered and the table shows "No data available". A `TimeGenerated` column enables enhanced lake features and preserves original event times; without it, federated rows are timestamped at query time.

> **The current pipeline output is plain Parquet and is therefore not yet federatable.** Making the pipeline emit Delta (writing a `_delta_log/`) or adding a downstream convert step is a separate, deferred task. The sample tables below prove the Delta requirement independently of the pipeline.

If federation shows "No data available" with zero tables, first confirm each table folder is a **Delta** table (it contains a `_delta_log/` subfolder) — plain Parquet alone is never discovered. Then confirm the output uses this layout (each container as a top-level folder, with no extra `targetRootPath` prefix and no `table=` segment), that the Parquet files sit directly under the `year=/month=/day=/` folders with no `WorkspaceResourceId=/subscriptions/.../` source path beneath them, and that the service principal has `Storage Blob Data Reader` on the account. A deep `WorkspaceResourceId=` path under each partition means the copy is mirroring the source hierarchy; redeploy the latest template, which sets `copyBehavior: FlattenHierarchy` to prevent that.

### Testing federation with sample Delta tables

The connector only reads **Delta** tables: a folder is recognized as a table only when it contains a `_delta_log/` transaction log, and the Delta reader serves **only** the data files listed in that log. Plain `.snappy.parquet` files with no `_delta_log/`, or extra Parquet files not referenced by the log, are ignored.

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

If the copy activity fails with `TypeConversionConnectorNotSupported` and mentions `JsonPathV2`, redeploy the latest template. JSON source files are treated as hierarchical data by Data Factory, and ADF type conversion is supported only for tabular data shapes. This template keeps the JSON-to-Parquet copy translator minimal so Data Factory does not enable unsupported type conversion for the JSON source.

If the copy activity fails with `MaxRowsPerFileNotSupportSuchCopyBehavior`, redeploy the latest template. Data Factory does not allow `maxRowsPerFile` together with the `FlattenHierarchy` (or `mergeFiles`) copy behavior. This template needs `FlattenHierarchy` to drop the source `WorkspaceResourceId=` path, so it does not set `maxRowsPerFile`; output file size is bounded by the five-minute source export window instead. This template also does not set a file name prefix, so Data Factory auto-generates Parquet part file names inside each partition folder.

If federation shows "No data available" and the storage browser shows Parquet files buried under a `.../day=.../WorkspaceResourceId=/subscriptions/<guid>/.../workspaces/<name>/y=/m=/d=/h=/m=/` path, the copy was mirroring the source blob hierarchy. Redeploy the latest template. The Parquet sink uses `copyBehavior: FlattenHierarchy`, which writes files directly into the descriptive `year=/month=/day=/[hour=/]` partitions and drops the source path. The `WorkspaceResourceId=` segment is an invalid Hive partition (its value contains `/` and a GUID), so the connector cannot discover partitions until it is gone.

If a later run fails with an authorization error, confirm the Data Factory managed identity has the post-deployment RBAC assignments above. For ADLS Gen2 accounts with hierarchical namespace ACLs, also confirm the identity has execute permission on parent folders and write permission on the target path.