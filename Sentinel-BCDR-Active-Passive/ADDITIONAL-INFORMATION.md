# Additional information

Supporting reference material for the Sentinel BCDR Active/Passive ADF deployment. For setup and day-to-day use, start with [README.md](README.md).

- [Cost estimations](#cost-estimations)
- [Viewing the Parquet data files](#viewing-the-parquet-data-files)
- [Testing federation with sample Delta tables](#testing-federation-with-sample-delta-tables)
- [Troubleshooting](#troubleshooting)

## Cost estimations

Estimated monthly cost using public pay-as-you-go USD rates. **These are planning estimates — confirm in the [Azure Pricing Calculator](https://azure.microsoft.com/pricing/calculator/) for your agreement and exact regions.** Source storage is in **UAE North**; the target ADLS Gen2 and Data Factory are in **Southeast Asia**.

**Assumptions:** ~2 TB/day raw Sentinel volume → about 2.66 TB/day as JSON export (JSON is roughly 33% larger) → about **80 TB/month** transferred cross-region.

| Cost item | Public rate | Approx. monthly |
| --- | --- | --- |
| Azure Monitor Data Export (pre-existing) | $0.10 / GB | ~$8,000 |
| UAE North source storage (rolling JSON staging) | ~$0.02 / GB-month | ~$300–400 |
| **Cross-region egress UAE North → Southeast Asia** | $0.08 / GB | **~$6,400** |
| Southeast Asia ADLS Gen2 (Hot, grows with retention) | ~$0.02 / GB-month | ~$120+ |
| ADLS Gen2 transactions | ~$0.07 / 10k writes | ~$75 |
| Data Factory orchestration (activity runs) | $1 / 1,000 runs | ~$75 |
| **Data Flow compute** (warm 8-vCore IR, hourly) | $0.274 / vCore-hour | **~$3,000–3,500** |
| **Estimated total (month 1)** | | **~$18,000–18,400** |

### What the Data Flow compute actually costs

In the deployed factory's resource group, the **Azure Data Factory v2 vCore** meter billed about **$102.66/day** (≈$3,080/month), with orchestration at ~$2.48/day and every other ADF meter under $0.01/day. That matches the design:

- The hourly master pipeline fans out with `ForEach` `batchCount: 4`, so up to **four 8-vCore Spark clusters** run concurrently each hour.
- The warm Integration Runtime TTL is **10 minutes**, but hourly runs are **60 minutes apart**, so in steady state **every run cold-starts** a fresh cluster (the warm pool only helps when runs are closer together than the TTL). Each run pays ~3–5 min of startup plus execution.
- Roughly: 24 runs/day × ~15 vCore-hours/run ≈ 370 vCore-hours/day × $0.274 ≈ **$100/day ≈ $3,000/month**.

> **The Data Flow compute is now the second-largest cost after cross-region egress** — about double the earlier estimate. The earlier $1,100–1,700 figure assumed the warm pool absorbed startup, which does not happen at an hourly cadence with a 10-minute TTL.

> **Refreshing the schema before every export adds a small increment.** The schema refresh now runs before each hourly export (previously daily) so newly added tables are typed correctly from their first export. That is one extra short Data Flow per hour with its own cold start — roughly **$10–15/day (~$300–450/month)**.

> **Confirm with a few pure-hourly days.** The $102.66/day sample included heavy manual testing. Watch 2–3 days of unattended hourly runs to get the true steady-state figure.

### Cost levers

- **Cross-region egress (~$6,400) dominates the new spend and is unavoidable** for a cross-region BCDR copy — it is the same regardless of which Delta approach is used.
- **Run less often.** Data Flow compute scales almost linearly with run frequency: every 2 hours roughly halves it, every 3 hours roughly thirds it — at the cost of fresher data. Change `triggerInterval` (and `processingDelayHours` if needed).
- **Lower `batchCount`.** Fewer concurrent clusters cost less per hour but make each hourly run take longer. Adjust it in the `pl_discover_and_export_azmon_to_delta` pipeline definition.
- **Match the TTL to the cadence, or accept cold starts.** A 10-minute `dataFlowTimeToLiveMinutes` gives no benefit at hourly spacing. Either shorten the interval below the TTL so clusters are reused, or leave it — the cold start is unavoidable at hourly cadence.
- **Use `tableAllowList` while testing** so the largest tables and their transfer are excluded until you are ready.
- **Tier the target.** Move long-term Southeast Asia data to **Cool/Archive** tiers (50–80% cheaper storage).
- **Keep source-side retention short** with a storage lifecycle policy.

Pricing references: [Azure Monitor](https://azure.microsoft.com/pricing/details/monitor/), [Data Factory](https://azure.microsoft.com/pricing/details/data-factory/data-pipeline/), [Bandwidth](https://azure.microsoft.com/pricing/details/bandwidth/), [ADLS Gen2 / Blob Storage](https://azure.microsoft.com/pricing/details/storage/data-lake/).

## Viewing the Parquet data files

The Delta table's data files are Parquet, a binary columnar format, so they cannot be read in a text editor. Visual Studio Code shows "The file is not displayed in the text editor because it is either binary or uses an unsupported text encoding." This is expected and is not caused by Snappy compression; uncompressed Parquet is also binary.

To inspect a Parquet data file:

- Install the `dvirtz.parquet-viewer` VS Code extension, which renders Parquet as JSON or CSV (supports Snappy; files up to 50 MB).
- Or use the Azure Storage browser preview, Python (`pandas`/`pyarrow`), `parquet-tools`, or an analytics engine such as Synapse, Fabric, or Azure Data Explorer.

Compression trade-offs:

- Snappy (this template's default): smaller files, faster analytics reads, native support in Sentinel, Spark, and Fabric. Not human-readable as text, but neither is uncompressed Parquet.
- No compression: still binary and unreadable as text, while using more storage and slowing scans. Do not disable compression to make files readable.

## Testing federation with sample Delta tables

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

### Discovery succeeds but the target container is empty

If the discovery pipeline **succeeds but the target container is empty** (no `_delta_log/` or Parquet files appear), the `ForEach` ran zero iterations because discovery found no `am-*` containers. In Monitor, the run shows `ListSourceContainers` and `FilterMatchingContainers` succeeding and `ForEachMatchingContainer` finishing in under a second with **no** `ExportContainerWindowDelta` child. The usual cause is `sourceStorageAccountResourceId` pointing at the wrong account — most often the **target** ADLS Gen2 account instead of the source. It must be the **source** account that holds the `am-*` export containers, the **same account** as `sourceStorageAccountUrl`. Fix the value (keep both pointing at the same account), confirm the Data Factory managed identity has **Reader** on that source account (required for the Azure Resource Manager container listing) plus **Storage Blob Data Reader**, then redeploy and rerun. (A wrong account that the identity cannot read fails loudly with an authorization error instead; a wrong-but-readable account, such as the target, silently lists zero `am-*` containers.)

### Some exports fail with `DF-Executor-InvalidOutputColumns`

If some `ExportContainerWindowDelta` activities fail with `DF-Executor-InvalidOutputColumns` ("at Sink 'DeltaSink': The result has 0 output columns. Please ensure at least one column is mapped"), the affected tables had **no `PT5M` files in the processed hour**. The data flow source uses schema drift with no fixed columns, so an empty hour produces a stream with zero columns, and the Delta sink rejects an empty schema. The template avoids this by deriving an always-present `IngestedUtc` column (the UTC time the rows were written) before the sink, so the output schema is never empty: a quiet hour writes an empty (0-row) Delta commit instead of failing. If you still hit this error, redeploy the latest template. `IngestedUtc` is the processing time, not the event time — use the source `TimeGenerated` column for event-time queries.

### A table or some columns are missing from the data lake

The workspace schema map (`_schemas/workspace-schemas.json`) lists every table **declared** in the workspace, but the data lake only contains tables Azure Monitor actually **exports** as `am-<table>` source containers with `PT5M*.json` files in the processed window. If a federated table is missing, check that an `am-<table>` container exists in the source account and has files for the hour — if not, add the table to the Azure Monitor Data Export rule.

A Delta table also only contains the **columns present in the data it has already seen**: the source uses schema drift, so a column that was never populated in any processed window is not created yet. Because the sink uses `mergeSchema`, the column is added automatically the first time an event populates it — and, with native typing on, it lands as its declared native type. So a missing column is usually "not yet observed," not an error.

### A table fails with a Delta schema/type merge conflict

Native typing reads each table's **declared** column types (which are stable across runs), so the per-run schema does not drift and merge conflicts do not arise in normal operation. A conflict almost always means a table's existing Delta folder was written under a **different typing mode** than the current run — for example it was first written all-string (`enableNativeTypes = false`) and a later run wrote it native, or vice versa. Switching a column between string and a native type is an incompatible Delta change. **Fix:** delete that table's folder (including its `_delta_log/`) so the next run rebuilds it cleanly under the current mode, or point `targetFileSystem` at a fresh file system and re-point federation to it. A clean run against an empty target needs no resets.

### Source listing is slow

If a run spends several minutes on **Listing source** while reading only a handful of files, the source is enumerating the whole container. With the default `sourceWildcardFolderPath` (`WorkspaceResourceId=*`) and recursive listing, Data Factory walks every historical five-minute folder in the container before filtering by time, so listing time grows with the container's history. Set `sourceWorkspaceResourceId` to the exact path Azure Monitor writes after `WorkspaceResourceId=` (the workspace ARM ID, lowercased, beginning with `/subscriptions/`). The data flow source then lists only the processed hour's `y=/m=/d=/h=/` folder, so listing stays fast regardless of history. Copy the value from the storage browser to match its casing exactly; if a run lists zero files, clear the parameter to fall back to the wildcard path. This assumes a single workspace per source container.

> **Manual runs of the single-container pipeline.** The discovery pipeline carries your deployed values, but a manual **Debug** of `pl_export_container_window_delta` uses that pipeline's static defaults, where `sourceWorkspaceResourceId` is empty. If you leave it blank there, the source falls back to the `WorkspaceResourceId=*` wildcard and lists the whole container. Type `sourceWorkspaceResourceId` into the dialog, or run the discovery pipeline or the schedule instead. See [Supplying parameters for manual runs](README.md#supplying-parameters-for-manual-runs).

### Authorization errors, or the export is skipped entirely

If a later run fails with an authorization error, confirm the Data Factory managed identity has the post-deployment RBAC assignments in the README. For ADLS Gen2 accounts with hierarchical namespace ACLs, also confirm the identity has execute permission on parent folders and write permission on the target path.

If the **export is skipped entirely** with native typing on, confirm the managed identity has **Reader on the Log Analytics workspace** — the export refreshes the schema first and stops if that refresh fails.

### Validate the data flow in Studio

A Mapping Data Flow is a Spark job written in ADF's data-flow script language. The definitions in this template are a working starting point but can be validated in a Data Factory Studio debug session, because the exact source/sink script options can need small adjustments for your data.

1. In Data Factory Studio, open **Author → Data flows → `df_json_to_delta`** (or `df_json_to_delta_native`).
2. Turn on the **Data flow debug** slider (top bar). This starts an interactive debug Spark cluster (billed per hour while on — turn it off when done).
3. Use **Data preview** on each step (source → sink) to confirm the schema looks right. Fix any flagged script options.
4. Run `pl_export_container_window_delta` with **Debug** for one small container (for example `am-signinlogs`) and a recent window. In the run dialog, set `sourceWorkspaceResourceId` (so source listing stays fast) and `containerName` to the full `am-` name, then confirm a `_delta_log/` appears in the target folder.
5. Publish, then federate the table to confirm rows are returned end to end.

### Turning data flow debug logging on/off

The `pl_export_container_window_delta` pipeline has a **`dataFlowDebugLogging`** parameter:

- `true` → the data flow runs with trace level **Fine** (verbose, per-partition logging) — use while troubleshooting.
- `false` (default) → trace level **None** (summary only) — use for normal runs; it is cheaper and faster.

This is separate from the interactive **Data flow debug** slider above: the slider is for authoring/preview, while `dataFlowDebugLogging` controls how much detail a real pipeline run records.

### Where to find the data flow logs

There are no debug *files* written to the storage account — data flow logs live in Data Factory monitoring:

- **ADF Studio → Monitor → Pipeline runs** → open the run → click the data flow activity, then the **eyeglasses** icon for the data flow detail view: execution plan, rows read/written per transformation, partition counts, stage timings, and cluster startup time. With `dataFlowDebugLogging = true` this includes per-partition detail.
- **Activity output JSON** → the activity's output contains `runStatus.metrics` with `rowsWritten` / `rowsRead` per sink and source.
- **Log Analytics** (when `logAnalyticsWorkspaceId` is set) → the existing diagnostic settings send `ADFActivityRun` records to the workspace. Query them with KQL, for example:

  ```kusto
  ADFActivityRun
  | where ActivityType == "ExecuteDataFlow"
  | where Status in ("Failed", "Succeeded")
  | project TimeGenerated, ActivityName, Status, Error, Output
  | order by TimeGenerated desc
  ```
