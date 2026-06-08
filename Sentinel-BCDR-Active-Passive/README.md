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
| `maxConcurrentContainers` | No | Maximum parallel source containers processed by the master pipeline. Valid range: `1` to `50`. | `8` |
| `hourlyTables` | No | Comma-separated source container names to partition by hour instead of day. All other tables use day partitioning. | `am-microsoftgraphactivitylogs,am-azurediagnostics` |
| `maxRowsPerFile` | No | Maximum rows per output Parquet file to cap file size for high-volume tables. Tiny tables stay in one file. | `1000000` |
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

Each source container becomes a top-level table folder directly under the target file system, with Hive-style date partitions. This matches what the Sentinel data lake federation connector discovers (one folder per table).

By default, tables are partitioned by day. Containers listed in `hourlyTables` are partitioned by hour instead, which improves time-range pruning for very high-volume tables.

```text
[<targetRootPath>/]<container>/year=<yyyy>/month=<MM>/day=<dd>/[hour=<HH>/]<file>.parquet
```

- Day-partitioned (default): `<container>/year=2026/month=06/day=08/<file>.parquet`
- Hour-partitioned (listed in `hourlyTables`): `<container>/year=2026/month=06/day=08/hour=05/<file>.parquet`

Leave `targetRootPath` empty so the container is the top-level table folder. A non-empty `targetRootPath` adds a prefix that the federation connector does not expect.

The copy activity uses `copyBehavior: FlattenHierarchy`, so the source blob's own folder hierarchy is not mirrored into the target. Azure Monitor continuous export writes each blob under a deep `WorkspaceResourceId=/subscriptions/.../workspaces/<name>/y=/m=/d=/h=/m=/` path; flattening drops all of those source segments and writes the Parquet files directly into the descriptive `year=/month=/day=/[hour=/]` folders above. File names are auto-generated by Data Factory.

> **Single-workspace limitation.** Flattening discards the source `WorkspaceResourceId` path, so all data for a table is merged into one table folder with no workspace dimension. This template assumes a single Log Analytics workspace per target container. If more than one workspace exports the same table into the same container, their rows are combined in one folder with no way to tell them apart. To support multiple workspaces, add a `WorkspaceResourceId` column (or a workspace-level root prefix) before flattening. Revisit this if you onboard additional workspaces.

Full timestamps are preserved in the `TimeGenerated` column, so sub-partition (hour, minute, second) filtering still works in queries even when data is partitioned by day.

### Partitioning and file size

The pipeline runs hourly, so the number of files is the same whether you partition by day or hour; only the folder layout and query pruning change.

- Day partitioning: fewer folders, coarser time pruning. Good default for most tables.
- Hour partitioning: more folders, finer time pruning. Use `hourlyTables` for very high-volume tables (for example, a table approaching hundreds of GB per day) so time-bounded queries scan one hour instead of a whole day.

Individual Parquet file size is controlled by `maxRowsPerFile`, not by the partition granularity. Set it to cap file size in the 0.5-1 GB range for large tables. Tiny tables never reach the cap and stay in a single file.

Approximate size relationship for the same records: Sentinel-billed raw bytes are about 25 percent smaller than the incoming JSON, and Parquet+Snappy is typically 4-6x smaller than the raw volume. For example, a table at 800 GB/day of raw Sentinel volume lands at roughly 120-215 GB/day as Parquet+Snappy. To tune `maxRowsPerFile`, measure actual Parquet bytes per row after a run (file size divided by row count) and set `maxRowsPerFile = target_bytes / bytes_per_row`.

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
- The connector discovers one table per folder. With this layout, each `am-*` container appears as a table with table path `<filesystem>/<container>`.
- Federated tables appear in Sentinel as `<table>_<instanceName>`, where `<instanceName>` is the connector instance name. For example, `am-azuremetrics` becomes `am-azuremetrics_<instanceName>`.
- Because the table names contain a hyphen, bracket them in KQL, for example `['am-azuremetrics_<instanceName>']`.
- Grant the connector's service principal the `Storage Blob Data Reader` role on the target storage account, enable Hierarchical namespace on the account, and grant the Sentinel platform identity (prefixed `msg-resources-`) access to the Key Vault secret.
- Parquet and delta are supported formats. A `TimeGenerated` column enables enhanced lake features; the pipeline preserves it from the source data.

If federation shows "No data available" with zero tables, confirm the output uses this layout (each container as a top-level folder, with no extra `targetRootPath` prefix and no `table=` segment), that the Parquet files sit directly under the `year=/month=/day=/` folders with no `WorkspaceResourceId=/subscriptions/.../` source path beneath them, and that the service principal has `Storage Blob Data Reader` on the account. A deep `WorkspaceResourceId=` path under each partition means the copy is mirroring the source hierarchy; redeploy the latest template, which sets `copyBehavior: FlattenHierarchy` to prevent that.

## Troubleshooting

If the copy activity fails with `TypeConversionConnectorNotSupported` and mentions `JsonPathV2`, redeploy the latest template. JSON source files are treated as hierarchical data by Data Factory, and ADF type conversion is supported only for tabular data shapes. This template keeps the JSON-to-Parquet copy translator minimal so Data Factory does not enable unsupported type conversion for the JSON source.

If the copy activity fails with `FileNamePrefixNotSupportSpecifyWithoutMaxRowsPerFile`, redeploy the latest template. Data Factory only supports `fileNamePrefix` for Parquet writes when `maxRowsPerFile` is also configured. This template does not set a file name prefix, so Data Factory auto-generates Parquet part file names inside each partition folder.

If federation shows "No data available" and the storage browser shows Parquet files buried under a `.../day=.../WorkspaceResourceId=/subscriptions/<guid>/.../workspaces/<name>/y=/m=/d=/h=/m=/` path, the copy was mirroring the source blob hierarchy. Redeploy the latest template. The Parquet sink uses `copyBehavior: FlattenHierarchy`, which writes files directly into the descriptive `year=/month=/day=/[hour=/]` partitions and drops the source path. The `WorkspaceResourceId=` segment is an invalid Hive partition (its value contains `/` and a GUID), so the connector cannot discover partitions until it is gone.

If a later run fails with an authorization error, confirm the Data Factory managed identity has the post-deployment RBAC assignments above. For ADLS Gen2 accounts with hierarchical namespace ACLs, also confirm the identity has execute permission on parent folders and write permission on the target path.