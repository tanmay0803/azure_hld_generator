import subprocess
import json
import csv
import sys
import time
import random
import os
import re
from collections import defaultdict

from html import escape
from zipfile import ZIP_DEFLATED, ZipFile

# =====================================================
# CONFIGURATION
# =====================================================

 
MG_ID = "Dubai_Holding"
API_VERSION = "2025-03-01"
 
RESOURCE_GROUPS = [
    "rg-jumeriahio-uat-dhh-nonprod-001",
    "rg-jumeirah-onlinecheckin-uat-dhh-nonprod-001",
    "rg-jcom-web-dev-dhh-nonprod-001",
    "rg-jcom-web-uat-dhh-nonprod-001",
    "rg-jcom-web-prod-dhh-prod-001",
    "rg-carbonblack-hub-prod-001",
    "rg-secservervapt-hub-prod-001",
    "rg-empapp-uat-dhre-nonprod-001",
    "rg-Jumeirah-analytics-prod-dhh-001",
    "rg-jumcolleagueconnect-uat-dhh-nonprod-001",
    "rg-Jumeirah-analytics-dev-dhh-nonprod-001"
]
 
# End dates are exclusive
 
MONTHS = {
    "January 2026": (
        "2026-01-01T00:00:00Z",
        "2026-02-01T00:00:00Z"
    ),
    "February 2026": (
        "2026-02-01T00:00:00Z",
        "2026-03-01T00:00:00Z"
    ),
    "March 2026": (
        "2026-03-01T00:00:00Z",
        "2026-04-01T00:00:00Z"
    ),
    "April 2026": (
        "2026-04-01T00:00:00Z",
        "2026-05-01T00:00:00Z"
    ),
    "May 2026": (
        "2026-05-01T00:00:00Z",
        "2026-06-01T00:00:00Z"
    ),
    "June 2026": (
        "2026-06-01T00:00:00Z",
        "2026-07-01T00:00:00Z"
    ),
    "July 2026": (
        "2026-07-01T00:00:00Z",
        "2026-08-01T00:00:00Z"
    ),
    "August 2026": (
        "2026-08-01T00:00:00Z",
        "2026-09-01T00:00:00Z"
    ),
    "September 2026": (
        "2026-09-01T00:00:00Z",
        "2026-10-01T00:00:00Z"
    ),
    "October 2026": (
        "2026-10-01T00:00:00Z",
        "2026-11-01T00:00:00Z"
    )
}
 
OUTPUT_FILE = "Azure_RG_Cost_Report_2026_FINAL.csv"
EXCEL_FILE = "cost_mgmt_final.xlsx"
COST_REDUCTION_PERCENT = 3.555
 
DEBUG_FOLDER = "Azure_Cost_Debug_2026_FINAL"
 
# =====================================================
# API URL
# =====================================================
 
URL = (
    "https://management.azure.com/providers/"
    f"Microsoft.Management/managementGroups/{MG_ID}/"
    "providers/Microsoft.CostManagement/query"
    f"?api-version={API_VERSION}"
)
 
# =====================================================
# INITIALIZE REPORT
# =====================================================
 
report = {}
 
for rg in RESOURCE_GROUPS:
 
    report[rg] = {
        "Resource Group": rg
    }
 
    for month in MONTHS:
        report[rg][month] = "NO DATA"
 
os.makedirs(DEBUG_FOLDER, exist_ok=True)
 
# Case-insensitive resource group lookup
RG_LOOKUP = {
    rg.lower(): rg
    for rg in RESOURCE_GROUPS
}


def apply_cost_reduction(amount):
    """Apply the configured reporting adjustment to a raw Azure cost."""
    return round(float(amount) * (1 - COST_REDUCTION_PERCENT / 100), 2)
 
# =====================================================
# AZURE LOGIN CHECK
# =====================================================
 
