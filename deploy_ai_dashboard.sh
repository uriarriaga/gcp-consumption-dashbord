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

# Helper: Strip surrounding whitespace, backticks, single quotes, and double quotes
sanitize_bq_id() {
  local raw="$1"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  raw="${raw//\`/}"
  raw="${raw//\"/}"
  raw="${raw//\'/}"
  printf '%s' "$raw"
}

# Helper: Auto-detect BigQuery location for a dataset (project:dataset) or table (project:dataset.table)
get_bq_location() {
  local ref="$1"
  local info_json=""
  local trimmed=""
  local loc=""
  info_json=$(bq show --format=json "$ref" 2>/dev/null || true)
  trimmed="${info_json#"${info_json%%[![:space:]]*}"}"
  if [[ "$trimmed" == "{"* ]]; then
    if command -v jq >/dev/null 2>&1; then
      loc=$(printf '%s\n' "$trimmed" | jq -r '.location // empty' 2>/dev/null || true)
    fi
    if [[ -z "$loc" ]]; then
      loc=$(printf '%s\n' "$trimmed" | sed -n 's/.*"location"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
    fi
  fi
  printf '%s' "$loc"
}

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
    val=$(sanitize_bq_id "$val")
    case "$key" in
      PROJECT_ID) PREV_PROJECT="$val" ;;
      DATASET_ID) PREV_DATASET="$val" ;;
      LOCATION) PREV_LOCATION="$val" ;;
      SOURCE_TABLE) PREV_SOURCE_TABLE="$val" ;;
    esac
  done < "$CONFIG_FILE"

  # Heal PREV_DATASET if a previous run stored project.dataset or project.dataset.table
  if [[ "$PREV_DATASET" =~ ^([a-zA-Z0-9_-]+)[.:]([a-zA-Z0-9_]+)[.:]([a-zA-Z0-9_]+)$ ]]; then
    [[ -z "$PREV_PROJECT" ]] && PREV_PROJECT="${BASH_REMATCH[1]}"
    PREV_DATASET="${BASH_REMATCH[2]}"
    [[ -z "$PREV_SOURCE_TABLE" ]] && PREV_SOURCE_TABLE="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
  elif [[ "$PREV_DATASET" =~ ^([a-zA-Z0-9_-]+)[.:]([a-zA-Z0-9_]+)$ ]]; then
    if [[ "${BASH_REMATCH[2]}" =~ ^(gcp_billing_export|sample_ai_billing_export) ]]; then
      PREV_DATASET="${BASH_REMATCH[1]}"
      [[ -n "$PREV_PROJECT" && -z "$PREV_SOURCE_TABLE" ]] && PREV_SOURCE_TABLE="${PREV_PROJECT}.${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
    else
      [[ -z "$PREV_PROJECT" ]] && PREV_PROJECT="${BASH_REMATCH[1]}"
      PREV_DATASET="${BASH_REMATCH[2]}"
    fi
  fi
fi

CONFIG_APPROVED=false

