# Comparison & Gap Analysis: `Executive_Deck` vs. Looker Studio AI Consumption Dashboard

This document provides a side-by-side comparison between the **`Executive_Deck`** tab in **[CHS GCP Billing_Reports, 2026-07-01 — 2026-07-31](https://docs.google.com/spreadsheets/d/1kt7y_eUUUmi44dj-eivcVk7rv77lgFId1nsFvMmjoL4/edit?resourcekey=0-KdYqUhxw-epPp4D4rVL0Ww&gid=298915128#gid=298915128)** and the **Looker Studio AI Consumption Dashboard (`vw_ai_consumption_master`)**.

---

## 1. Executive Summary

| Dimension | `Executive_Deck` (Google Sheet) | Looker Studio Dashboard (`vw_ai_consumption_master`) |
| :--- | :--- | :--- |
| **Primary Audience** | C-Level / FinOps Executives | Engineering Leads, FinOps Analysts, Platform Teams |
| **Time Horizon** | **Static 1-Month Snapshot** (July 1 – July 31, 2026) | **Live Rolling Time-Series** (Daily granularity, 365-day lookback, MoM comparisons) |
| **Granularity** | Aggregated monthly by **Service** and **Top 10 SKUs** across the entire portfolio (`$10,243.72` net) | Granular by **Day**, **Project**, **Region**, **Team/Environment Labels**, **Service**, and **SKU** |
| **Core Strength** | **Executive FinOps Storytelling**: Top cost drivers, subscription seat audits, and qualitative FinOps action plans (`$1,200–$1,800/mo` addressable savings) | **Operational & Engineering Telemetry**: Daily spend trends, token volume tracking, model-family breakdowns, team showback, and automated anomaly alerts |

---

## 2. KPI Scorecard Comparison

| KPI Card | `Executive_Deck` Tab | Looker Studio Dashboard | Difference / Gap |
| :--- | :--- | :--- | :--- |
| **Net Spend** | `TOTAL NET SPEND` (`$10,243.72`) | `Total AI Net Spend` (`SUM(net_cost)`) | **Identical definition** (List cost minus negotiated/promotional savings). |
| **Gross Cost** | `GROSS LIST COST` (`$11,073.20`) | `Total Gross Cost` (`SUM(gross_cost)`) | **Identical definition** (`cost` before discounts). |
| **Savings / Credits** | `TOTAL SAVINGS REALIZED` (`$829.51` / `7.5% discount`) | `Credits / Discounts` (`SUM(total_credits)`) | `Executive_Deck` explicitly displays the **Effective Discount % (`7.5%`)** alongside the dollar savings; Looker Studio only shows the dollar sum by default. |
| **4th KPI Card** | **`TOP SKU CONCENTRATION` (`37.4%` — Vector Search Index Serving)** | **`GenAI Share %`** (`GenAI Spend / Total Spend`) | **Different metric**: `Executive_Deck` highlights **Single-SKU Concentration Risk** (top SKU share of total spend), whereas Looker Studio highlights **GenAI % of Total AI Spend**. |

---

## 3. Service & SKU Taxonomy Gaps (Critical Findings)

Analyzing the actual July 2026 billing data in `Executive_Deck` reveals **4 major AI services and SKU patterns** in CHS's real workload that are categorized differently or excluded by the current `vw_ai_consumption_master` SQL logic:

| Workload / SKU in `Executive_Deck` | July 2026 Net Spend | How `Executive_Deck` Treats It | How Current Looker Studio View (`vw_ai_consumption_master`) Treats It |
| :--- | :--- | :--- | :--- |
| **1. Vector Search Index Serving** (`Vector Search Index Serving e2-standard-16`, `Vertex AI`) | **`$3,835.35`** (`37.4%` of total spend — **#1 SKU**) | Highlighted as the **#1 Cost Driver** under "Infrastructure & Vector Search Dominance" (`5,948.64 server hours`). | Falls into the generic `Perception & Cognitive AI` fallback bucket and `model_or_resource_family = 'Vertex AI'`, because current regexes do not explicitly classify `Vector Search`. |
| **2. Enterprise Subscriptions** (`Duet AI: Gemini Code Assist`, `Vertex AI Search: Gemini Enterprise Plus / Standard`) | **`$3,784.70`** (`36.9%` of total spend) | Tracked as **Enterprise Subscription Commitments** (`76.69 months` of Code Assist + `53.63 months` of Enterprise Search). | **Excluded / Missing**: `Duet AI` and `Vertex AI Search` are not in the `service.description IN (...)` whitelist of `vw_ai_consumption_master` (which only listed `'Discovery Engine'` and `'Generative AI Support'`). |
| **3. Gemini 2.5 / 3.5 & "Thinking" Tokens** (`Gemini 2.5 Flash Thinking Text Output`, `Gemini 2.5 Pro Thinking`, `Gemini 3.5 Flash`) | **`~$1,700+`** across Gemini 2.5/3.5 SKUs | Distinguishes **Standard Output** (`$180.30`) vs. **Thinking Text Output** (`$690.63` reasoning tokens) and **Long Context Input**. | Current view regex only parses `Gemini 1.5 Pro`, `Gemini 1.5 Flash`, and `Gemini 2.0`. **Gemini 2.5 / 3.5** fall into the generic `Vertex AI` bucket, and **Thinking Tokens** are grouped with regular `Output (Response)`. |
| **4. Gemini API (Direct)** (`service.description = 'Gemini API'`) | **`$103.00`** | Included as a top-level service alongside `Vertex AI`. | Excluded by the `service.description` filter (which only captures `Vertex AI`, not `Gemini API`). |

---

## 4. Visual & Analytical Content Comparison

| Feature / Section | `Executive_Deck` (Google Sheet) | Looker Studio Dashboard |
| :--- | :--- | :--- |
| **Service Summary Table** | 4-row table (`Vertex AI`, `Vertex AI Search`, `Duet AI`, `Gemini API`) with List Cost, Savings, and Net Spend | Donut Chart + Bar Chart by `ai_category` and `model_or_resource_family` |
| **Top 10 SKU Table** | Dedicated **Top 10 SKU concentration table** showing exact SKU description, usage quantity (`5,948.64 hours`, `76.69 months`, `2.15B tokens`), and % concentration (`96.0% of spend`) | Full SKU table on Page 2, but not filtered to "Top 10 SKUs with % of Total Portfolio Spend" |
| **Time-Series Trends** | None (single month total) | **Daily Stacked Area Chart + 7-Day Moving Average** |
| **Project / Team Showback** | None (portfolio-wide rollup only) | **Treemap & Bar Chart by Project, Team, Environment (`prod`/`staging`/`dev`), and Cost Center** |
| **FinOps Recommendations & Action Plan** | **Narrative Executive Briefing** (Vector Search replica tuning, Gemini seat audit, Context Caching rollout, GPU CUD evaluation) with estimated savings (`$1,200–$1,800/mo`) | **Automated Anomaly Detection Table** (`vw_ai_cost_anomaly_alerts`), but no narrative recommendations panel |

---

## 5. Summary of Recommendations (If Aligning Both Reports)

To make the Looker Studio dashboard (`vw_ai_consumption_master`) 100% aligned with the real CHS workload in `Executive_Deck`, the following additions are recommended:

### A. Expand `service.description` Filter in `vw_ai_consumption_master`
Add the missing Google Cloud AI services to the `WHERE` clause:
- `'Duet AI'` (Gemini Code Assist subscriptions)
- `'Vertex AI Search'` (Gemini Enterprise Plus / Standard 1-Yr subscriptions)
- `'Gemini API'` (Direct Gemini 2.5 / 3.5 API calls)

### B. Update `ai_category` and `model_or_resource_family` CASE Statements
Add classification rules for the top CHS spend drivers:
1. **Vector Search**:
   ```sql
   WHEN REGEXP_CONTAINS(sku_description, r'(?i)Vector Search|Matching Engine') THEN 'Vector Search & Embeddings Infra'
   ```
2. **Subscriptions (Code Assist & Enterprise Search)**:
   ```sql
   WHEN REGEXP_CONTAINS(sku_description, r'(?i)Subscription|Code Assist|Gemini Enterprise|Notebook Enterprise') THEN 'Enterprise AI Subscriptions (Seats)'
   ```
3. **Gemini 2.5 & Gemini 3.5 Models**:
   ```sql
   WHEN REGEXP_CONTAINS(sku_description, r'(?i)Gemini.*2\.5.*Pro') THEN 'Gemini 2.5 Pro'
   WHEN REGEXP_CONTAINS(sku_description, r'(?i)Gemini.*2\.5.*Flash') THEN 'Gemini 2.5 Flash'
   WHEN REGEXP_CONTAINS(sku_description, r'(?i)Gemini.*3\.5') THEN 'Gemini 3.5 Flash/Pro'
   ```
4. **Thinking (Reasoning) Token Modality**:
   ```sql
   WHEN REGEXP_CONTAINS(sku_description, r'(?i)Thinking') THEN 'Output (Thinking / Reasoning)'
   ```

### C. Add 2 Visuals from `Executive_Deck` to Looker Studio Page 1
1. **Effective Discount % Scorecard**:
   - Calculated Field: `ABS(SUM(total_credits)) / SUM(gross_cost)` (formatted as Percent).
2. **Top 10 SKU Concentration Table**:
   - Dimensions: `sku_description`, `service_name`, `usage_unit`
   - Metrics: `SUM(usage_amount)`, `SUM(net_cost)`, `% of Total net_cost`
   - Sort by `net_cost` descending, limited to **Top 10 rows**.