def check_azure_login():
 
    print("\nChecking Azure authentication...")
 
    result = subprocess.run(
        ["az", "account", "show", "--output", "json"],
        capture_output=True,
        text=True
    )
 
    if result.returncode != 0:
 
        print("Azure authentication failed.")
        print("Run: az login")
        sys.exit(1)
 
    account = json.loads(result.stdout)
 
    print("Azure authentication successful.")
    print("Account:", account.get("user", {}).get("name"))
    print("Tenant:", account.get("tenantId"))
    print("Subscription:", account.get("name"))
 
# =====================================================
# AZURE API REQUEST
# =====================================================
 
def call_api(payload, month):
 
    for attempt in range(8):
 
        result = subprocess.run(
            [
                "az",
                "rest",
                "--method", "post",
                "--url", URL,
                "--headers", "Content-Type=application/json",
                "--body", json.dumps(payload),
                "--output", "json"
            ],
            capture_output=True,
            text=True
        )
 
        if result.returncode == 0:
 
            return json.loads(result.stdout)
 
        error = result.stderr
 
        # Authentication / query errors
        if any(code in error for code in [
            "RBACAccessDenied",
            "Unauthorized",
            "AuthorizationFailed",
            "BadRequest"
        ]):
 
            raise Exception(error)
 
        # Retry actual throttling only
        is_throttled = (
            "TooManyRequests" in error
            or (
                re.search(r"\b429\b", error) is not None
                and "BadRequest" not in error
            )
        )
 
        if is_throttled:
 
            wait = min(60, (2 ** attempt) * 5)
            wait += random.uniform(0, 3)
 
            print(
                f"Throttled on {month}. "
                f"Retrying in {wait:.1f} seconds..."
            )
 
            time.sleep(wait)
            continue
 
        raise Exception(error)
 
    raise Exception(
        f"Maximum retries exceeded for {month}"
    )
 
# =====================================================
# PROCESS MONTHLY COST
# =====================================================
 
def process_month(month, dates):
 
    print("\n" + "=" * 65)
    print("FETCHING:", month)
    print("FROM:", dates[0])
    print("TO:", dates[1])
    print("=" * 65)
 
    payload = {
 
        "type": "ActualCost",
 
        "timeframe": "Custom",
 
        "timePeriod": {
            "from": dates[0],
            "to": dates[1]
        },
 
        "dataset": {
 
            "granularity": "Monthly",
 
            "aggregation": {
 
                "totalCost": {
                    "name": "PreTaxCost",
                    "function": "Sum"
                }
 
            },
 
            "grouping": [
 
                {
                    "type": "Dimension",
                    "name": "ResourceGroupName"
                }
 
            ],
 
            "filter": {
 
                "dimensions": {
 
                    "name": "ResourceGroupName",
 
                    "operator": "In",
 
                    "values": RESOURCE_GROUPS
 
                }
 
            }
 
        }
 
    }
 
    response = call_api(payload, month)
 
    # Save raw API response
    debug_file = os.path.join(
        DEBUG_FOLDER,
        month.replace(" ", "_") + ".json"
    )
 
    with open(
        debug_file,
        "w",
        encoding="utf-8"
    ) as f:
 
        json.dump(response, f, indent=4)
 
    properties = response.get("properties", {})
 
    columns = [
        c["name"]
        for c in properties.get("columns", [])
    ]
 
    rows = properties.get("rows", [])
 
    print("\nReturned columns:", columns)
    print("Total API records:", len(rows))
 
    if "ResourceGroupName" not in columns:
        raise Exception("ResourceGroupName column missing.")
 
    if "PreTaxCost" not in columns:
        raise Exception("PreTaxCost column missing.")

    # The query succeeded and returned the expected schema. Resource groups
    # with no cost rows for this month therefore start at zero; matched rows
    # below replace zero with their aggregated cost. Query failures are marked
    # as ERROR by the caller and never reach this point.
    for rg in RESOURCE_GROUPS:
        report[rg][month] = 0
 
    # =================================================
    # IMPORTANT: AGGREGATE DUPLICATE RESOURCE GROUPS
    # =================================================
 
    # Store the SUM of every record per resource group
    monthly_totals = defaultdict(float)
 
    # Keep billing month information for diagnostics
    billing_month_details = defaultdict(list)
 
    currencies = defaultdict(set)
 
    for row in rows:
 
        data = dict(zip(columns, row))
 
        rg = data.get("ResourceGroupName")
 
        if not rg:
            continue
 
        matching_rg = RG_LOOKUP.get(str(rg).lower())
 
        if not matching_rg:
            continue
 
        cost = float(
            data.get("PreTaxCost", 0) or 0
        )
 
        # ADD costs instead of overwriting
        monthly_totals[matching_rg] += cost
 
        billing_month = data.get("BillingMonth", "Unknown")
 
        billing_month_details[matching_rg].append(
            (billing_month, cost)
        )
 
        if "Currency" in data:
            currencies[matching_rg].add(
                str(data["Currency"])
            )
 
    # =================================================
    # WRITE AGGREGATED COSTS TO REPORT
    # =================================================
 
    print("\nAGGREGATED RESOURCE GROUP COSTS")
 
    for rg in RESOURCE_GROUPS:
 
        if rg in monthly_totals:
 
            raw_total_cost = monthly_totals[rg]
            total_cost = apply_cost_reduction(raw_total_cost)
 
            report[rg][month] = total_cost
 
            print("\nResource Group:", rg)
 
            # Display individual records
            for billing_month, cost in billing_month_details[rg]:
 
                print(
                    f"  Billing Month: {billing_month}"
                    f" | Raw Individual Cost: {cost:.2f}"
                )
 
            print(
                f"  RAW TOTAL COST: {raw_total_cost:.2f}"
            )

            print(
                f"  ADJUSTED TOTAL (-{COST_REDUCTION_PERCENT}%): {total_cost:.2f}"
            )
 
            print(
                f"  Currency: {', '.join(sorted(currencies[rg]))}"
            )
 
        else:
 
            print("\nNO RECORD:", rg)
 
    # =================================================
    # MONTH SUMMARY
    # =================================================
 
    print("\nMONTH SUMMARY")
    print("Month:", month)
    print("API records:", len(rows))
    print("Matched resource groups:", len(monthly_totals))
    print("Debug file:", debug_file)
 
