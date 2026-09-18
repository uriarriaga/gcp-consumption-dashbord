#!/usr/bin/env bash
# ==============================================================================
# Deploy AI Consumption & Cost Dashboard (Google Cloud)
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/.dashboard_config"

echo -e "${BOLD}${CYAN}======================================================${RESET}"
echo -e "${BOLD}${CYAN} Google Cloud AI Billing Dashboard - Automated Setup  ${RESET}"
echo -e "${BOLD}${CYAN}======================================================${RESET}\n"

# 1. Verify CLI requirements
command -v gcloud >/dev/null 2>&1 || { echo -e "${RED}Error: 'gcloud' CLI is not installed or not in PATH.${RESET}" >&2; exit 1; }
command -v bq >/dev/null 2>&1 || { echo -e "${RED}Error: 'bq' CLI is not installed or not in PATH.${RESET}" >&2; exit 1; }

# Load existing config if available
PREV_PROJECT=""
PREV_DATASET=""
PREV_LOCATION="US"
PREV_SOURCE_TABLE=""

if [[ -f "$CONFIG_FILE" ]]; then
  echo -e "${CYAN}Found existing configuration in ${CONFIG_FILE}.${RESET}"
  # Safely parse KEY=VALUE without arbitrary code execution
  while IFS='=' read -r key val || [[ -n "$key" ]]; do
    key=$(echo "$key" | tr -d '[:space:]')
    val=$(echo "$val" | tr -d '[:space:]"' | tr -d "'")
    case "$key" in
      PROJECT_ID) PREV_PROJECT="$val" ;;
      DATASET_ID) PREV_DATASET="$val" ;;
      LOCATION) PREV_LOCATION="$val" ;;
      SOURCE_TABLE) PREV_SOURCE_TABLE="$val" ;;
    esac
  done < "$CONFIG_FILE"
fi

CONFIG_APPROVED=false

