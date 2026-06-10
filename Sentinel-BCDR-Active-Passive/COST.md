# Cost estimations

Estimated monthly cost using public pay-as-you-go USD rates. **These are planning estimates — confirm in the [Azure Pricing Calculator](https://azure.microsoft.com/pricing/calculator/) for your agreement and exact regions.** Source storage is in **UAE North**; the target ADLS Gen2 and Data Factory are in **Southeast Asia**.

**Assumptions:** ~2 TB/day raw Sentinel volume → about 2.66 TB/day as JSON export (JSON is roughly 33% larger) → about **80 TB/month** transferred cross-region.

| Cost item | Public rate | Approx. monthly |
| --- | --- | --- |
| Azure Monitor Data Export (pre-existing) | $0.10 / GB | ~$8,000 |
| UAE North source storage (rolling JSON staging) | ~$0.02 / GB-month | ~$300–400 |
| **Cross-region egress UAE North → Southeast Asia** | $0.08 / GB | **~$6,400** |
| Southeast Asia ADLS Gen2 (Hot, grows with retention) | ~$0.02 / GB-month | ~$120+ |
| ADLS Gen2 transactions | ~$0.07 / 10k writes | ~$75 |
| Data Factory orchestration (activity runs) | $1 / 1,000 runs | ~$40 |
| **Option A Data Flow compute** (warm 8–16 vCore IR, tuned) | $0.274 / vCore-hour | **~$1,100–1,700** |
| **Estimated total (month 1)** | | **~$16,100–16,700** |

Notes:

- **Cross-region egress (~$6,400) dominates the new spend and is unavoidable** for a cross-region BCDR copy — it is the same regardless of which Delta approach is used.
- The Delta approach only changes the **compute** line. Option A (Data Flow) ~$1,100–1,700; the alternative Copy + Azure Function approach would be ~$600–900; Databricks ~$1,200–2,000 plus operations. The difference (a few hundred dollars) is small next to the egress.
- **Cost levers:** use `tableAllowList` to test cheaply on a few tables; move long-term Southeast Asia data to **Cool/Archive** tiers (50–80% cheaper storage); keep one **warm shared** Data Flow cluster (low `ForEach` concurrency) rather than many concurrent clusters; keep source-side retention short with a storage lifecycle policy.

Pricing references: [Azure Monitor](https://azure.microsoft.com/pricing/details/monitor/), [Data Factory](https://azure.microsoft.com/pricing/details/data-factory/data-pipeline/), [Bandwidth](https://azure.microsoft.com/pricing/details/bandwidth/), [ADLS Gen2 / Blob Storage](https://azure.microsoft.com/pricing/details/storage/data-lake/).