# =====================================================
# MAIN EXECUTION
# =====================================================
 
check_azure_login()
 
print("\nAZURE RESOURCE GROUP COST REPORT")
print("Management Group:", MG_ID)
print("Resource Groups:", len(RESOURCE_GROUPS))
print("Months:", len(MONTHS))
 
for month, dates in MONTHS.items():
 
    try:
 
        process_month(month, dates)
 
    except Exception as error:
 
        print("\nFAILED:", month)
        print("ERROR:", error)
 
        for rg in RESOURCE_GROUPS:
            report[rg][month] = "ERROR"
 
        if any(code in str(error) for code in [
            "RBACAccessDenied",
            "Unauthorized",
            "AuthorizationFailed"
        ]):
 
            print("Stopping due to authorization failure.")
            sys.exit(1)
 
# =====================================================
# EXPORT CSV
# =====================================================
 
columns = [
    "Resource Group",
] + [
    f"{month} (Adjusted -{COST_REDUCTION_PERCENT}%)"
    for month in MONTHS
]
 
with open(
    OUTPUT_FILE,
    "w",
    newline="",
    encoding="utf-8-sig"
) as f:
 
    writer = csv.writer(f)
 
    writer.writerow(columns)
 
    for rg in RESOURCE_GROUPS:
        writer.writerow([
            report[rg]["Resource Group"],
            *(report[rg][month] for month in MONTHS),
        ])
 
# =====================================================
# FINAL SUMMARY
# =====================================================
 
print("\n" + "=" * 65)
print("AZURE COST REPORT GENERATED (ADJUSTED COSTS)")
print("=" * 65)
print(f"Reporting adjustment: -{COST_REDUCTION_PERCENT}% from raw PreTaxCost")
print("Raw API responses are preserved in the debug JSON files.")
 
