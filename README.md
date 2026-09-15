# Google Cloud AI Consumption & Cost Dashboard

A turnkey toolkit that transforms your **Google Cloud Billing Export (BigQuery)** into a curated **AI / GenAI consumption and cost dashboard** in Looker Studio.

---

## Table of Contents

1. [Objective](#1-objective)
2. [What's Included](#2-whats-included)
3. [Architecture](#3-architecture)
4. [How the Deployment Script Works](#4-how-the-deployment-script-works)
5. [Implementation Guide: Using an Existing GCP Billing Export Table](#5-implementation-guide-using-an-existing-gcp-billing-export-table)
6. [Master View Schema Reference](#6-master-view-schema-reference)
7. [Building the Looker Studio Dashboard](#7-building-the-looker-studio-dashboard)
8. [Customization](#8-customization)
9. [Troubleshooting](#9-troubleshooting)
10. [FAQ](#10-faq)

---

## 1. Objective

Google Cloud's standard billing export contains every SKU across every service, which makes it hard to answer AI-specific questions such as:

- *How much are we spending on Gemini vs. Claude vs. Imagen?*
- *What is our input (prompt) vs. output (response) token cost ratio?*
- *Which team or project is driving GPU / TPU spend?*
- *Did any project's AI spend spike unexpectedly yesterday?*

This toolkit solves that by deploying a **single, curated BigQuery view** (`vw_ai_consumption_master`) on top of your existing billing export that:

| Capability | Description |
| :--- | :--- |
| **AI-only filtering** | Isolates Vertex AI, Generative AI, Conversational AI, Document/Vision/Speech AI, and GPU/TPU compute SKUs from all other cloud spend. |
| **Category classification** | Buckets spend into `Generative AI`, `Agentic & Conversational AI`, `AI Compute (GPU/TPU)`, and `Perception & Cognitive AI`. |
| **Model-family parsing** | Extracts model families from SKU descriptions (Gemini 1.5 Pro / Flash, Gemini 2.0, Anthropic Claude, Imagen, Embeddings, A100 / H100 / L4 GPUs, TPUs). |
| **Token modality** | Splits GenAI SKUs into `Input (Prompt)`, `Output (Response)`, and `Context Cache`. |
| **True net cost** | Computes `net_cost = gross_cost + credits` (credits are negative in the export) so CUDs, SUDs, and promotions are reflected. |
| **Chargeback labels** | Surfaces `team`, `environment`, `cost_center`, and `app` labels for showback / chargeback. |
| **Anomaly detection** | A companion view (`vw_ai_cost_anomaly_alerts`) flags any project whose daily AI spend exceeds 1.8× its 7-day rolling average. |

The result is a Looker Studio-ready data source that requires **no custom SQL in the BI layer**.

---

## 2. What's Included

| File | Purpose |
| :--- | :--- |
| `deploy_ai_dashboard.sh` | Interactive Bash deployment script. Creates the dataset, (optionally) sample data, and both BigQuery views. |
| `gcp_ai_consumption_dashboard_guide.md` | Client-facing step-by-step guide including chart-by-chart Looker Studio configuration. |
| `create_looker_studio_dashboard.py` | Generates a one-click Looker Studio **Linking API** URL that copies the public template (`c7991054-d499-4aa0-9b2a-e8f98d92ea55`) and re-binds it to your BigQuery view. |
| `README.md` | This file. |

---

## 3. Architecture

```mermaid
flowchart LR
    A["Cloud Billing Export<br/>(gcp_billing_export_v1_XXXX)"] -->|Already exists| B["BigQuery View<br/>vw_ai_consumption_master"]
    B --> C["BigQuery View<br/>vw_ai_cost_anomaly_alerts"]
    B -->|Looker Studio Linking API<br/>(Copies Template c7991054-...)| D["Looker Studio Dashboard"]
    C -->|Scheduled query / alert| E["Email / Chat notification"]
```

> [!NOTE]
> The toolkit **never modifies or copies** your billing export table. Both deployed objects are *views*, so they always reflect the latest exported data and add no storage cost.

---

## 4. How the Deployment Script Works

`deploy_ai_dashboard.sh` is an interactive Bash script that wraps the `gcloud` and `bq` CLIs. It performs the following steps:

### Step 0 — Pre-flight checks
- Verifies `gcloud` and `bq` are installed and on `PATH`.
- Reads the current `gcloud` project and prompts you to confirm or override it.

### Step 1 — Dataset provisioning
- Prompts for a **target dataset ID** (default: `ai_billing_dashboard`) and **location** (default: `US`).
- Runs `bq mk --dataset` only if the dataset does not already exist (idempotent).

> [!IMPORTANT]
> The target dataset **must be in the same location** as your billing export dataset (typically `US` or `EU`). BigQuery views cannot reference tables across locations.

### Step 2 — Data source selection
The script offers two modes:

| Mode | When to use | What happens |
| :--- | :--- | :--- |
| **1 – Production** | You have an existing billing export table. | You are prompted for the fully-qualified table path. **No data is generated or copied.** |
| **2 – Demo** | Sandbox / Argolis project with no billing export. | Creates `sample_ai_billing_export` with 60 days of synthetic, schema-compatible data. |

### Step 3 — Deploy `vw_ai_consumption_master`
Executes a `CREATE OR REPLACE VIEW` statement that:
1. Filters the source table to AI services and GPU/TPU compute SKUs.
2. Flattens the `credits` array into `total_credits` and computes `net_cost`.
3. Unnests the `labels` array into `label_env`, `label_team`, `label_cost_center`, `label_app`.
4. Adds the derived columns `ai_category`, `model_or_resource_family`, and `modality_type` via `REGEXP_CONTAINS` on `sku.description`.

### Step 4 — Deploy `vw_ai_cost_anomaly_alerts`
Creates a second view over the master view that aggregates daily net cost per project / category, computes a trailing 7-day average with a window function, and returns only rows where today's spend is `> $50` **and** `> 1.8×` the baseline.

### Step 5 — Summary
Prints the fully-qualified names of the deployed views and the Looker Studio connection steps.

---

## 5. Implementation Guide: Using an Existing GCP Billing Export Table

Follow this section if your organization **already exports Cloud Billing data to BigQuery**.

### 5.1 Prerequisites

| Requirement | Details |
| :--- | :--- |
| **Billing export enabled** | *Standard usage cost* export (table `gcp_billing_export_v1_<BILLING_ACCOUNT_ID>`) or *Detailed usage cost* export (`gcp_billing_export_resource_v1_<BILLING_ACCOUNT_ID>`). See [Set up Cloud Billing data export to BigQuery](https://cloud.google.com/billing/docs/how-to/export-data-bigquery-setup). |
| **IAM on the billing export dataset** | `roles/bigquery.dataViewer` (read the export). |
| **IAM on the target project** | `roles/bigquery.dataEditor` (create dataset & views) and `roles/bigquery.jobUser` (run queries). |
| **Local tooling** | `gcloud` CLI with the `bq` component (`gcloud components install bq`), authenticated via `gcloud auth login`. |

### 5.2 Locate your billing export table

In the BigQuery console, or via CLI:

```bash
# List datasets in the billing project
bq ls --project_id=<BILLING_PROJECT_ID>

# List tables in the billing dataset
bq ls <BILLING_PROJECT_ID>:<BILLING_DATASET_ID>
```

Note the **fully-qualified table path** in the form:

```
<BILLING_PROJECT_ID>.<BILLING_DATASET_ID>.gcp_billing_export_v1_XXXXXX_XXXXXX_XXXXXX
```

Confirm the dataset **location** (`US`, `EU`, or a region):

```bash
bq show --format=prettyjson <BILLING_PROJECT_ID>:<BILLING_DATASET_ID> | grep location
```

### 5.3 (Optional) Verify AI spend exists

```sql
SELECT
  service.description AS service_name,
  COUNT(1)            AS line_items,
  ROUND(SUM(cost), 2) AS gross_cost
FROM `<BILLING_PROJECT_ID>.<BILLING_DATASET_ID>.gcp_billing_export_v1_XXXXXX_XXXXXX_XXXXXX`
WHERE _PARTITIONDATE >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)
  AND (
    service.description IN ('Vertex AI', 'Document AI', 'Discovery Engine', 'Dialogflow CX',
                            'Cloud Vision API', 'Cloud Translation API', 'Cloud Speech-to-Text API')
    OR (service.description = 'Compute Engine'
        AND REGEXP_CONTAINS(sku.description, r'(?i)Nvidia|A100|H100|L4|T4|TPU'))
  )
GROUP BY 1
ORDER BY gross_cost DESC;
```

### 5.4 Run the deployment script

```bash
chmod +x deploy_ai_dashboard.sh
./deploy_ai_dashboard.sh
```

Answer the prompts as follows:

| Prompt | Value |
| :--- | :--- |
| `Enter your Project ID` | The project where you want the views created (can be the billing project or a separate analytics project). |
| `Enter BigQuery Dataset ID` | e.g. `ai_billing_dashboard` |
| `Enter BigQuery Dataset Location` | **Must match** the billing export dataset location from §5.2 (e.g. `US`). |
| `Select option [1 or 2]` | **`1`** (Production mode) |
| `Enter full path to Billing Export table` | The fully-qualified path from §5.2. |

Expected output:

```
Step 1: Ensuring BigQuery dataset 'ai_billing_dashboard' exists...
Dataset created successfully.
Step 3: Deploying Unified Master View 'vw_ai_consumption_master'...
Master View '<PROJECT>.ai_billing_dashboard.vw_ai_consumption_master' deployed successfully!
Step 4: Deploying Anomaly Alert View 'vw_ai_cost_anomaly_alerts'...
Anomaly alert view deployed.
Deployment Completed Successfully!
```

### 5.5 Manual deployment (without the script)

If you prefer to run SQL directly in the BigQuery console, copy the `CREATE OR REPLACE VIEW` statement from **Step 2** of `gcp_ai_consumption_dashboard_guide.md`, and replace the placeholder table path with your real export table. The only change required between demo and production is the `FROM` clause:

```sql
FROM `<BILLING_PROJECT_ID>.<BILLING_DATASET_ID>.gcp_billing_export_v1_XXXXXX_XXXXXX_XXXXXX`
```

> [!TIP]
> If you use the *Detailed* (resource-level) export, the schema is a superset of the standard export, so the same view definition works unchanged. You may additionally expose `resource.name` and `resource.global_name` for per-endpoint or per-VM attribution.

### 5.6 Validate the view

```sql
SELECT
  ai_category,
  model_or_resource_family,
  ROUND(SUM(gross_cost), 2)     AS gross_usd,
  ROUND(SUM(total_credits), 2)  AS credits_usd,
  ROUND(SUM(net_cost), 2)       AS net_usd
FROM `<PROJECT>.ai_billing_dashboard.vw_ai_consumption_master`
WHERE usage_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)
GROUP BY 1, 2
ORDER BY net_usd DESC;
```

Every row should show a non-negative `net_usd`, and the model families should match the SKUs you actually consume.

### 5.7 Grant dashboard viewers access

Looker Studio viewers using **Owner's credentials** need no BigQuery access. If you use **Viewer's credentials**, grant each viewer:

```bash
# On the analytics project (views)
gcloud projects add-iam-policy-binding <PROJECT> \
  --member="user:<viewer>@example.com" --role="roles/bigquery.jobUser"

bq add-iam-policy-binding --member="user:<viewer>@example.com" \
  --role="roles/bigquery.dataViewer" <PROJECT>:ai_billing_dashboard
```

> [!NOTE]
> Because the views are **not authorized views** by default, viewers also need `roles/bigquery.dataViewer` on the underlying billing export dataset. To avoid exposing the raw export, configure the views as [authorized views](https://cloud.google.com/bigquery/docs/authorized-views) on the billing dataset.

---

## 6. Master View Schema Reference

`vw_ai_consumption_master` exposes the following columns:

| Column | Type | Description |
| :--- | :--- | :--- |
| `billing_account_id` | STRING | Billing account that incurred the charge. |
| `usage_date` | DATE | `DATE(usage_start_time)`; use as the Looker Studio date dimension. |
| `invoice_month` | STRING | `YYYYMM` invoice period. |
| `project_id` / `project_name` | STRING | Consuming project. |
| `region` | STRING | Region where usage occurred. |
| `service_id` / `service_name` | STRING | Google Cloud service (e.g. `Vertex AI`). |
| `sku_id` / `sku_description` | STRING | Raw SKU identifiers. |
| `usage_amount` / `usage_unit` | FLOAT64 / STRING | Metered usage (tokens, requests, hours, pages…). |
| `gross_cost` | FLOAT64 | List-price cost before credits. |
| `total_credits` | FLOAT64 | Sum of all credits on the line (negative value). |
| `net_cost` | FLOAT64 | `GREATEST(0, gross_cost + total_credits)`. |
| `currency` | STRING | Billing currency. |
| `label_env` / `label_team` / `label_cost_center` / `label_app` | STRING | Extracted from the `labels` array. |
| `ai_category` | STRING | `Generative AI` \| `Agentic & Conversational AI` \| `AI Compute (GPU/TPU)` \| `Perception & Cognitive AI` |
| `model_or_resource_family` | STRING | `Gemini 1.5 Pro`, `Gemini 1.5 Flash`, `Gemini 2.0`, `Anthropic Claude`, `Imagen`, `Embeddings`, `Provisioned Throughput`, `NVIDIA A100 GPU`, `NVIDIA H100 GPU`, `NVIDIA L4 GPU`, `Google Cloud TPU`, or the service name. |
| `modality_type` | STRING | `Input (Prompt)` \| `Output (Response)` \| `Context Cache` \| `API Request / Hourly` |

---

## 7. Building the Looker Studio Dashboard

### 7.1 One-click template cloning

Run the helper script to generate a pre-bound Looker Studio URL that **copies the public template report** (`https://datastudio.google.com/reporting/c7991054-d499-4aa0-9b2a-e8f98d92ea55`) and automatically maps its data source (`ds0`) to your BigQuery view:

```bash
python3 create_looker_studio_dashboard.py <PROJECT> ai_billing_dashboard vw_ai_consumption_master
```

Open the printed URL; Looker Studio clones the template and attaches your BigQuery data source automatically.

Alternatively, to build a blank report from scratch in Looker Studio: **Create → Data source → BigQuery →** `<PROJECT>` **→** `ai_billing_dashboard` **→** `vw_ai_consumption_master` **→ Connect → Create Report**.

### 7.2 Recommended data-source settings

| Field | Type | Aggregation |
| :--- | :--- | :--- |
| `usage_date` | Date (YYYYMMDD) | — |
| `net_cost`, `gross_cost`, `total_credits` | Currency (USD) | Sum |
| `usage_amount` | Number | Sum |

Add two calculated fields:

```
GenAI Spend %          = SUM(CASE WHEN ai_category = 'Generative AI' THEN net_cost ELSE 0 END) / SUM(net_cost)
Estimated Million Tokens = CASE WHEN usage_unit = 'token' THEN usage_amount / 1000000 ELSE usage_amount END
```

### 7.3 Suggested page layout

| Page | Components |
| :--- | :--- |
| **Executive Overview** | Date-range control · dropdowns for `ai_category`, `project_name`, `label_env` · scorecards (Net Spend w/ previous-period comparison, Gross, Credits, GenAI %) · stacked time-series by `ai_category` · donut by `ai_category` |
| **GenAI Deep-Dive** | Page filter `ai_category = 'Generative AI'` · horizontal bar by `model_or_resource_family` · pivot table `model_or_resource_family` × `modality_type` with tokens and net cost |
| **Attribution** | Treemap `label_team` → `project_name` · table by `label_cost_center`, `label_env` with % of total |
| **AI Infrastructure** | Page filter `ai_category = 'AI Compute (GPU/TPU)'` · scorecard accelerator hours · donut by accelerator type · table by `project_name`, `region`, `sku_description` |

Full chart-by-chart instructions are in `gcp_ai_consumption_dashboard_guide.md`.

### 7.4 Anomaly alerting (optional)

Create a BigQuery **scheduled query** that runs daily against `vw_ai_cost_anomaly_alerts` and writes results to a table, then attach a Looker Studio table widget or a Cloud Monitoring / Pub/Sub notification to that table.

---

## 8. Customization

| What to change | Where |
| :--- | :--- |
| **Label keys** (e.g. your org uses `env` instead of `environment`) | Edit the four `(SELECT value FROM UNNEST(labels) WHERE key = '...')` lines in the view. |
| **Add / remove AI services** | Edit the `service.description IN (...)` list in the `WHERE` clause. |
| **New model families** (e.g. Gemini 2.5, Llama on Vertex) | Add `WHEN REGEXP_CONTAINS(sku_description, r'(?i)...') THEN '...'` branches to the `model_or_resource_family` CASE. |
| **Look-back window** | Change `INTERVAL 365 DAY` in the view's `WHERE` clause to limit scanned partitions. |
| **Anomaly sensitivity** | Adjust `daily_net_cost > 50.0` and the `1.8` multiplier in `vw_ai_cost_anomaly_alerts`. |
| **Currency** | If your billing account is not in USD, `cost` is already in the account currency; relabel the Looker Studio currency type accordingly. |

---

## 9. Troubleshooting

| Symptom | Cause | Fix |
| :--- | :--- | :--- |
| `Not found: Dataset ... was not found in location` | Target dataset location ≠ billing export location. | Re-create the target dataset in the same location as the export (`bq mk --location=<LOC>`). |
| `Access Denied: BigQuery BigQuery: Permission denied while getting Drive credentials` | N/A — appears if Looker Studio credentials lack BigQuery access. | Grant `roles/bigquery.jobUser` on the project and `roles/bigquery.dataViewer` on both datasets (see §5.7). |
| **Pie / Donut chart shows "Chart configuration incomplete" or renders blank** | Negative metric values. Looker Studio cannot draw pie slices for negative sums. | Already handled by `GREATEST(0.0, …)` in `net_cost`. If you removed it, add a chart-level filter `net_cost > 0`. |
| `Invalid field name "_PARTITIONDATE"` when creating a table | You are materializing the view into a table; pseudo-columns cannot be selected. | Partition by `DATE(usage_start_time)` instead, or exclude `_PARTITIONDATE` from the `SELECT`. |
| `Unexpected keyword ROWS` | `rows` is a reserved word in GoogleSQL. | Do not alias a column as `rows`; use `row_count`. |
| Dashboard is slow | Each widget queries the view directly. | Enable **BI Engine** on the analytics project, or schedule a nightly materialization of the view into a partitioned table and point Looker Studio to that table. |
| Model shows as `Vertex AI` instead of a specific family | SKU description does not match any regex branch. | Inspect `sku_description` for that row and add a new `WHEN` branch (see §8). |

---

## 10. FAQ

**Does the script contain dummy data?**
Only in **Demo mode (option 2)**. In **Production mode (option 1)** the script creates views over your real export and generates no data.

**Will this affect my billing export or incur storage cost?**
No. Only views are created; nothing is copied. Query cost is incurred when the dashboard runs, proportional to the partitions scanned.

**Can I point the view at multiple billing accounts?**
Yes. Replace the `FROM` clause with a `UNION ALL` of the export tables, or use a wildcard table if they live in the same dataset.

**Does it work with the FOCUS export?**
Not directly — the FOCUS schema uses different column names (`BilledCost`, `ServiceName`, `ChargeCategory`, …). The classification logic is portable, but the `SELECT` list would need to be remapped.

**How current is the data?**
Cloud Billing export latency is typically a few hours. The dashboard reflects whatever has landed in the export table at query time.
