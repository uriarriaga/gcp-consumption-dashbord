# Looker Studio Calculated Fields: Cloning & Linking API Behavior

This guide explains how **Calculated Fields** behave when a Looker Studio report template (such as `c7991054-d499-4aa0-9b2a-e8f98d92ea55`) is cloned and bound to a new BigQuery view using `create_looker_studio_dashboard.py` (the Looker Studio Linking API).

---

## 1. Are Calculated Fields Copied When a New Dashboard is Created?

It depends on **where** the calculated field was created in the template report. Looker Studio supports two distinct scopes for calculated fields:

| Calculated Field Type | How It Is Created in Looker Studio | Copied When Cloning Dashboard? | Technical Reason |
| :--- | :--- | :--- | :--- |
| **1. Chart-Level (Report-Level) Calculated Field** | Select a chart/scorecard → **Setup panel** → **Add metric** (or **Add dimension**) → **Create field** | **✅ YES — Automatically Copied** | The formula is stored inside the **Report layout definition** (`c.reportId`). When the report is cloned, Looker Studio evaluates the formula against the matching column names (`net_cost`, `ai_category`, `gross_cost`, etc.) in the newly connected BigQuery view (`ds0`). |
| **2. Data Source–Level Calculated Field** | Top menu → **Resource** → **Manage added data sources** → **Edit** → **Add a field** | **❌ NO — Not Copied** | The Linking API (`ds.ds0.connector=bigQuery`) generates a **brand-new BigQuery data source** directly from the target table/view schema (`vw_ai_consumption_master`). Because the new data source only knows about columns that physically exist in BigQuery, any Data Source–level custom fields from the original template are lost and will trigger an `Invalid Metric / Unknown Field` error on charts that use them. |

---

## 2. Best Practices: Guaranteeing 100% Automatic Cloning

To ensure that every chart and scorecard works immediately out-of-the-box when a client runs `create_looker_studio_dashboard.py`—without requiring manual field creation—use the two-tier approach below:

### Rule 1: Put Row-Level Calculations Directly in the BigQuery View (`vw_ai_consumption_master`)
Any calculation that operates on a **single row** (or converts units, parses strings, or floors negative values) is defined as a native SQL column inside `vw_ai_consumption_master` in `deploy_ai_dashboard.sh`.

Because BigQuery exposes these as physical view columns, Looker Studio imports them automatically when connecting to `ds0`.

**Implemented Columns in `vw_ai_consumption_master`:**
```sql
-- 1. Estimated Million Tokens (row-level unit conversion)
CASE
  WHEN usage.unit = 'token' THEN usage.amount / 1000000.0
  ELSE usage.amount
END AS estimated_million_tokens,

-- 2. Non-negative Net Cost (prevents Donut/Pie chart errors)
GREATEST(0.0, cost + COALESCE((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)) AS net_cost,

-- 3. Absolute Total Credits / Savings
ABS(COALESCE((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)) AS abs_total_credits,

-- 4. Isolated GenAI Net Cost (enables straightforward ratio aggregation)
CASE
  WHEN ai_category = 'Generative AI' THEN net_cost
  ELSE 0.0
END AS genai_net_cost
```

---

### Rule 2: Put Ratio / Aggregated Calculations as **Chart-Level Fields** in the Template Report
Ratios and percentages (such as `GenAI Spend %` or `Effective Discount %`) must be aggregated **after** filtering (`SUM(A) / SUM(B)`), so they cannot be pre-calculated row-by-row in SQL.

Instead of creating these inside the Data Source editor, create them directly on the Scorecard/Chart inside your master template (`c7991054-d499-4aa0-9b2a-e8f98d92ea55`):

1. Open the master template report in **Edit** mode (`https://lookerstudio.google.com/reporting/c7991054-d499-4aa0-9b2a-e8f98d92ea55`).
2. Click on the target **Scorecard** or **Chart**.
3. In the right-hand **Setup** panel, under **Metric**, click the current metric (or **Add metric**).
4. Click **+ Create field** at the bottom of the field picker dropdown.
5. Enter the **Name**, **Formula**, and **Type**, then click **Apply**:

| Metric Name | Chart-Level Formula | Data Type | Visual Format |
| :--- | :--- | :--- | :--- |
| **Effective Discount %** | `SAFE_DIVIDE(SUM(abs_total_credits), SUM(gross_cost))` | Numeric | **Percent** |
| **GenAI Spend %** | `SAFE_DIVIDE(SUM(genai_net_cost), SUM(net_cost))` | Numeric | **Percent** |
| **Cost per Million Tokens** | `SAFE_DIVIDE(SUM(net_cost), SUM(estimated_million_tokens))` | Numeric | **Currency (USD)** |

Because these formulas live on the visual widget in the template report and only reference base columns (`genai_net_cost`, `net_cost`, `abs_total_credits`, `gross_cost`, `estimated_million_tokens`) that exist in `vw_ai_consumption_master`, they are **100% preserved** whenever the dashboard is cloned.