while [[ "$CONFIG_APPROVED" != "true" ]]; do
  PREFILLED_SOURCE_TABLE=""

  # 2. Determine GCP Project
  CURRENT_GCLOUD_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
  DEFAULT_PROJECT="${PREV_PROJECT:-$CURRENT_GCLOUD_PROJECT}"

  while true; do
    read -r -p "$(echo -e "${YELLOW}Enter your Google Cloud Project ID [${DEFAULT_PROJECT}]: ${RESET}")" PROJECT_INPUT
    PROJECT_RAW=$(sanitize_bq_id "${PROJECT_INPUT:-$DEFAULT_PROJECT}")

    # If user pasted project.dataset.table or project.dataset at the project prompt, extract project
    if [[ "$PROJECT_RAW" =~ ^([a-zA-Z0-9_-]+)[.:]([a-zA-Z0-9_]+)[.:]([a-zA-Z0-9_]+)$ ]]; then
      PROJECT_ID="${BASH_REMATCH[1]}"
      PREV_DATASET="${BASH_REMATCH[2]}"
      PREFILLED_SOURCE_TABLE="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
    elif [[ "$PROJECT_RAW" =~ ^([a-zA-Z0-9_-]+)[.:]([a-zA-Z0-9_]+)$ ]]; then
      PROJECT_ID="${BASH_REMATCH[1]}"
      PREV_DATASET="${BASH_REMATCH[2]}"
    else
      PROJECT_ID="$PROJECT_RAW"
    fi

    if [[ -n "$PROJECT_ID" && "$PROJECT_ID" != "(unset)" ]]; then
      break
    fi
    echo -e "${RED}Project ID cannot be empty. Please enter a valid Project ID.${RESET}"
  done

  echo -e "Setting active gcloud project to: ${GREEN}${PROJECT_ID}${RESET}"
  gcloud config set project "$PROJECT_ID" >/dev/null 2>&1 || true

  # 3. BigQuery Dataset Configuration (supports bare dataset, project.dataset, or project.dataset.table from 'Copy ID')
  DEFAULT_DATASET="${PREV_DATASET:-ai_billing_dashboard}"

  while true; do
    read -r -p "$(echo -e "${YELLOW}Enter BigQuery Dataset ID to create/use [${DEFAULT_DATASET}]: ${RESET}")" DATASET_INPUT
    DATASET_RAW=$(sanitize_bq_id "${DATASET_INPUT:-$DEFAULT_DATASET}")

    # Case 1: 3-part identifier (project.dataset.table or project:dataset.table) from BigQuery 'Copy ID'
    if [[ "$DATASET_RAW" =~ ^([a-zA-Z0-9_-]+)[.:]([a-zA-Z0-9_]+)[.:]([a-zA-Z0-9_]+)$ ]]; then
      INFERRED_PROJECT="${BASH_REMATCH[1]}"
      DATASET_ID="${BASH_REMATCH[2]}"
      INFERRED_TABLE="${BASH_REMATCH[3]}"
      PREFILLED_SOURCE_TABLE="${INFERRED_PROJECT}.${DATASET_ID}.${INFERRED_TABLE}"
      echo -e "${CYAN}Detected full table ID. Extracted Dataset ID: '${BOLD}${DATASET_ID}${RESET}${CYAN}' and Source Table: '${BOLD}${PREFILLED_SOURCE_TABLE}${RESET}${CYAN}'${RESET}"
      if [[ "$INFERRED_PROJECT" != "$PROJECT_ID" ]]; then
        echo -e "${CYAN}Note: Project prefix '${INFERRED_PROJECT}' detected in input.${RESET}"
        read -r -p "$(echo -e "${YELLOW}Use '${INFERRED_PROJECT}' as target Project ID instead of '${PROJECT_ID}'? [y/N]: ${RESET}")" SWITCH_PROJ
        if [[ "$SWITCH_PROJ" =~ ^[Yy]$ ]]; then
          PROJECT_ID="$INFERRED_PROJECT"
          gcloud config set project "$PROJECT_ID" >/dev/null 2>&1 || true
        fi
      fi
    # Case 2: 2-part identifier (either dataset.table or project.dataset / project:dataset)
    elif [[ "$DATASET_RAW" =~ ^([a-zA-Z0-9_-]+)[.:]([a-zA-Z0-9_]+)$ ]]; then
      PART1="${BASH_REMATCH[1]}"
      PART2="${BASH_REMATCH[2]}"
      if [[ "$PART2" =~ ^(gcp_billing_export|sample_ai_billing_export) ]]; then
        DATASET_ID="$PART1"
        INFERRED_TABLE="$PART2"
        PREFILLED_SOURCE_TABLE="${PROJECT_ID}.${DATASET_ID}.${INFERRED_TABLE}"
        echo -e "${CYAN}Detected dataset.table input. Extracted Dataset ID: '${BOLD}${DATASET_ID}${RESET}${CYAN}' and Source Table: '${BOLD}${PREFILLED_SOURCE_TABLE}${RESET}${CYAN}'${RESET}"
      else
        INFERRED_PROJECT="$PART1"
        DATASET_ID="$PART2"
        if [[ "$INFERRED_PROJECT" != "$PROJECT_ID" ]]; then
          echo -e "${CYAN}Note: Project prefix '${INFERRED_PROJECT}' detected in dataset input.${RESET}"
          read -r -p "$(echo -e "${YELLOW}Use '${INFERRED_PROJECT}' as target Project ID instead of '${PROJECT_ID}'? [y/N]: ${RESET}")" SWITCH_PROJ
          if [[ "$SWITCH_PROJ" =~ ^[Yy]$ ]]; then
            PROJECT_ID="$INFERRED_PROJECT"
            gcloud config set project "$PROJECT_ID" >/dev/null 2>&1 || true
          fi
        fi
      fi
    # Case 3: Bare dataset ID
    else
      DATASET_ID="$DATASET_RAW"
    fi

    if [[ -z "$DATASET_ID" ]]; then
      echo -e "${RED}Dataset ID cannot be empty. Please enter a valid Dataset ID.${RESET}"
      continue
    fi

    if [[ ! "$DATASET_ID" =~ ^[a-zA-Z0-9_]{1,1024}$ ]]; then
      echo -e "${RED}Invalid Dataset ID '${DATASET_ID}'. BigQuery dataset names must contain only letters, numbers, and underscores (or paste project.dataset / project.dataset.table).${RESET}"
      continue
    fi

    break
  done

  # Auto-detect dataset location if the source or target dataset already exists
  DETECTED_LOCATION=""
  if [[ -n "$PREFILLED_SOURCE_TABLE" && "$PREFILLED_SOURCE_TABLE" =~ ^([a-zA-Z0-9_-]+)\.([a-zA-Z0-9_]+)\.([a-zA-Z0-9_]+)$ ]]; then
    DETECTED_LOCATION=$(get_bq_location "${BASH_REMATCH[1]}:${BASH_REMATCH[2]}.${BASH_REMATCH[3]}")
    [[ -z "$DETECTED_LOCATION" ]] && DETECTED_LOCATION=$(get_bq_location "${BASH_REMATCH[1]}:${BASH_REMATCH[2]}")
  fi
  if [[ -z "$DETECTED_LOCATION" ]]; then
    DETECTED_LOCATION=$(get_bq_location "${PROJECT_ID}:${DATASET_ID}")
  fi

  if [[ -n "$DETECTED_LOCATION" ]]; then
    DEFAULT_LOCATION="$DETECTED_LOCATION"
    echo -e "${CYAN}Auto-detected BigQuery dataset location: ${BOLD}${DEFAULT_LOCATION}${RESET}"
  else
    DEFAULT_LOCATION="${PREV_LOCATION:-US}"
  fi

  read -r -p "$(echo -e "${YELLOW}Enter BigQuery Dataset Location [${DEFAULT_LOCATION}]: ${RESET}")" LOCATION_INPUT
  LOCATION=$(sanitize_bq_id "${LOCATION_INPUT:-$DEFAULT_LOCATION}")

  # 4. Data Source Mode Selection (Production mode is default)
  echo -e "\n${BOLD}Select your data source mode:${RESET}"
  echo -e "  1) ${BOLD}Production mode${RESET} — Connect to existing Google Cloud Billing Export table (Recommended)"
  echo -e "  2) ${BOLD}Demo mode${RESET} — Generate synthetic sample AI billing data for sandbox testing"
  read -r -p "$(echo -e "${YELLOW}Select option [1 or 2, default: 1]: ${RESET}")" DATA_MODE_INPUT
  DATA_MODE=$(sanitize_bq_id "${DATA_MODE_INPUT:-1}")

  SOURCE_TABLE=""

  # Check if view already exists and what table it currently points to (Re-run regression protection)
  EXISTING_SOURCE_IN_VIEW=""
  if bq show "${PROJECT_ID}:${DATASET_ID}.vw_ai_consumption_master" >/dev/null 2>&1; then
    VIEW_JSON=$(bq show --format=prettyjson "${PROJECT_ID}:${DATASET_ID}.vw_ai_consumption_master" 2>/dev/null || true)
    EXISTING_SOURCE_IN_VIEW=$(echo "$VIEW_JSON" | grep -o 'FROM[[:space:]]*`[^`]*`' | head -n1 | sed -E 's/FROM[[:space:]]*`([^`]+)`/\1/' || true)
  fi

  if [[ "$DATA_MODE" == "1" ]]; then
    # Production Mode: Auto-discover Billing Export tables
    echo -e "\n${CYAN}Scanning for Google Cloud Billing Export tables...${RESET}"

    SCAN_PROJECT="$PROJECT_ID"
    SCAN_DATASET="$DATASET_ID"

    # Priority 1: Table ID already pasted in the Dataset prompt during this session
    if [[ -n "$PREFILLED_SOURCE_TABLE" && "$PREFILLED_SOURCE_TABLE" != *"sample_ai_billing_export"* ]]; then
      echo -e "${GREEN}Using billing export table from input:${RESET} ${BOLD}${PREFILLED_SOURCE_TABLE}${RESET}"
      SOURCE_TABLE="$PREFILLED_SOURCE_TABLE"
    # Priority 2: Existing view's source table
    elif [[ -n "$EXISTING_SOURCE_IN_VIEW" && "$EXISTING_SOURCE_IN_VIEW" != *"sample_ai_billing_export"* ]]; then
      echo -e "${GREEN}Found existing source table in view:${RESET} ${BOLD}${EXISTING_SOURCE_IN_VIEW}${RESET}"
      read -r -p "$(echo -e "${YELLOW}Keep using this existing billing export table? [Y/n]: ${RESET}")" KEEP_EXISTING
      if [[ ! "$KEEP_EXISTING" =~ ^[Nn]$ ]]; then
        SOURCE_TABLE="$EXISTING_SOURCE_IN_VIEW"
      fi
    # Priority 3: Previously saved source table in .dashboard_config
    elif [[ -n "$PREV_SOURCE_TABLE" && "$PREV_SOURCE_TABLE" != *"sample_ai_billing_export"* ]]; then
      echo -e "${GREEN}Found previously configured source table:${RESET} ${BOLD}${PREV_SOURCE_TABLE}${RESET}"
      read -r -p "$(echo -e "${YELLOW}Keep using this previous billing export table? [Y/n]: ${RESET}")" KEEP_PREV
      if [[ ! "$KEEP_PREV" =~ ^[Nn]$ ]]; then
        SOURCE_TABLE="$PREV_SOURCE_TABLE"
      fi
    fi

    if [[ -z "$SOURCE_TABLE" ]]; then
      while true; do
        read -r -p "$(echo -e "${YELLOW}Enter dataset containing billing export tables (or full project.dataset.table) [${SCAN_DATASET}]: ${RESET}")" SCAN_DS_INPUT
        CHOSEN_SCAN_DS=$(sanitize_bq_id "${SCAN_DS_INPUT:-$SCAN_DATASET}")

        # Support 3-part project.dataset.table pasted directly into the dataset scan prompt
        if [[ "$CHOSEN_SCAN_DS" =~ ^([a-zA-Z0-9_-]+)[.:]([a-zA-Z0-9_]+)[.:]([a-zA-Z0-9_]+)$ ]]; then
          SCAN_PROJECT="${BASH_REMATCH[1]}"
          SCAN_DATASET="${BASH_REMATCH[2]}"
          SOURCE_TABLE="${SCAN_PROJECT}.${SCAN_DATASET}.${BASH_REMATCH[3]}"
          echo -e "${GREEN}Detected full billing export table path:${RESET} ${BOLD}${SOURCE_TABLE}${RESET}"
          break
        # Support 2-part dataset.table or project.dataset
        elif [[ "$CHOSEN_SCAN_DS" =~ ^([a-zA-Z0-9_-]+)[.:]([a-zA-Z0-9_]+)$ ]]; then
          if [[ "${BASH_REMATCH[2]}" =~ ^gcp_billing_export ]]; then
            SCAN_DATASET="${BASH_REMATCH[1]}"
            SOURCE_TABLE="${SCAN_PROJECT}.${SCAN_DATASET}.${BASH_REMATCH[2]}"
            echo -e "${GREEN}Detected billing export table path:${RESET} ${BOLD}${SOURCE_TABLE}${RESET}"
            break
          else
            SCAN_PROJECT="${BASH_REMATCH[1]}"
            SCAN_DATASET="${BASH_REMATCH[2]}"
          fi
        # Support 1-part table name if user pasted gcp_billing_export_* directly
        elif [[ "$CHOSEN_SCAN_DS" =~ ^gcp_billing_export[a-zA-Z0-9_]*$ ]]; then
          SOURCE_TABLE="${SCAN_PROJECT}.${SCAN_DATASET}.${CHOSEN_SCAN_DS}"
          echo -e "${GREEN}Detected billing export table:${RESET} ${BOLD}${SOURCE_TABLE}${RESET}"
          break
        else
          SCAN_DATASET="$CHOSEN_SCAN_DS"
        fi

        # Find tables matching gcp_billing_export (guard jq against non-JSON stdout error messages from bq ls)
        DETECTED_TABLES=()
        if command -v jq >/dev/null 2>&1; then
          BQ_LS_JSON=$(bq ls --max_results=100 --format=json "${SCAN_PROJECT}:${SCAN_DATASET}" 2>/dev/null || true)
          BQ_LS_TRIMMED="${BQ_LS_JSON#"${BQ_LS_JSON%%[![:space:]]*}"}"
          if [[ "$BQ_LS_TRIMMED" == "["* ]]; then
            while IFS= read -r t; do
              [[ -n "$t" ]] && DETECTED_TABLES+=("$t")
            done < <(printf '%s\n' "$BQ_LS_TRIMMED" | jq -r 'if type == "array" then .[].tableReference.tableId // empty else empty end' 2>/dev/null | grep -E '^gcp_billing_export' || true)
          fi
        else
          BQ_LS_TEXT=$(bq ls --max_results=100 "${SCAN_PROJECT}:${SCAN_DATASET}" 2>/dev/null || true)
          while IFS= read -r t; do
            [[ -n "$t" ]] && DETECTED_TABLES+=("$t")
          done < <(printf '%s\n' "$BQ_LS_TEXT" | awk '{print $1}' | grep -E '^gcp_billing_export' || true)
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
          TABLE_CHOICE=$(sanitize_bq_id "${TABLE_CHOICE:-1}")

          if [[ "$TABLE_CHOICE" =~ ^[0-9]+$ ]] && (( TABLE_CHOICE >= 1 && TABLE_CHOICE <= ${#SORTED_TABLES[@]} )); then
            selected_raw="${SORTED_TABLES[$((TABLE_CHOICE - 1))]}"
            selected_table_name=$(echo "$selected_raw" | awk '{print $1}')
            SOURCE_TABLE="${SCAN_PROJECT}.${SCAN_DATASET}.${selected_table_name}"
            break
          elif [[ "$TABLE_CHOICE" =~ ^[Cc]$ ]]; then
            read -r -p "$(echo -e "${YELLOW}Enter full table path (project.dataset.table): ${RESET}")" CUSTOM_TABLE
            SOURCE_TABLE=$(sanitize_bq_id "$CUSTOM_TABLE")
            break
          elif [[ "$TABLE_CHOICE" =~ ^([a-zA-Z0-9_-]+)[.:]([a-zA-Z0-9_]+)[.:]([a-zA-Z0-9_]+)$ ]]; then
            SOURCE_TABLE="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
            break
          else
            echo -e "${RED}Invalid selection. Please try again.${RESET}"
          fi
        else
          echo -e "${YELLOW}No 'gcp_billing_export_*' tables found in ${SCAN_PROJECT}.${SCAN_DATASET}.${RESET}"
          echo "  1) Try another dataset"
          echo "  2) Enter full table path manually"
          read -r -p "$(echo -e "${YELLOW}Select option [1 or 2, default: 2]: ${RESET}")" NO_TBL_CHOICE
          NO_TBL_CHOICE=$(sanitize_bq_id "${NO_TBL_CHOICE:-2}")

          if [[ "$NO_TBL_CHOICE" == "2" ]]; then
            read -r -p "$(echo -e "${YELLOW}Enter full path to Billing Export table (e.g. project.dataset.gcp_billing_export_v1_XXXX): ${RESET}")" MANUAL_TABLE
            SOURCE_TABLE=$(sanitize_bq_id "$MANUAL_TABLE")
            break
          elif [[ "$NO_TBL_CHOICE" =~ ^([a-zA-Z0-9_-]+)[.:]([a-zA-Z0-9_]+)[.:]([a-zA-Z0-9_]+)$ ]]; then
            SOURCE_TABLE="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
            break
          fi
        fi
      done
    fi

    # Normalize SOURCE_TABLE to SQL dot format (project.dataset.table) and bq CLI format (project:dataset.table)
    SOURCE_TABLE=$(sanitize_bq_id "$SOURCE_TABLE")
    SRC_PROJECT_REF="$SCAN_PROJECT"
    SRC_DATASET_REF="$SCAN_DATASET"
    if [[ "$SOURCE_TABLE" =~ ^([a-zA-Z0-9_-]+)[.:]([a-zA-Z0-9_]+)[.:]([a-zA-Z0-9_]+)$ ]]; then
      SRC_PROJECT_REF="${BASH_REMATCH[1]}"
      SRC_DATASET_REF="${BASH_REMATCH[2]}"
      SOURCE_TABLE="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
      BQ_SOURCE_REF="${BASH_REMATCH[1]}:${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
    elif [[ "$SOURCE_TABLE" =~ ^([a-zA-Z0-9_]+)[.]([a-zA-Z0-9_]+)$ ]]; then
      SRC_DATASET_REF="${BASH_REMATCH[1]}"
      SOURCE_TABLE="${SCAN_PROJECT}.${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
      BQ_SOURCE_REF="${SCAN_PROJECT}:${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
    elif [[ "$SOURCE_TABLE" =~ ^([a-zA-Z0-9_]+)$ ]]; then
      SOURCE_TABLE="${SCAN_PROJECT}.${SCAN_DATASET}.${BASH_REMATCH[1]}"
      BQ_SOURCE_REF="${SCAN_PROJECT}:${SCAN_DATASET}.${BASH_REMATCH[1]}"
    else
      BQ_SOURCE_REF="${SOURCE_TABLE/./:}"
    fi

    # Validate source table existence with bq show (using colon syntax project:dataset.table)
    echo -e "Verifying access to ${CYAN}${SOURCE_TABLE}${RESET}..."
    TBL_SHOW_JSON=$(bq show --format=json "${BQ_SOURCE_REF}" 2>/dev/null || true)
    if [[ "$TBL_SHOW_JSON" != *'"tableReference"'* ]]; then
      echo -e "${YELLOW}Warning: Could not verify table '${SOURCE_TABLE}' with bq show.${RESET}"
      read -r -p "$(echo -e "${YELLOW}Continue with this table path anyway? [y/N]: ${RESET}")" CONFIRM_UNVERIFIED
      if [[ ! "$CONFIRM_UNVERIFIED" =~ ^[Yy]$ ]]; then
        PREFILLED_SOURCE_TABLE=""
        continue
      fi
    else
      echo -e "${GREEN}Table verified successfully.${RESET}"
    fi

    # Auto-align LOCATION with the source billing export table / dataset location (e.g. us-central1 vs US)
    SRC_TBL_LOCATION=$(get_bq_location "${BQ_SOURCE_REF}")
    if [[ -z "$SRC_TBL_LOCATION" && -n "$SRC_PROJECT_REF" && -n "$SRC_DATASET_REF" ]]; then
      SRC_TBL_LOCATION=$(get_bq_location "${SRC_PROJECT_REF}:${SRC_DATASET_REF}")
    fi
    if [[ -n "$SRC_TBL_LOCATION" && "${SRC_TBL_LOCATION^^}" != "${LOCATION^^}" ]]; then
      echo -e "${YELLOW}Note: Source billing export is in location '${SRC_TBL_LOCATION}' (current setting: '${LOCATION}').${RESET}"
      echo -e "${CYAN}Automatically updating target dataset location to '${BOLD}${SRC_TBL_LOCATION}${RESET}${CYAN}' so BigQuery views can query the export table.${RESET}"
      LOCATION="$SRC_TBL_LOCATION"
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

# Ensure Target Dataset exists in the exact same location as the source table
echo -e "\n${CYAN}Step 1: Ensuring BigQuery dataset '${DATASET_ID}' exists in location '${LOCATION}'...${RESET}"
if bq show "${PROJECT_ID}:${DATASET_ID}" >/dev/null 2>&1; then
  EXISTING_DS_LOC=$(get_bq_location "${PROJECT_ID}:${DATASET_ID}")
  if [[ -n "$EXISTING_DS_LOC" && "${EXISTING_DS_LOC^^}" != "${LOCATION^^}" ]]; then
    echo -e "${YELLOW}Warning: Dataset '${PROJECT_ID}:${DATASET_ID}' currently exists in location '${EXISTING_DS_LOC}', but source data is in '${LOCATION}'.${RESET}"
    DS_TABLES_JSON=$(bq ls --max_results=50 --format=json "${PROJECT_ID}:${DATASET_ID}" 2>/dev/null || true)
    DS_TABLES_TRIMMED="${DS_TABLES_JSON#"${DS_TABLES_JSON%%[![:space:]]*}"}"
    NON_DASHBOARD_TABLES=""
    if command -v jq >/dev/null 2>&1 && [[ "$DS_TABLES_TRIMMED" == "["* ]]; then
      NON_DASHBOARD_TABLES=$(printf '%s\n' "$DS_TABLES_TRIMMED" | jq -r '.[]?.tableReference.tableId // empty' 2>/dev/null | grep -Ev '^(vw_ai_consumption_master|vw_ai_cost_anomaly_alerts|sample_ai_billing_export)$' || true)
    fi
    if [[ -z "$NON_DASHBOARD_TABLES" ]]; then
      echo -e "${CYAN}Recreating dataset '${PROJECT_ID}:${DATASET_ID}' in location '${LOCATION}'...${RESET}"
      bq rm -r -f -d "${PROJECT_ID}:${DATASET_ID}" >/dev/null 2>&1 || true
      bq --location="${LOCATION}" mk --dataset \
        --description="AI Billing and Consumption Analytics Dataset" \
        "${PROJECT_ID}:${DATASET_ID}"
      echo -e "${GREEN}Dataset '${DATASET_ID}' recreated in location '${LOCATION}' successfully.${RESET}"
    else
      echo -e "${RED}Error: Dataset '${PROJECT_ID}:${DATASET_ID}' in '${EXISTING_DS_LOC}' contains other tables and cannot be automatically moved to '${LOCATION}'.${RESET}"
      echo -e "${YELLOW}Please re-run and choose a different Dataset ID (such as '${SRC_DATASET_REF:-ai_billing_dashboard_regional}') in location '${LOCATION}'.${RESET}"
      exit 1
    fi
  else
    echo -e "${GREEN}Dataset ${DATASET_ID} already exists (Location: ${EXISTING_DS_LOC:-$LOCATION}).${RESET}"
  fi
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
    SELECT 'Vertex AI' AS service_name, 'C7E2-9256-1C43' AS service_id, 'Gemini 1.5 Pro - Input Prompt Tokens' AS sku_description, 'token' AS usage_unit, 0.00000125 AS unit_price, 45000000.0 AS base_daily_units, 'Generative AI' AS cat
    UNION ALL SELECT 'Vertex AI', 'C7E2-9256-1C43', 'Gemini 1.5 Pro - Output Candidate Tokens', 'token', 0.000005, 22000000.0, 'Generative AI'
    UNION ALL SELECT 'Vertex AI', 'C7E2-9256-1C43', 'Gemini 1.5 Flash - Input Prompt Tokens', 'token', 0.000000075, 300000000.0, 'Generative AI'
    UNION ALL SELECT 'Vertex AI', 'C7E2-9256-1C43', 'Gemini 1.5 Flash - Output Candidate Tokens', 'token', 0.0000003, 120000000.0, 'Generative AI'
    UNION ALL SELECT 'Vertex AI', 'C7E2-9256-1C43', 'Gemini 2.0 Flash - Input Prompt Tokens', 'token', 0.0000001, 250000000.0, 'Generative AI'
    UNION ALL SELECT 'Vertex AI', 'C7E2-9256-1C43', 'Gemini 2.0 Flash - Output Candidate Tokens', 'token', 0.0000004, 100000000.0, 'Generative AI'
    UNION ALL SELECT 'Vertex AI', 'C7E2-9256-1C43', 'Claude 3.5 Sonnet - Input Tokens', 'token', 0.000003, 25000000.0, 'Generative AI'
    UNION ALL SELECT 'Vertex AI', 'C7E2-9256-1C43', 'Claude 3.5 Sonnet - Output Tokens', 'token', 0.000015, 10000000.0, 'Generative AI'
    UNION ALL SELECT 'Vertex AI', 'C7E2-9256-1C43', 'Text Embedding Gecko / Multimodal Embeddings', 'token', 0.000000025, 600000000.0, 'Generative AI'
    UNION ALL SELECT 'Vertex AI', 'C7E2-9256-1C43', 'Imagen 3 - Image Generation', 'request', 0.03, 1800.0, 'Generative AI'
    UNION ALL SELECT 'Discovery Engine', 'A123-4567-8901', 'Vertex AI Search & Conversation Queries', 'request', 0.005, 12000.0, 'Agentic & Conversational AI'
    UNION ALL SELECT 'Dialogflow CX', 'B234-5678-9012', 'Dialogflow CX Conversation Sessions', 'request', 0.007, 10000.0, 'Agentic & Conversational AI'
    UNION ALL SELECT 'Document AI', 'D456-7890-1234', 'Document AI - Form Parser Pages', 'page', 0.05, 1200.0, 'Perception & Cognitive AI'
    UNION ALL SELECT 'Compute Engine', '6F81-5844-456A', 'NVIDIA A100 80GB GPU running in Americas', 'hour', 3.67, 36.0, 'AI Compute (GPU/TPU)'
    UNION ALL SELECT 'Compute Engine', '6F81-5844-456A', 'NVIDIA H100 80GB GPU running in Americas', 'hour', 10.50, 24.0, 'AI Compute (GPU/TPU)'
    UNION ALL SELECT 'Compute Engine', '6F81-5844-456A', 'NVIDIA L4 GPU running in Americas', 'hour', 0.85, 48.0, 'AI Compute (GPU/TPU)'
    UNION ALL SELECT 'Compute Engine', '6F81-5844-456A', 'Cloud TPU v5e Pod Slice Running in us-central1', 'hour', 1.80, 48.0, 'AI Compute (GPU/TPU)'
    UNION ALL SELECT 'Vertex AI', 'C7E2-9256-1C43', 'Vector Search Index Serving e2-standard-16', 'hour', 1.25, 48.0, 'Vector Search & Embeddings Infra'
    UNION ALL SELECT 'Duet AI', 'E567-8901-2345', 'Duet AI: Gemini Code Assist Subscription', 'month', 45.0, 0.80, 'Enterprise AI Subscriptions (Seats)'
    UNION ALL SELECT 'Vertex AI Search', 'F678-9012-3456', 'Vertex AI Search: Gemini Enterprise Standard 1-Yr Subscription', 'month', 35.0, 0.60, 'Enterprise AI Subscriptions (Seats)'
    UNION ALL SELECT 'Gemini API', 'G789-0123-4567', 'Gemini 2.5 Flash - Thinking Text Output Tokens', 'token', 0.0000006, 70000000.0, 'Generative AI'
    UNION ALL SELECT 'Vertex AI', 'C7E2-9256-1C43', 'Gemini 2.5 Pro - Thinking Text Output Tokens', 'token', 0.0000075, 15000000.0, 'Generative AI'
    UNION ALL SELECT 'Gemini API', 'G789-0123-4567', 'Gemini 3.5 Flash - Input Prompt Tokens', 'token', 0.00000015, 200000000.0, 'Generative AI'
    UNION ALL SELECT 'Gemini API', 'G789-0123-4567', 'Gemini 3.5 Flash - Output Candidate Tokens', 'token', 0.0000006, 90000000.0, 'Generative AI'
  ),
  raw_combinations AS (
    SELECT
      d.day,
      p.project_id,
      p.project_name,
      p.env,
      p.team,
      p.cost_center,
      s.service_id,
      s.service_name,
      s.sku_description,
      s.usage_unit,
      s.unit_price,
      CASE
        WHEN s.usage_unit = 'month' THEN ROUND(s.base_daily_units * (0.85 + RAND() * 0.30), 4)
        WHEN s.usage_unit = 'hour' THEN ROUND(s.base_daily_units * (0.75 + RAND() * 0.50), 2)
        WHEN s.usage_unit = 'token' THEN ROUND(s.base_daily_units * (0.70 + RAND() * 0.60), 0)
        ELSE ROUND(s.base_daily_units * (0.70 + RAND() * 0.60), 0)
      END AS generated_units
    FROM date_range d
    CROSS JOIN projects p
    CROSS JOIN services_and_skus s
  )
  SELECT
    '01ABCD-23EF45-678901' AS billing_account_id,
    TIMESTAMP(r.day) AS usage_start_time,
    TIMESTAMP_ADD(TIMESTAMP(r.day), INTERVAL 1 DAY) AS usage_end_time,
    TIMESTAMP(CURRENT_TIMESTAMP()) AS export_time,
    STRUCT(
      r.project_id AS id,
      r.project_name AS name,
      '123456789' AS number,
      [STRUCT('env' AS key, r.env AS value)] AS labels,
      '' AS ancestry_numbers
    ) AS project,
    STRUCT(
      r.service_id AS id,
      r.service_name AS description
    ) AS service,
    STRUCT(
      GENERATE_UUID() AS id,
      r.sku_description AS description
    ) AS sku,
    STRUCT(
      'us-central1' AS location,
      'us-central1' AS region,
      'us-central1-a' AS zone,
      'US' AS country
    ) AS location,
    STRUCT(
      FORMAT_DATE('%Y%m', r.day) AS month
    ) AS invoice,
    'regular' AS cost_type,
    'USD' AS currency,
    1.0 AS currency_conversion_rate,
    STRUCT(
      CAST(r.generated_units AS FLOAT64) AS amount,
      r.usage_unit AS unit,
      CAST(r.generated_units AS FLOAT64) AS amount_in_pricing_units,
      r.usage_unit AS pricing_unit
    ) AS usage,
    ROUND(r.generated_units * r.unit_price, 2) AS cost,
    IF(RAND() > 0.35, [STRUCT('Committed Use Discount' AS name, ROUND(-1 * (r.generated_units * r.unit_price) * (0.08 + RAND() * 0.07), 2) AS amount, 'CUD Credit' AS full_name, 'CREDIT-1' AS id, 'DISCOUNT' AS type)], []) AS credits,
    [
      STRUCT('environment' AS key, r.env AS value),
      STRUCT('team' AS key, r.team AS value),
      STRUCT('cost_center' AS key, r.cost_center AS value),
      STRUCT('app' AS key, 'Enterprise AI Platform' AS value)
    ] AS labels,
    [] AS system_labels
  FROM raw_combinations r;
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
    ABS(COALESCE((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)) AS abs_total_credits,
    GREATEST(0.0, cost + COALESCE((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)) AS net_cost,
    CASE
      WHEN usage.unit = 'token' THEN usage.amount / 1000000.0
      ELSE usage.amount
    END AS estimated_million_tokens,
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
),
classified AS (
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
  FROM raw_billing
)
SELECT
  *,
  CASE
    WHEN ai_category = 'Generative AI' THEN net_cost
    ELSE 0.0
  END AS genai_net_cost
FROM classified;
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