while [[ "$CONFIG_APPROVED" != "true" ]]; do
  # 2. Determine GCP Project
  CURRENT_GCLOUD_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
  DEFAULT_PROJECT="${PREV_PROJECT:-$CURRENT_GCLOUD_PROJECT}"

  while true; do
    read -r -p "$(echo -e "${YELLOW}Enter your Google Cloud Project ID [${DEFAULT_PROJECT}]: ${RESET}")" PROJECT_INPUT
    PROJECT_ID="${PROJECT_INPUT:-$DEFAULT_PROJECT}"
    if [[ -n "$PROJECT_ID" && "$PROJECT_ID" != "(unset)" ]]; then
      break
    fi
    echo -e "${RED}Project ID cannot be empty. Please enter a valid Project ID.${RESET}"
  done

  echo -e "Setting active gcloud project to: ${GREEN}${PROJECT_ID}${RESET}"
  gcloud config set project "$PROJECT_ID" >/dev/null 2>&1 || true

  # 3. BigQuery Dataset Configuration (supports bare dataset or project.dataset)
  DEFAULT_DATASET="${PREV_DATASET:-ai_billing_dashboard}"

  while true; do
    read -r -p "$(echo -e "${YELLOW}Enter BigQuery Dataset ID to create/use [${DEFAULT_DATASET}]: ${RESET}")" DATASET_INPUT
    DATASET_RAW="${DATASET_INPUT:-$DEFAULT_DATASET}"

    # Strip project prefix if user entered project.dataset or project:dataset
    if [[ "$DATASET_RAW" =~ ^([a-zA-Z0-9_-]+)[.:]([a-zA-Z0-9_]+)$ ]]; then
      INFERRED_PROJECT="${BASH_REMATCH[1]}"
      DATASET_ID="${BASH_REMATCH[2]}"
      if [[ "$INFERRED_PROJECT" != "$PROJECT_ID" ]]; then
        echo -e "${CYAN}Note: Project prefix '${INFERRED_PROJECT}' detected in dataset input.${RESET}"
        read -r -p "$(echo -e "${YELLOW}Use '${INFERRED_PROJECT}' as target Project ID instead of '${PROJECT_ID}'? [y/N]: ${RESET}")" SWITCH_PROJ
        if [[ "$SWITCH_PROJ" =~ ^[Yy]$ ]]; then
          PROJECT_ID="$INFERRED_PROJECT"
          gcloud config set project "$PROJECT_ID" >/dev/null 2>&1 || true
        fi
      fi
    else
      DATASET_ID="$DATASET_RAW"
    fi

    if [[ -n "$DATASET_ID" ]]; then
      break
    fi
    echo -e "${RED}Dataset ID cannot be empty. Please enter a valid Dataset ID.${RESET}"
  done

  DEFAULT_LOCATION="${PREV_LOCATION:-US}"
  read -r -p "$(echo -e "${YELLOW}Enter BigQuery Dataset Location [${DEFAULT_LOCATION}]: ${RESET}")" LOCATION_INPUT
  LOCATION="${LOCATION_INPUT:-$DEFAULT_LOCATION}"

  # 4. Data Source Mode Selection (Production mode is default)
  echo -e "\n${BOLD}Select your data source mode:${RESET}"
  echo -e "  1) ${BOLD}Production mode${RESET} — Connect to existing Google Cloud Billing Export table (Recommended)"
  echo -e "  2) ${BOLD}Demo mode${RESET} — Generate synthetic sample AI billing data for sandbox testing"
  read -r -p "$(echo -e "${YELLOW}Select option [1 or 2, default: 1]: ${RESET}")" DATA_MODE_INPUT
  DATA_MODE="${DATA_MODE_INPUT:-1}"

  SOURCE_TABLE=""

  # Check if view already exists and what table it currently points to (Re-run regression protection)
  EXISTING_SOURCE_IN_VIEW=""
  if bq show --view "${PROJECT_ID}:${DATASET_ID}.vw_ai_consumption_master" >/dev/null 2>&1; then
    VIEW_JSON=$(bq show --view --format=prettyjson "${PROJECT_ID}:${DATASET_ID}.vw_ai_consumption_master" 2>/dev/null || true)
    EXISTING_SOURCE_IN_VIEW=$(echo "$VIEW_JSON" | grep -o 'FROM[[:space:]]*`[^`]*`' | head -n1 | sed -E 's/FROM[[:space:]]*`([^`]+)`/\1/' || true)
  fi

  if [[ "$DATA_MODE" == "1" ]]; then
    # Production Mode: Auto-discover Billing Export tables
    echo -e "\n${CYAN}Scanning for Google Cloud Billing Export tables...${RESET}"

    SCAN_PROJECT="$PROJECT_ID"
    SCAN_DATASET="$DATASET_ID"

    # If the user previously used a source table, offer to keep it
    if [[ -n "$EXISTING_SOURCE_IN_VIEW" && "$EXISTING_SOURCE_IN_VIEW" != *"sample_ai_billing_export"* ]]; then
      echo -e "${GREEN}Found existing source table in view:${RESET} ${BOLD}${EXISTING_SOURCE_IN_VIEW}${RESET}"
      read -r -p "$(echo -e "${YELLOW}Keep using this existing billing export table? [Y/n]: ${RESET}")" KEEP_EXISTING
      if [[ ! "$KEEP_EXISTING" =~ ^[Nn]$ ]]; then
        SOURCE_TABLE="$EXISTING_SOURCE_IN_VIEW"
      fi
    elif [[ -n "$PREV_SOURCE_TABLE" && "$PREV_SOURCE_TABLE" != *"sample_ai_billing_export"* ]]; then
      echo -e "${GREEN}Found previously configured source table:${RESET} ${BOLD}${PREV_SOURCE_TABLE}${RESET}"
      read -r -p "$(echo -e "${YELLOW}Keep using this previous billing export table? [Y/n]: ${RESET}")" KEEP_PREV
      if [[ ! "$KEEP_PREV" =~ ^[Nn]$ ]]; then
        SOURCE_TABLE="$PREV_SOURCE_TABLE"
      fi
    fi

    if [[ -z "$SOURCE_TABLE" ]]; then
      while true; do
        read -r -p "$(echo -e "${YELLOW}Enter dataset containing billing export tables [${SCAN_DATASET}]: ${RESET}")" SCAN_DS_INPUT
        CHOSEN_SCAN_DS="${SCAN_DS_INPUT:-$SCAN_DATASET}"

        if [[ "$CHOSEN_SCAN_DS" =~ ^([a-zA-Z0-9_-]+)[.:]([a-zA-Z0-9_]+)$ ]]; then
          SCAN_PROJECT="${BASH_REMATCH[1]}"
          SCAN_DATASET="${BASH_REMATCH[2]}"
        else
          SCAN_DATASET="$CHOSEN_SCAN_DS"
        fi

        # Find tables matching gcp_billing_export
        DETECTED_TABLES=()
        if command -v jq >/dev/null 2>&1; then
          while IFS= read -r t; do
            [[ -n "$t" ]] && DETECTED_TABLES+=("$t")
          done < <(bq ls --max_results=100 --format=json "${SCAN_PROJECT}:${SCAN_DATASET}" 2>/dev/null | jq -r '.[].tableReference.tableId // empty' | grep -E '^gcp_billing_export' || true)
        else
          while IFS= read -r t; do
            [[ -n "$t" ]] && DETECTED_TABLES+=("$t")
          done < <(bq ls --max_results=100 "${SCAN_PROJECT}:${SCAN_DATASET}" 2>/dev/null | awk '{print $1}' | grep -E '^gcp_billing_export' || true)
        fi

        # Prioritize resource export over standard export
        SORTED_TABLES=()
        for tbl in "${DETECTED_TABLES[@]}"; do
          if [[ "$tbl" == gcp_billing_export_resource_v1_* ]]; then
            SORTED_TABLES+=("$tbl (Detailed Resource Export - Recommended)")
          fi
        done
        for tbl in "${DETECTED_TABLES[@]}"; do
          if [[ "$tbl" != gcp_billing_export_resource_v1_* ]]; then
            SORTED_TABLES+=("$tbl (Standard Billing Export)")
          fi
        done

        if [[ ${#SORTED_TABLES[@]} -gt 0 ]]; then
          echo -e "\n${GREEN}Detected Billing Export tables in ${SCAN_PROJECT}.${SCAN_DATASET}:${RESET}"
          for i in "${!SORTED_TABLES[@]}"; do
            idx=$((i + 1))
            echo "  $idx) ${SORTED_TABLES[$i]}"
          done
          echo "  c) Enter a custom table path"

          read -r -p "$(echo -e "${YELLOW}Select export table [1-${#SORTED_TABLES[@]}, default: 1]: ${RESET}")" TABLE_CHOICE
          TABLE_CHOICE="${TABLE_CHOICE:-1}"

          if [[ "$TABLE_CHOICE" =~ ^[0-9]+$ ]] && (( TABLE_CHOICE >= 1 && TABLE_CHOICE <= ${#SORTED_TABLES[@]} )); then
            selected_raw="${SORTED_TABLES[$((TABLE_CHOICE - 1))]}"
            selected_table_name=$(echo "$selected_raw" | awk '{print $1}')
            SOURCE_TABLE="${SCAN_PROJECT}.${SCAN_DATASET}.${selected_table_name}"
            break
          elif [[ "$TABLE_CHOICE" =~ ^[Cc]$ ]]; then
            read -r -p "$(echo -e "${YELLOW}Enter full table path (project.dataset.table): ${RESET}")" CUSTOM_TABLE
            SOURCE_TABLE="$CUSTOM_TABLE"
            break
          else
            echo -e "${RED}Invalid selection. Please try again.${RESET}"
          fi
        else
          echo -e "${YELLOW}No 'gcp_billing_export_*' tables found in ${SCAN_PROJECT}.${SCAN_DATASET}.${RESET}"
          echo "  1) Try another dataset"
          echo "  2) Enter full table path manually"
          read -r -p "$(echo -e "${YELLOW}Select option [1 or 2, default: 2]: ${RESET}")" NO_TBL_CHOICE
          NO_TBL_CHOICE="${NO_TBL_CHOICE:-2}"

          if [[ "$NO_TBL_CHOICE" == "2" ]]; then
            read -r -p "$(echo -e "${YELLOW}Enter full path to Billing Export table (e.g. project.dataset.gcp_billing_export_v1_XXXX): ${RESET}")" MANUAL_TABLE
            SOURCE_TABLE="$MANUAL_TABLE"
            break
          fi
        fi
      done
    fi

    # Validate source table existence with bq show
    echo -e "Verifying access to ${CYAN}${SOURCE_TABLE}${RESET}..."
    if ! bq show "${SOURCE_TABLE}" >/dev/null 2>&1; then
      echo -e "${YELLOW}Warning: Could not verify table '${SOURCE_TABLE}' with bq show.${RESET}"
      read -r -p "$(echo -e "${YELLOW}Continue with this table path anyway? [y/N]: ${RESET}")" CONFIRM_UNVERIFIED
      if [[ ! "$CONFIRM_UNVERIFIED" =~ ^[Yy]$ ]]; then
        continue
      fi
    else
      echo -e "${GREEN}Table verified successfully.${RESET}"
    fi

  else
    # Demo Mode
    SOURCE_TABLE="${PROJECT_ID}.${DATASET_ID}.sample_ai_billing_export"
  fi

  # 5. Pre-Deployment Configuration Summary & Confirmation Checkpoint
  echo -e "\n${BOLD}${CYAN}======================================================${RESET}"
  echo -e "${BOLD}${CYAN}             Deployment Configuration Summary         ${RESET}"
  echo -e "${BOLD}${CYAN}======================================================${RESET}"
  echo -e "  ${BOLD}Target Project:${RESET}     ${PROJECT_ID}"
  echo -e "  ${BOLD}Target Dataset:${RESET}     ${DATASET_ID} (Location: ${LOCATION})"
  echo -e "  ${BOLD}Deployment Mode:${RESET}    $([[ "$DATA_MODE" == "1" ]] && echo "Production (Live Billing Export)" || echo "Demo (Synthetic Data)")"
  echo -e "  ${BOLD}Source Table:${RESET}       ${SOURCE_TABLE}"
  echo -e "  ${BOLD}Views to Deploy:${RESET}    ${PROJECT_ID}.${DATASET_ID}.vw_ai_consumption_master"
  echo -e "                      ${PROJECT_ID}.${DATASET_ID}.vw_ai_cost_anomaly_alerts"
  echo -e "${BOLD}${CYAN}======================================================${RESET}"

  read -r -p "$(echo -e "${YELLOW}Proceed with deployment? [Y/n/edit, default: Y]: ${RESET}")" PROCEED_CHOICE
  PROCEED_CHOICE="${PROCEED_CHOICE:-Y}"

  case "$PROCEED_CHOICE" in
    [Yy]*)
      CONFIG_APPROVED=true
      ;;
    [Ee]*)
      echo -e "\n${CYAN}Re-opening configuration prompts...${RESET}\n"
      CONFIG_APPROVED=false
      ;;
    *)
      echo -e "${YELLOW}Deployment cancelled by user.${RESET}"
      exit 0
      ;;
  esac
done

# Save configuration for future re-runs and Python script
cat <<EOF > "$CONFIG_FILE"
PROJECT_ID=${PROJECT_ID}
DATASET_ID=${DATASET_ID}
LOCATION=${LOCATION}
VIEW_NAME=vw_ai_consumption_master
SOURCE_TABLE=${SOURCE_TABLE}
EOF

# Ensure Target Dataset exists
echo -e "\n${CYAN}Step 1: Ensuring BigQuery dataset '${DATASET_ID}' exists in location '${LOCATION}'...${RESET}"
if bq show --location="${LOCATION}" "${PROJECT_ID}:${DATASET_ID}" >/dev/null 2>&1; then
  echo -e "${GREEN}Dataset ${DATASET_ID} already exists.${RESET}"
else
  echo -e "Creating dataset ${DATASET_ID} in location ${LOCATION}..."
  bq --location="${LOCATION}" mk --dataset \
    --description="AI Billing and Consumption Analytics Dataset" \
    "${PROJECT_ID}:${DATASET_ID}"
  echo -e "${GREEN}Dataset created successfully.${RESET}"
fi

# Step 2: Populate sample data if in Demo mode
if [[ "$DATA_MODE" == "2" ]]; then
  echo -e "\n${CYAN}Step 2: Generating synthetic AI billing data in '${SOURCE_TABLE}' for demo...${RESET}"
  bq query --use_legacy_sql=false --location="${LOCATION}" "
  CREATE OR REPLACE TABLE \`${SOURCE_TABLE}\`
  PARTITION BY DATE(usage_start_time) AS
  WITH date_range AS (
    SELECT day
    FROM UNNEST(GENERATE_DATE_ARRAY(DATE_SUB(CURRENT_DATE(), INTERVAL 60 DAY), CURRENT_DATE())) AS day
  ),
  projects AS (
    SELECT 'enterprise-genai-prod' AS project_id, 'GenAI Production' AS project_name, 'prod' AS env, 'NLP Core' AS team, 'CC-101' AS cost_center
    UNION ALL SELECT 'customer-cx-bot', 'Customer CX Bot', 'prod', 'Support Automation', 'CC-102'
    UNION ALL SELECT 'docai-pipeline', 'Doc Processing Pipeline', 'staging', 'Finance Tech', 'CC-103'
    UNION ALL SELECT 'ai-research-lab', 'AI Research Lab', 'dev', 'Data Science', 'CC-104'
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
    UNION ALL SELECT 'Vertex AI', 'C7E2-9256-1C43', 'Vector Search Index Serving e2-standard-16', 'hour', 380.0, 'Vector Search & Embeddings Infra'
    UNION ALL SELECT 'Duet AI', 'E567-8901-2345', 'Duet AI: Gemini Code Assist Subscription', 'month', 240.0, 'Enterprise AI Subscriptions (Seats)'
    UNION ALL SELECT 'Vertex AI Search', 'F678-9012-3456', 'Vertex AI Search: Gemini Enterprise Standard 1-Yr Subscription', 'month', 190.0, 'Enterprise AI Subscriptions (Seats)'
    UNION ALL SELECT 'Gemini API', 'G789-0123-4567', 'Gemini 2.5 Flash - Thinking Text Output Tokens', 'token', 170.0, 'Generative AI'
    UNION ALL SELECT 'Vertex AI', 'C7E2-9256-1C43', 'Gemini 2.5 Pro - Thinking Text Output Tokens', 'token', 230.0, 'Generative AI'
    UNION ALL SELECT 'Gemini API', 'G789-0123-4567', 'Gemini 3.5 Flash - Input Prompt Tokens', 'token', 120.0, 'Generative AI'
    UNION ALL SELECT 'Gemini API', 'G789-0123-4567', 'Gemini 3.5 Flash - Output Candidate Tokens', 'token', 260.0, 'Generative AI'
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

# Step 3: Deploy Master View
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
        'Discovery Engine',
        'Duet AI',
        'Vertex AI Search',
        'Gemini API'
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
    WHEN REGEXP_CONTAINS(sku_description, r'(?i)Vector Search|Matching Engine') THEN 'Vector Search & Embeddings Infra'
    WHEN REGEXP_CONTAINS(sku_description, r'(?i)Subscription|Code Assist|Gemini Enterprise|Notebook Enterprise') THEN 'Enterprise AI Subscriptions (Seats)'
    WHEN REGEXP_CONTAINS(sku_description, r'(?i)Gemini|Claude|PaLM|Imagen|Codey|Embeddings|Text Generation|Multimodal|Provisioned Throughput') THEN 'Generative AI'
    WHEN service_name IN ('Dialogflow Enterprise Edition', 'Dialogflow CX', 'Discovery Engine', 'Vertex AI Search') THEN 'Agentic & Conversational AI'
    WHEN REGEXP_CONTAINS(sku_description, r'(?i)Nvidia|A100|H100|V100|L4|T4|P100|TPU') THEN 'AI Compute (GPU/TPU)'
    ELSE 'Perception & Cognitive AI'
  END AS ai_category,

  CASE
    WHEN REGEXP_CONTAINS(sku_description, r'(?i)Vector Search|Matching Engine') THEN 'Vector Search'
    WHEN REGEXP_CONTAINS(sku_description, r'(?i)Code Assist') THEN 'Gemini Code Assist'
    WHEN REGEXP_CONTAINS(sku_description, r'(?i)Gemini.*Enterprise|Vertex AI Search') THEN 'Vertex AI Search / Enterprise'
    WHEN REGEXP_CONTAINS(sku_description, r'(?i)Gemini.*1\.5.*Pro') THEN 'Gemini 1.5 Pro'
    WHEN REGEXP_CONTAINS(sku_description, r'(?i)Gemini.*1\.5.*Flash') THEN 'Gemini 1.5 Flash'
    WHEN REGEXP_CONTAINS(sku_description, r'(?i)Gemini.*2\.0') THEN 'Gemini 2.0'
    WHEN REGEXP_CONTAINS(sku_description, r'(?i)Gemini.*2\.5.*Pro') THEN 'Gemini 2.5 Pro'
    WHEN REGEXP_CONTAINS(sku_description, r'(?i)Gemini.*2\.5.*Flash') THEN 'Gemini 2.5 Flash'
    WHEN REGEXP_CONTAINS(sku_description, r'(?i)Gemini.*3\.5') THEN 'Gemini 3.5 Flash/Pro'
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
    WHEN REGEXP_CONTAINS(sku_description, r'(?i)Thinking') THEN 'Output (Thinking / Reasoning)'
    WHEN REGEXP_CONTAINS(sku_description, r'(?i)Input|Prompt') THEN 'Input (Prompt)'
    WHEN REGEXP_CONTAINS(sku_description, r'(?i)Output|Candidate') THEN 'Output (Response)'
    WHEN REGEXP_CONTAINS(sku_description, r'(?i)Context Caching') THEN 'Context Cache'
    WHEN REGEXP_CONTAINS(sku_description, r'(?i)Subscription|Seat|Month') THEN 'Subscription / Seat'
    ELSE 'API Request / Hourly'
  END AS modality_type
FROM raw_billing;
"

echo -e "${GREEN}Master View '${PROJECT_ID}.${DATASET_ID}.vw_ai_consumption_master' deployed successfully!${RESET}"

# Step 4: Deploy Anomaly View
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

# Step 5: Generate Looker Studio Link Automatically
PYTHON_BIN=""
if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="python3"
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN="python"
fi

if [[ -n "$PYTHON_BIN" && -f "${SCRIPT_DIR}/create_looker_studio_dashboard.py" ]]; then
  "$PYTHON_BIN" "${SCRIPT_DIR}/create_looker_studio_dashboard.py" \
    --project "$PROJECT_ID" \
    --dataset "$DATASET_ID" \
    --table "vw_ai_consumption_master"
else
  CLONE_URL="https://lookerstudio.google.com/reporting/create?c.reportId=c7991054-d499-4aa0-9b2a-e8f98d92ea55&r.reportName=Google+Cloud+AI+Consumption+%26+Cost+Dashboard&ds.ds0.connector=bigQuery&ds.ds0.type=TABLE&ds.ds0.projectId=${PROJECT_ID}&ds.ds0.datasetId=${DATASET_ID}&ds.ds0.tableId=vw_ai_consumption_master&ds.ds0.billingProjectId=${PROJECT_ID}"
  echo -e ">>> Click the link below to clone the Looker Studio template report:"
  echo -e "\n${CLONE_URL}\n"
  echo -e "Operational Best Practices:"
  echo -e "  1. Credentials: In Looker Studio, configure data source credentials to"
  echo -e "     'Viewer's Credentials' so access respects BigQuery IAM permissions."
  echo -e "  2. Sharing: The URL above is for initial creation/editing."
  echo -e "     To distribute to stakeholders, click the 'Share' button inside Looker Studio.\n"
fi

