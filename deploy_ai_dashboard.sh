#!/usr/bin/env bash
# ==============================================================================
# Deploy AI Consumption & Cost Dashboard in Argolis (Google Cloud)
#
# This script configures BigQuery views and optional sample billing data
# to power an AI Consumption & Cost Dashboard in Looker Studio / Looker.
# ==============================================================================

set -euo pipefail

# Text formatting
BOLD="\033[1m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
CYAN="\033[0;36m"
RED="\033[0;31m"
RESET="\033[0m"

echo -e "${BOLD}${CYAN}======================================================${RESET}"
echo -e "${BOLD}${CYAN}   Argolis AI Billing Dashboard - Automated Setup    ${RESET}"
echo -e "${BOLD}${CYAN}======================================================${RESET}\n"

# 1. Verify CLI requirements
command -v gcloud >/dev/null 2>&1 || { echo -e "${RED}Error: 'gcloud' CLI is not installed or not in PATH.${RESET}" >&2; exit 1; }
command -v bq >/dev/null 2>&1 || { echo -e "${RED}Error: 'bq' CLI is not installed or not in PATH.${RESET}" >&2; exit 1; }

# 2. Determine GCP Project
CURRENT_GCLOUD_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
read -r -p "$(echo -e "${YELLOW}Enter your Argolis Project ID [${CURRENT_GCLOUD_PROJECT}]: ${RESET}")" PROJECT_ID
PROJECT_ID=${PROJECT_ID:-$CURRENT_GCLOUD_PROJECT}

if [[ -z "$PROJECT_ID" ]]; then
  echo -e "${RED}Error: Project ID cannot be empty.${RESET}"
  exit 1
fi

echo -e "Setting active gcloud project to: ${GREEN}${PROJECT_ID}${RESET}"
gcloud config set project "$PROJECT_ID"

# 3. BigQuery Dataset & Mode Configuration
DEFAULT_DATASET="ai_billing_dashboard"
read -r -p "$(echo -e "${YELLOW}Enter BigQuery Dataset ID to create/use [${DEFAULT_DATASET}]: ${RESET}")" DATASET_ID
DATASET_ID=${DATASET_ID:-$DEFAULT_DATASET}

DEFAULT_LOCATION="US"
read -r -p "$(echo -e "${YELLOW}Enter BigQuery Dataset Location [${DEFAULT_LOCATION}]: ${RESET}")" LOCATION
LOCATION=${LOCATION:-$DEFAULT_LOCATION}

echo -e "\n${BOLD}Select your data source mode:${RESET}"
echo "  1) I have an existing GCP Cloud Billing Export table (Production mode)"
echo "  2) Create realistic Sample/Mock AI Billing data in Argolis (Demo mode)"
read -r -p "$(echo -e "${YELLOW}Select option [1 or 2, default: 2]: ${RESET}")" DATA_MODE
DATA_MODE=${DATA_MODE:-2}

# Create Dataset if not exists
echo -e "\n${CYAN}Step 1: Ensuring BigQuery dataset '${DATASET_ID}' exists...${RESET}"
if bq show --location="${LOCATION}" "${PROJECT_ID}:${DATASET_ID}" >/dev/null 2>&1; then
  echo -e "${GREEN}Dataset ${DATASET_ID} already exists.${RESET}"
else
  echo -e "Creating dataset ${DATASET_ID} in location ${LOCATION}..."
  bq --location="${LOCATION}" mk --dataset \
    --description="AI Billing and Consumption Analytics Dataset" \
    "${PROJECT_ID}:${DATASET_ID}"
  echo -e "${GREEN}Dataset created successfully.${RESET}"
fi

# Determine source table
if [[ "$DATA_MODE" == "1" ]]; then
  read -r -p "$(echo -e "${YELLOW}Enter full path to Billing Export table (e.g. your_proj.your_billing_ds.gcp_billing_export_v1_XXXXXX): ${RESET}")" SOURCE_TABLE
  if [[ -z "$SOURCE_TABLE" ]]; then
    echo -e "${RED}Error: Source billing table cannot be empty in mode 1.${RESET}"
    exit 1
  fi
