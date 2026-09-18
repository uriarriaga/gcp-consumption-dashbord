#!/usr/bin/env python3
"""
Looker Studio Automated Report Cloner & Launcher

Clones the public Looker Studio template report:
  https://datastudio.google.com/reporting/c7991054-d499-4aa0-9b2a-e8f98d92ea55
and automatically re-binds its data source (ds0) to your BigQuery
AI billing dataset and view.
"""

import argparse
import os
import subprocess
import sys
import urllib.parse
from pathlib import Path
from typing import Dict, Optional

TEMPLATE_REPORT_ID = "c7991054-d499-4aa0-9b2a-e8f98d92ea55"
CONFIG_FILE_NAME = ".dashboard_config"


def load_local_config(config_path: Optional[Path] = None) -> Dict[str, str]:
    """
    Loads key-value pairs from .dashboard_config file if it exists.
    """
    if config_path is None:
        config_path = Path(__file__).resolve().parent / CONFIG_FILE_NAME

    config = {}
    if config_path.is_file():
        try:
            with open(config_path, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith("#") and "=" in line:
                        k, v = line.split("=", 1)
                        config[k.strip()] = v.strip().strip("\"'")
        except Exception:
            pass
    return config


def get_active_gcloud_project() -> Optional[str]:
    """
    Retrieves the currently active Google Cloud project from gcloud config.
    """
    try:
        res = subprocess.run(
            ["gcloud", "config", "get-value", "project"],
            capture_output=True,
            text=True,
            check=False
        )
        project = res.stdout.strip()
        if project and project != "(unset)":
            return project
    except Exception:
        pass
    return None


def generate_looker_studio_clone_url(
    project_id: str,
    dataset_id: str,
    table_id: str = "vw_ai_consumption_master",
    template_report_id: str = TEMPLATE_REPORT_ID,
    report_name: str = "Google Cloud AI Consumption & Cost Dashboard"
) -> str:
    """
    Constructs the Looker Studio Linking API URL to copy a template report
    and connect it directly to a BigQuery table/view.
    """
    if not project_id:
        raise ValueError("project_id is required")
    if not dataset_id:
        raise ValueError("dataset_id is required")

    base_url = "https://lookerstudio.google.com/reporting/create"

    params = {
        "c.reportId": template_report_id,
        "r.reportName": report_name,
        "ds.ds0.connector": "bigQuery",
        "ds.ds0.type": "TABLE",
        "ds.ds0.projectId": project_id,
        "ds.ds0.datasetId": dataset_id,
        "ds.ds0.tableId": table_id,
        "ds.ds0.billingProjectId": project_id,
    }

    encoded_params = urllib.parse.urlencode(params)
    return f"{base_url}?{encoded_params}"


def parse_args():
    parser = argparse.ArgumentParser(
        description="Generate a 1-click Looker Studio template clone URL bound to your BigQuery view.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter
    )
    parser.add_argument("-p", "--project", dest="project", help="Target Google Cloud Project ID")
    parser.add_argument("-d", "--dataset", dest="dataset", help="Target BigQuery Dataset ID")
    parser.add_argument("-t", "--table", dest="table", default=None, help="Target BigQuery View/Table ID")
    parser.add_argument("--template-id", dest="template_id", default=None, help="Looker Studio Template Report ID")
    parser.add_argument("--report-name", dest="report_name", default="Google Cloud AI Consumption & Cost Dashboard", help="Report name")
    parser.add_argument("positional_args", nargs="*", help="Optional positional args: [project] [dataset] [table] [template_id]")
    return parser.parse_args()


def main():
    try:
        if hasattr(sys.stdout, "reconfigure"):
            sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        if hasattr(sys.stderr, "reconfigure"):
            sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

    args = parse_args()
    config = load_local_config()

    # Handle positional arguments for backward compatibility
    pos_project = args.positional_args[0] if len(args.positional_args) > 0 else None
    pos_dataset = args.positional_args[1] if len(args.positional_args) > 1 else None
    pos_table = args.positional_args[2] if len(args.positional_args) > 2 else None
    pos_template = args.positional_args[3] if len(args.positional_args) > 3 else None

    # Resolution hierarchy for Project ID:
    # 1. Named CLI argument
    # 2. Positional CLI argument
    # 3. .dashboard_config file
    # 4. Environment variables
    # 5. gcloud active project
    project = (
        args.project
        or pos_project
        or config.get("PROJECT_ID")
        or os.getenv("GCP_PROJECT_ID")
        or os.getenv("GOOGLE_CLOUD_PROJECT")
        or os.getenv("CLOUDSDK_CORE_PROJECT")
        or get_active_gcloud_project()
    )

    if not project and sys.stdin.isatty():
        try:
            user_input = input("Enter Google Cloud Project ID: ").strip()
            if user_input:
                project = user_input
        except EOFError:
            pass

    if not project:
        sys.stderr.write(
            "\n[ERROR] Google Cloud Project ID could not be determined.\n"
            "Please specify via:\n"
            "  python3 create_looker_studio_dashboard.py --project <PROJECT_ID> --dataset <DATASET_ID>\n"
            "or run ./deploy_ai_dashboard.sh first.\n\n"
        )
        sys.exit(1)

    # Resolution hierarchy for Dataset ID:
    dataset = (
        args.dataset
        or pos_dataset
        or config.get("DATASET_ID")
        or os.getenv("DATASET_ID")
    )

    # Support project.dataset format in dataset argument
    if dataset and ("." in dataset or ":" in dataset):
        sep = "." if "." in dataset else ":"
        parts = dataset.split(sep, 1)
        if not args.project and not pos_project:
            project = parts[0]
        dataset = parts[1]

    if not dataset and sys.stdin.isatty():
        try:
            default_ds = config.get("DATASET_ID", "ai_billing_dashboard")
            user_input = input(f"Enter BigQuery Dataset ID [{default_ds}]: ").strip()
            dataset = user_input if user_input else default_ds
        except EOFError:
            pass

    if not dataset:
        dataset = "ai_billing_dashboard"

    # Resolution hierarchy for View/Table ID:
    table = (
        args.table
        or pos_table
        or config.get("VIEW_NAME")
        or "vw_ai_consumption_master"
    )

    # Resolution for Template Report ID:
    template_id = (
        args.template_id
        or pos_template
        or config.get("TEMPLATE_REPORT_ID")
        or TEMPLATE_REPORT_ID
    )

    report_name = args.report_name

    url = generate_looker_studio_clone_url(
        project_id=project,
        dataset_id=dataset,
        table_id=table,
        template_report_id=template_id,
        report_name=report_name
    )

    print("=" * 78)
    print(" [*] Looker Studio 1-Click Automated Dashboard Cloner")
    print("=" * 78)
    print(f"\nTemplate Report ID : {template_id}")
    print(f"Template URL       : https://datastudio.google.com/reporting/{template_id}")
    print(f"Target Project     : {project}")
    print(f"Target Dataset     : {dataset}")
    print(f"Target View/Table  : {table}\n")
    print(">>> Click the URL below to automatically copy the template & bind your data:")
    print(f"\n{url}\n")
    print("=" * 78)
    print("Operational Best Practices:")
    print("  1. Credentials: In Looker Studio, configure data source credentials to")
    print("     'Viewer\'s Credentials' so access respects BigQuery IAM permissions.")
    print("  2. Sharing: The URL above is for initial creation/editing.")
    print("     To distribute to stakeholders, click the 'Share' button inside Looker Studio.")
    print("=" * 78)


if __name__ == "__main__":
    main()

