# Sentinel BCDR Active/Passive ADF Deployment

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2F%3CGITHUB-OWNER%3E%2FSecurity-bits%2Fmain%2Fsentinel-bcdr-active-passive-adf%2Fazuredeploy.json)

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
| `targetRootPath` | No | Root folder path below the target file system. | `sentinel-bcdr` |
| `sourceContainerPrefix` | No | Prefix used to select source containers. Azure Monitor export containers commonly use `am-`. | `am-` |
| `sourceWildcardFolderPath` | No | Wildcard folder path below each source container. | `WorkspaceResourceId=*` |
| `sourceFilePattern` | No | File pattern for source export blobs. | `PT5M*.json` |
| `triggerFrequency` | No | Schedule trigger frequency. Allowed values: `Minute`, `Hour`, `Day`, `Week`. | `Hour` |
| `triggerInterval` | No | Schedule trigger interval. Must be at least `1`. | `1` |
| `triggerStartTimeUtc` | No | UTC start time for the schedule trigger. Leave empty to skip trigger creation. | `2026-06-04T00:00:00Z` |
| `processingDelayHours` | No | Hours to wait before processing. Default processes the previous complete hour. | `1` |
| `maxConcurrentContainers` | No | Maximum parallel source containers processed by the master pipeline. Valid range: `1` to `50`. | `8` |
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

The pipeline writes Parquet files below the configured target root path using this layout:

```text
<table-root>/table=<container>/year=<yyyy>/month=<MM>/day=<dd>/hour=<HH>/batch=<runId>
```

## Publishing Notes

Before publishing to Security-bits, replace `<GITHUB-OWNER>` in the Deploy to Azure button URL with the GitHub owner or organization that hosts the repository.