else
  SOURCE_TABLE="${PROJECT_ID}.${DATASET_ID}.sample_ai_billing_export"
  echo -e "\n${CYAN}Step 2: Generating synthetic AI billing data in '${SOURCE_TABLE}' for demo...${RESET}"
  
  bq query --use_legacy_sql=false --location="${LOCATION}" "
  CREATE OR REPLACE TABLE \`${SOURCE_TABLE}\`
  PARTITION BY DATE(usage_start_time) AS
  WITH date_range AS (
    SELECT day
    FROM UNNEST(GENERATE_DATE_ARRAY(DATE_SUB(CURRENT_DATE(), INTERVAL 60 DAY), CURRENT_DATE())) AS day
  ),
  projects AS (
    SELECT 'argolis-genai-prod' AS project_id, 'GenAI Production' AS project_name, 'prod' AS env, 'NLP Core' AS team, 'CC-101' AS cost_center
    UNION ALL SELECT 'argolis-customer-cx', 'Customer CX Bot', 'prod', 'Support Automation', 'CC-102'
    UNION ALL SELECT 'argolis-docai-pipeline', 'Doc Processing Pipeline', 'staging', 'Finance Tech', 'CC-103'
    UNION ALL SELECT 'argolis-sandbox-dev', 'AI Research Lab', 'dev', 'Data Science', 'CC-104'
  ),
  services_and_skus AS (
    SELECT 'Vertex AI' AS service_name, 'C7E2-9256-1C43' AS service_id, 'Gemini 1.5 Pro - Input Prompt Tokens' AS sku_description, 'token' AS usage_unit, 180.0 AS base_daily_cost, 'Generative AI' AS cat
    UNION ALL SELECT 'Vertex AI', 'C7E2-9256-1C43', 'Gemini 1.5 Pro - Output Candidate Tokens', 'token', 320.0, 'Generative AI'
    UNION ALL SELECT 'Vertex AI', 'C7E2-9256-1C43', 'Gemini 1.5 Flash - Input Prompt Tokens', 'token', 65.0, 'Generative AI'
    UNION ALL SELECT 'Vertex AI', 'C7E2-9256-1C43', 'Gemini 1.5 Flash - Output Candidate Tokens', 'token', 110.0, 'Generative AI'
    UNION ALL SELECT 'Vertex AI', 'C7E2-9256-1C43', 'Gemini 2.0 Flash - Input Prompt Tokens', 'token', 95.0, 'Generative AI'
    UNION ALL SELECT 'Vertex AI', 'C7E2-9256-1C43', 'Gemini 2.0 Flash - Output Candidate Tokens', 'token', 145.0, 'Generative AI'
    UNION ALL SELECT 'Vertex AI', 'C7E2-9256-1C43', 'Claude 3.5 Sonnet - Input Tokens', 'token', 210.0, 'Generative AI'
    UNION ALL SELECT 'Vertex AI', 'C7E2-9256-1C43', 'Claude 3.5 Sonnet - Output Tokens', 'token', 390.0, 'Generative AI'
    UNION ALL SELECT 'Vertex AI', 'C7E2-9256-1C43', 'Text Embedding Gecko / Multimodal Embeddings', 'token', 45.0, 'Generative AI'
    UNION ALL SELECT 'Vertex AI', 'C7E2-9256-1C43', 'Imagen 3 - Image Generation', 'request', 125.0, 'Generative AI'
    UNION ALL SELECT 'Discovery Engine', 'A123-4567-8901', 'Vertex AI Search & Conversation Queries', 'request', 160.0, 'Agentic & Conversational AI'
    UNION ALL SELECT 'Dialogflow CX', 'B234-5678-9012', 'Dialogflow CX Conversation Sessions', 'request', 190.0, 'Agentic & Conversational AI'
    UNION ALL SELECT 'Document AI', 'D456-7890-1234', 'Document AI - Form Parser Pages', 'page', 140.0, 'Perception & Cognitive AI'
    UNION ALL SELECT 'Compute Engine', '6F81-5844-456A', 'NVIDIA A100 80GB GPU running in Americas', 'hour', 420.0, 'AI Compute (GPU/TPU)'
    UNION ALL SELECT 'Compute Engine', '6F81-5844-456A', 'NVIDIA H100 80GB GPU running in Americas', 'hour', 680.0, 'AI Compute (GPU/TPU)'
    UNION ALL SELECT 'Compute Engine', '6F81-5844-456A', 'NVIDIA L4 GPU running in Americas', 'hour', 150.0, 'AI Compute (GPU/TPU)'
    UNION ALL SELECT 'Compute Engine', '6F81-5844-456A', 'Cloud TPU v5e Pod Slice Running in us-central1', 'hour', 290.0, 'AI Compute (GPU/TPU)'
  )
  SELECT
    '01ABCD-23EF45-678901' AS billing_account_id,
    TIMESTAMP(d.day) AS usage_start_time,
    TIMESTAMP_ADD(TIMESTAMP(d.day), INTERVAL 1 DAY) AS usage_end_time,
    TIMESTAMP(CURRENT_TIMESTAMP()) AS export_time,
    STRUCT(
      p.project_id AS id,
      p.project_name AS name,
      '123456789' AS number,
      [STRUCT('env' AS key, p.env AS value)] AS labels,
      '' AS ancestry_numbers
    ) AS project,
    STRUCT(
      s.service_id AS id,
      s.service_name AS description
    ) AS service,
    STRUCT(
      GENERATE_UUID() AS id,
      s.sku_description AS description
    ) AS sku,
    STRUCT(
      'us-central1' AS location,
      'us-central1' AS region,
      'us-central1-a' AS zone,
      'US' AS country
    ) AS location,
    STRUCT(
      FORMAT_DATE('%Y%m', d.day) AS month
    ) AS invoice,
    'regular' AS cost_type,
    'USD' AS currency,
    1.0 AS currency_conversion_rate,
    STRUCT(
      CAST(ROUND(RAND() * 5000000 + 250000, 2) AS FLOAT64) AS amount,
      s.usage_unit AS unit,
      CAST(ROUND(RAND() * 5000000 + 250000, 2) AS FLOAT64) AS amount_in_pricing_units,
      s.usage_unit AS pricing_unit
    ) AS usage,
    ROUND(s.base_daily_cost * (0.7 + RAND() * 0.6), 2) AS cost,
    IF(RAND() > 0.4, [STRUCT('Committed Use Discount' AS name, ROUND(-1 * s.base_daily_cost * (0.08 + RAND() * 0.07), 2) AS amount, 'CUD Credit' AS full_name, 'CREDIT-1' AS id, 'DISCOUNT' AS type)], []) AS credits,
    [
      STRUCT('environment' AS key, p.env AS value),
      STRUCT('team' AS key, p.team AS value),
      STRUCT('cost_center' AS key, p.cost_center AS value),
      STRUCT('app' AS key, 'Enterprise AI Platform' AS value)
    ] AS labels,
    [] AS system_labels
  FROM date_range d
  CROSS JOIN projects p
  CROSS JOIN services_and_skus s;
  "
  echo -e "${GREEN}Sample billing export table populated successfully.${RESET}"
fi

# Step 3: Create the Master Dashboard View
echo -e "\n${CYAN}Step 3: Deploying Unified Master View 'vw_ai_consumption_master'...${RESET}"

bq query --use_legacy_sql=false --location="${LOCATION}" "
CREATE OR REPLACE VIEW \`${PROJECT_ID}.${DATASET_ID}.vw_ai_consumption_master\` AS
WITH raw_billing AS (
  SELECT
    billing_account_id,
    DATE(usage_start_time) AS usage_date,
    invoice.month AS invoice_month,
    project.id AS project_id,
    project.name AS project_name,
    location.region AS region,
    service.id AS service_id,
    service.description AS service_name,
    sku.id AS sku_id,
    sku.description AS sku_description,
    usage.amount AS usage_amount,
    usage.unit AS usage_unit,
    cost AS gross_cost,
    COALESCE((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0) AS total_credits,
    GREATEST(0.0, cost + COALESCE((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)) AS net_cost,
    currency,
    -- Extract organizational metadata
    (SELECT value FROM UNNEST(labels) WHERE key = 'environment') AS label_env,
    (SELECT value FROM UNNEST(labels) WHERE key = 'cost_center') AS label_cost_center,
    (SELECT value FROM UNNEST(labels) WHERE key = 'team') AS label_team,
    (SELECT value FROM UNNEST(labels) WHERE key = 'app') AS label_app
  FROM
    \`${SOURCE_TABLE}\`
  WHERE
    DATE(usage_start_time) >= DATE_SUB(CURRENT_DATE(), INTERVAL 365 DAY)
    AND (
      service.description IN (
        'Vertex AI',
        'Generative AI Support',
        'Cloud Vision API',
        'Cloud Natural Language API',
        'Cloud Translation API',
        'Cloud Speech-to-Text API',
        'Cloud Text-to-Speech API',
        'Document AI',
        'Dialogflow Enterprise Edition',
        'Dialogflow CX',
        'Discovery Engine'
      )
      OR (
        service.description = 'Compute Engine'
        AND REGEXP_CONTAINS(sku.description, r'(?i)Nvidia|A100|H100|V100|L4|T4|P100|TPU|Tensor')
      )
    )
)
SELECT
  *,
  CASE
    WHEN REGEXP_CONTAINS(sku_description, r'(?i)Gemini|Claude|PaLM|Imagen|Codey|Embeddings|Text Generation|Multimodal|Provisioned Throughput') THEN 'Generative AI'
    WHEN service_name IN ('Dialogflow Enterprise Edition', 'Dialogflow CX', 'Discovery Engine') THEN 'Agentic & Conversational AI'
    WHEN REGEXP_CONTAINS(sku_description, r'(?i)Nvidia|A100|H100|V100|L4|T4|P100|TPU') THEN 'AI Compute (GPU/TPU)'
    ELSE 'Perception & Cognitive AI'
  END AS ai_category,

  CASE
    WHEN REGEXP_CONTAINS(sku_description, r'(?i)Gemini.*1\.5.*Pro') THEN 'Gemini 1.5 Pro'
    WHEN REGEXP_CONTAINS(sku_description, r'(?i)Gemini.*1\.5.*Flash') THEN 'Gemini 1.5 Flash'
    WHEN REGEXP_CONTAINS(sku_description, r'(?i)Gemini.*2\.0') THEN 'Gemini 2.0'
    WHEN REGEXP_CONTAINS(sku_description, r'(?i)Claude') THEN 'Anthropic Claude'
    WHEN REGEXP_CONTAINS(sku_description, r'(?i)Imagen') THEN 'Imagen'
    WHEN REGEXP_CONTAINS(sku_description, r'(?i)Embedding') THEN 'Embeddings'
    WHEN REGEXP_CONTAINS(sku_description, r'(?i)Provisioned Throughput') THEN 'Provisioned Throughput'
    WHEN REGEXP_CONTAINS(sku_description, r'(?i)A100') THEN 'NVIDIA A100 GPU'
    WHEN REGEXP_CONTAINS(sku_description, r'(?i)H100') THEN 'NVIDIA H100 GPU'
    WHEN REGEXP_CONTAINS(sku_description, r'(?i)L4') THEN 'NVIDIA L4 GPU'
    WHEN REGEXP_CONTAINS(sku_description, r'(?i)TPU') THEN 'Google Cloud TPU'
    ELSE service_name
  END AS model_or_resource_family,

  CASE
    WHEN REGEXP_CONTAINS(sku_description, r'(?i)Input|Prompt') THEN 'Input (Prompt)'
    WHEN REGEXP_CONTAINS(sku_description, r'(?i)Output|Candidate') THEN 'Output (Response)'
    WHEN REGEXP_CONTAINS(sku_description, r'(?i)Context Caching') THEN 'Context Cache'
    ELSE 'API Request / Hourly'
  END AS modality_type
FROM raw_billing;
"

echo -e "${GREEN}Master View '${PROJECT_ID}.${DATASET_ID}.vw_ai_consumption_master' deployed successfully!${RESET}"

# Step 4: Create Rollup/Anomaly Views
echo -e "\n${CYAN}Step 4: Deploying Anomaly Alert View 'vw_ai_cost_anomaly_alerts'...${RESET}"

bq query --use_legacy_sql=false --location="${LOCATION}" "
CREATE OR REPLACE VIEW \`${PROJECT_ID}.${DATASET_ID}.vw_ai_cost_anomaly_alerts\` AS
WITH daily_project_spend AS (
  SELECT
    usage_date,
    project_id,
    project_name,
    ai_category,
    SUM(net_cost) AS daily_net_cost
  FROM
    \`${PROJECT_ID}.${DATASET_ID}.vw_ai_consumption_master\`
  WHERE
    usage_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)
  GROUP BY 1, 2, 3, 4
),
rolling_stats AS (
  SELECT
    *,
    AVG(daily_net_cost) OVER(
      PARTITION BY project_id, ai_category
      ORDER BY usage_date
      ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING
    ) AS prev_7d_avg_cost
  FROM daily_project_spend
)
SELECT
  usage_date,
  project_id,
  project_name,
  ai_category,
  ROUND(daily_net_cost, 2) AS today_spend_usd,
  ROUND(prev_7d_avg_cost, 2) AS baseline_avg_usd,
  ROUND(daily_net_cost - prev_7d_avg_cost, 2) AS surge_amount_usd,
  ROUND(SAFE_DIVIDE(daily_net_cost, prev_7d_avg_cost), 2) AS surge_multiple
FROM
  rolling_stats
WHERE
  daily_net_cost > 50.0
  AND daily_net_cost > (prev_7d_avg_cost * 1.8);
"

echo -e "${GREEN}Anomaly alert view deployed.${RESET}"

echo -e "\n${BOLD}${GREEN}======================================================${RESET}"
echo -e "${BOLD}${GREEN}            Deployment Completed Successfully!         ${RESET}"
echo -e "${BOLD}${GREEN}======================================================${RESET}\n"