print("CSV File:", os.path.abspath(OUTPUT_FILE))
print("Debug Folder:", os.path.abspath(DEBUG_FOLDER))
 
print("\nFINAL AGGREGATED COST REPORT")
 
for rg in RESOURCE_GROUPS:
 
    print("\n" + rg)
 
    for month in MONTHS:
 
        print(
            f"  {month}: {report[rg][month]}"
        )
 
print("\n" + "=" * 65)
print("PROCESS COMPLETED")
print("=" * 65)
 
 
 
# =====================================================
# GENERATE EXCEL REPORT FROM JSON ARTEFACTS
# =====================================================
 
def generate_excel_report():
    print("\nGenerating Excel workbook from JSON artefacts...")

    json_monthly_data = {}
    detailed_records = []
    currencies_by_month = defaultdict(set)

    for month in MONTHS:
        json_file = os.path.join(
            DEBUG_FOLDER,
            month.replace(" ", "_") + ".json"
        )
        if not os.path.exists(json_file):
            raise FileNotFoundError(f"Missing JSON artefact: {json_file}")

        with open(json_file, "r", encoding="utf-8") as f:
            response = json.load(f)

        properties = response.get("properties", {})
        api_columns = [column["name"] for column in properties.get("columns", [])]
        rows = properties.get("rows", [])
        aggregated = defaultdict(float)

        for row in rows:
            data = dict(zip(api_columns, row))
            rg = data.get("ResourceGroupName")
            if not rg:
                continue

            matching_rg = RG_LOOKUP.get(str(rg).lower())
            if not matching_rg:
                continue

            cost = float(data.get("PreTaxCost", 0) or 0)
            aggregated[matching_rg] += cost
            currency = data.get("Currency", "")
            if currency:
                currencies_by_month[month].add(str(currency))
            detailed_records.append([
                month,
                data.get("BillingMonth", ""),
                matching_rg,
                cost,
                apply_cost_reduction(cost),
                currency,
            ])

        json_monthly_data[month] = aggregated
        print(f"Loaded {month}: {len(rows)} records")

    summary_rows = [[
        "Resource Group",
        *(f"{month} (Adjusted -{COST_REDUCTION_PERCENT}%)" for month in MONTHS),
    ]]
    for rg in RESOURCE_GROUPS:
        values = [rg]
        for month in MONTHS:
            if report[rg][month] == "ERROR":
                values.append("ERROR")
            else:
                values.append(apply_cost_reduction(json_monthly_data[month].get(rg, 0.0)))
        summary_rows.append(values)

    details_rows = [[
        "Requested Month", "Billing Month", "Resource Group",
        "Raw PreTax Cost", f"Adjusted Cost (-{COST_REDUCTION_PERCENT}%)", "Currency"
    ], *detailed_records]

    monthly_rows = [[
        "Month", f"Adjusted Total Cost (-{COST_REDUCTION_PERCENT}%)", "Currency"
    ]]
    for month in MONTHS:
        if any(report[rg][month] == "ERROR" for rg in RESOURCE_GROUPS):
            total = "ERROR"
        else:
            total = apply_cost_reduction(sum(json_monthly_data[month].values()))
        currency = ", ".join(sorted(currencies_by_month[month])) or "Unknown"
        monthly_rows.append([month, total, currency])

    sheets = [
        ("Cost Summary", summary_rows),
        ("Detailed Records", details_rows),
        ("Monthly Totals", monthly_rows),
    ]

    def column_name(number):
        name = ""
        while number:
            number, remainder = divmod(number - 1, 26)
            name = chr(65 + remainder) + name
        return name

    def cell_xml(reference, value, style=None):
        style_attr = f' s="{style}"' if style is not None else ""
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            return f'<c r="{reference}"{style_attr}><v>{value}</v></c>'
        text = escape("" if value is None else str(value))
        return (
            f'<c r="{reference}" t="inlineStr"{style_attr}>'
            f'<is><t xml:space="preserve">{text}</t></is></c>'
        )

    def worksheet_xml(rows):
        row_count = max(len(rows), 1)
        col_count = max((len(row) for row in rows), default=1)
        dimension = f"A1:{column_name(col_count)}{row_count}"
        xml_rows = []
        for row_num, row in enumerate(rows, start=1):
            cells = []
            for col_num, value in enumerate(row, start=1):
                style = 1 if row_num == 1 else (2 if isinstance(value, (int, float)) else None)
                cells.append(cell_xml(f"{column_name(col_num)}{row_num}", value, style))
            xml_rows.append(f'<row r="{row_num}">{"".join(cells)}</row>')

        return (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
            f'<dimension ref="{dimension}"/>'
            '<sheetViews><sheetView workbookViewId="0">'
            '<pane xSplit="1" ySplit="1" topLeftCell="B2" activePane="bottomRight" state="frozen"/>'
            '</sheetView></sheetViews>'
            f'<sheetFormatPr defaultRowHeight="15"/><sheetData>{"".join(xml_rows)}</sheetData>'
            f'<autoFilter ref="{dimension}"/>'
            '</worksheet>'
        )

    content_types = [
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">',
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
        '<Default Extension="xml" ContentType="application/xml"/>',
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>',
        '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>',
    ]
    for index in range(1, len(sheets) + 1):
        content_types.append(
            f'<Override PartName="/xl/worksheets/sheet{index}.xml" '
            'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        )
    content_types.append('</Types>')

    workbook_sheets = "".join(
        f'<sheet name="{escape(name)}" sheetId="{index}" r:id="rId{index}"/>'
        for index, (name, _) in enumerate(sheets, start=1)
    )
    workbook_xml = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        f'<sheets>{workbook_sheets}</sheets></workbook>'
    )
    workbook_rels = [
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
    ]
    for index in range(1, len(sheets) + 1):
        workbook_rels.append(
            f'<Relationship Id="rId{index}" '
            'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" '
            f'Target="worksheets/sheet{index}.xml"/>'
        )
    workbook_rels.append(
        f'<Relationship Id="rId{len(sheets) + 1}" '
        'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" '
        'Target="styles.xml"/></Relationships>'
    )
    root_rels = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" '
        'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" '
        'Target="xl/workbook.xml"/></Relationships>'
    )
    styles_xml = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<numFmts count="1"><numFmt numFmtId="164" formatCode="#,##0.00"/></numFmts>'
        '<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font>'
        '<font><b/><color rgb="FFFFFFFF"/><sz val="11"/><name val="Calibri"/></font></fonts>'
        '<fills count="3"><fill><patternFill patternType="none"/></fill>'
        '<fill><patternFill patternType="gray125"/></fill>'
        '<fill><patternFill patternType="solid"><fgColor rgb="FF17365D"/>'
        '<bgColor indexed="64"/></patternFill></fill></fills>'
        '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
        '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
        '<cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
        '<xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1" applyAlignment="1">'
        '<alignment horizontal="center" vertical="center"/></xf>'
        '<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs>'
        '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
        '</styleSheet>'
    )

    with ZipFile(EXCEL_FILE, "w", ZIP_DEFLATED) as workbook:
        workbook.writestr("[Content_Types].xml", "".join(content_types))
        workbook.writestr("_rels/.rels", root_rels)
        workbook.writestr("xl/workbook.xml", workbook_xml)
        workbook.writestr("xl/_rels/workbook.xml.rels", "".join(workbook_rels))
        workbook.writestr("xl/styles.xml", styles_xml)
        for index, (_, rows) in enumerate(sheets, start=1):
            workbook.writestr(
                f"xl/worksheets/sheet{index}.xml",
                worksheet_xml(rows),
            )

    print("\n==============================================")
    print("EXCEL REPORT GENERATED SUCCESSFULLY")
    print("==============================================")
    print("Excel File:", os.path.abspath(EXCEL_FILE))
    print("Worksheets:", len(sheets))
    print("JSON records:", len(detailed_records))
    print("Resource Groups:", len(RESOURCE_GROUPS))
    print("==============================================")


generate_excel_report()
