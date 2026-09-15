#!/usr/bin/env python3
"""
Looker Studio Automated Report Cloner & Launcher

Clones the public Looker Studio template report:
  https://datastudio.google.com/reporting/c7991054-d499-4aa0-9b2a-e8f98d92ea55
and automatically re-binds its data source (ds0) to your BigQuery
AI billing dataset and view.
"""

import urllib.parse
import sys

TEMPLATE_REPORT_ID = "c7991054-d499-4aa0-9b2a-e8f98d92ea55"


def generate_looker_studio_clone_url(
    project_id: str = "uri-test-491314",
    dataset_id: str = "ai_billing_dashboard",
    table_id: str = "vw_ai_consumption_master",
    template_report_id: str = TEMPLATE_REPORT_ID,
    report_name: str = "Google Cloud AI Consumption & Cost Dashboard"
) -> str:
    """
    Constructs the Looker Studio Linking API URL to copy a template report
    and connect it directly to a BigQuery table/view.
    """
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


if __name__ == "__main__":
    project = sys.argv[1] if len(sys.argv) > 1 else "uri-test-491314"
    dataset = sys.argv[2] if len(sys.argv) > 2 else "ai_billing_dashboard"
    table = sys.argv[3] if len(sys.argv) > 3 else "vw_ai_consumption_master"
    template_id = sys.argv[4] if len(sys.argv) > 4 else TEMPLATE_REPORT_ID

    url = generate_looker_studio_clone_url(project, dataset, table, template_id)

    print("=" * 75)
    print(" 🚀 Looker Studio 1-Click Automated Dashboard Cloner")
    print("=" * 75)
    print(f"\nTemplate Report ID : {template_id}")
    print(f"Template URL       : https://datastudio.google.com/reporting/{template_id}")
    print(f"Target Project     : {project}")
    print(f"Target Dataset     : {dataset}")
    print(f"Target View/Table  : {table}\n")
    print("👉 Click the URL below to automatically copy the template & bind your data:")
    print(f"\n{url}\n")
    print("=" * 75)
