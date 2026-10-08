#!/bin/bash
# ==============================================================================
# Azure Management Group -> HLD Generator
# Template: Esolutions_LLD_v0.2.docx
#
# Purpose:
#   1. Discover every subscription beneath a Management Group.
#   2. Inventory Azure infrastructure in every discovered subscription.
#   3. Generate a Word HLD using the supplied DOCX as the formatting baseline.
#
# Prerequisites:
#   - Azure Cloud Shell (Bash) or Linux workstation
#   - Azure CLI: az
#   - Python 3
#   - python-docx (the script installs it if missing)
#
# Usage:
#   ./generate_hld.sh <MANAGEMENT_GROUP_ID> [TEMPLATE_DOCX] [OUTPUT_DOCX]
#
# Example:
#   ./generate_hld.sh mg-esolutions ./Esolutions_LLD_v0.2.docx ./ESolutions_HLD.docx
#
# Optional environment variables:
#   HLD_AUTHOR="Cloud4C"
#   HLD_REVIEWER="TBD"
#   HLD_APPROVER="TBD"
#   HLD_CLASSIFICATION="Confidential"
#   HLD_REGION="UAE North"
#   SUBSCRIPTION_IDS="<id1>,<id2>" to limit inventory to selected subscriptions
#   REUSE_INVENTORY="1" to skip Azure discovery and reuse inventory.json
#   MG_STRUCTURE_FILE="./management_group_structure.txt" for portal-pasted evidence
#   MG_STRUCTURE_IMAGE="./management_group_structure.png" for portal screenshot evidence
#   FOUNDRY_PROJECT_ENDPOINT, FOUNDRY_AGENT_NAME, FOUNDRY_AGENT_VERSION
#   FOUNDRY_MAX_INPUT_CHARS=9000 to set the serialized evidence batch size
#   FOUNDRY_TRACING_ENABLED=0 to disable OpenTelemetry traces (enabled by default)
#   FOUNDRY_OTEL_ENDPOINT=http://localhost:4318 for the OTLP HTTP collector
#   AI_DEBUG_CITATIONS=1 to log rejected and available evidence citations
#   MODEL_ENRICHMENT_ENABLED=0 to skip Foundry agent design-note enrichment
#   AGENT_ENRICHMENT_ENABLED remains accepted as a legacy setting
#   The script automatically loads ENV_FILE (default: ./.env) when present.
#   Optional Agent tracing packages:
#   opentelemetry-instrumentation-openai-v2==2.1b0
#   opentelemetry-sdk==1.34.1
#   opentelemetry-exporter-otlp-proto-http==1.34.1
#
# Notes:
#   - Read-only discovery only. No Azure resources are changed.
#   - Foundry agent authentication uses DefaultAzureCredential.
#   - The agent classifies selected Azure architecture evidence; failures do not
#     prevent deterministic HLD generation.
#   - The generated document reports what Azure exposes to the current identity.
#   - Resources for which the caller lacks read permission are recorded as
#     "Not accessible" rather than invented.
# ==============================================================================

set -uo pipefail

ENV_FILE="${ENV_FILE:-.env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  source "$ENV_FILE" || {
    echo "ERROR: Could not load environment file: $ENV_FILE"
    exit 1
  }
  set +a
fi
MODEL_ENRICHMENT_ENABLED="${MODEL_ENRICHMENT_ENABLED:-${AGENT_ENRICHMENT_ENABLED:-1}}"
export MODEL_ENRICHMENT_ENABLED

MG_ID="${1:-}"
TEMPLATE="${2:-Esolutions_LLD_v0.2.docx}"
OUTPUT="${3:-Azure_HLD_$(date +%Y%m%d_%H%M%S).docx}"

if [[ -z "$MG_ID" ]]; then
  echo "Usage: $0 <MANAGEMENT_GROUP_ID> [TEMPLATE_DOCX] [OUTPUT_DOCX]"
  exit 1
fi

if ! command -v az >/dev/null 2>&1; then
  echo "ERROR: Azure CLI (az) is required."
  exit 1
fi

echo "Checking Azure Resource Graph extension..."
if ! az extension show --name resource-graph >/dev/null 2>&1; then
    if ! az extension add --name resource-graph --only-show-errors; then
        echo "WARNING: Could not install the Azure Resource Graph extension."
        echo "WARNING: ARG-backed inventory will use Azure CLI fallbacks where available."
    fi
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: Python 3 is required."
  exit 1
fi

if [[ "$MODEL_ENRICHMENT_ENABLED" != "0" ]] &&
   ! python3 -c "from azure.ai.projects import AIProjectClient; from azure.identity import DefaultAzureCredential; from openai import RateLimitError" >/dev/null 2>&1; then
  echo "[AI] SKIPPED: Foundry Agent dependencies are unavailable; continuing without AI analysis."
  echo 'Install them with: python3 -m pip install "azure-ai-projects>=2.1.0" azure-identity openai'
  MODEL_ENRICHMENT_ENABLED=0
  export MODEL_ENRICHMENT_ENABLED
fi

if [[ ! -f "$TEMPLATE" ]]; then
  echo "ERROR: Template not found: $TEMPLATE"
  exit 1
fi

echo "Checking Azure login..."
if ! az account show >/dev/null 2>&1; then
  echo "Not logged in. Running 'az login'..."
  az login >/dev/null || exit 1
fi

# TMP_DIR="$(mktemp -d)"
# trap 'rm -rf "$TMP_DIR"' EXIT

DISCOVERY="./discovery.json"
INVENTORY="./inventory.json"
RESOURCES="./resources.json"

echo "Discovering Management Group hierarchy: $MG_ID"

export MG_ID DISCOVERY INVENTORY

if [[ "${REUSE_INVENTORY:-0}" == "1" ]]; then
    if [[ ! -f "$INVENTORY" && -f "$RESOURCES" ]]; then
        INVENTORY="$RESOURCES"
        export INVENTORY
    fi
    if [[ ! -f "$INVENTORY" ]]; then
        echo "ERROR: REUSE_INVENTORY=1 but neither $INVENTORY nor $RESOURCES was found."
        exit 1
    fi
    echo "Reusing existing inventory: $INVENTORY"
else
# --expand --recurse returns the management-group tree including descendants.
if ! az account management-group show \
      --name "$MG_ID" \
      --expand \
      --recurse \
      -o json > "$DISCOVERY" 2>mg.err; then

  echo "WARNING: Could not read Management Group hierarchy."
  echo "Falling back to accessible subscriptions."

  echo "{}" > "$DISCOVERY"
fi


python3 - <<'PY'
import json, os, subprocess, sys
from pathlib import Path

MG_ID = os.environ["MG_ID"]
discovery_file = Path(os.environ["DISCOVERY"])
inventory_file = Path(os.environ["INVENTORY"])

def run(cmd, default=None):
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           text=True, check=False)
        if p.returncode != 0:
            return default if default is not None else []
        if not p.stdout.strip():
            return default if default is not None else []
        return json.loads(p.stdout)
    except Exception:
        return default if default is not None else []

tree = json.loads(discovery_file.read_text())

subscriptions = {}

#
# First try Management Group tree
#
def walk(node, parent_path=None):

    if not isinstance(node, dict):
        return

    props = node.get("properties", {})

    display = (
        node.get("name")
        or props.get("displayName")
        or ""
    )

    path = (
        parent_path or []
    ) + [display]

    #
    # Check current node
    #
    ntype = (
        node.get("type", "")
        .lower()
    )

    name = node.get("name", "")

    if (
        "subscription" in ntype
        or (
            isinstance(name, str)
            and len(name) == 36
            and name.count("-") == 4
        )
    ):

        subscriptions[name] = {

            "subscription_id": name,

            "management_group_path":
                " / ".join(path),

            "management_group":
                MG_ID
        }

    #
    # Traverse children
    #
    for child in props.get(
        "children",
        []
    ):
        walk(
            child,
            path
        )

walk(tree)

#
# If MG traversal finds nothing
# fall back to accessible subscriptions
#
if len(subscriptions) == 0:

    print(
        "MG traversal returned 0 subscriptions."
        " Using az account list fallback.",
        file=sys.stderr
    )

    p = subprocess.run(
        [
            "az",
            "account",
            "list",
            "-o",
            "json"
        ],
        stdout=subprocess.PIPE,
        text=True
    )

    all_subs = json.loads(
        p.stdout
    )

    for sub in all_subs:

        sid = sub.get("id")

        if not sid:
            continue

        subscriptions[sid] = {

            "subscription_id": sid,

            "management_group_path":
                MG_ID,

            "management_group":
                MG_ID
        }

subs = sorted(
    subscriptions.values(),
    key=lambda x:
        x["subscription_id"]
)

print(
    f"Discovered "
    f"{len(subs)} "
    f"subscription(s).",
    file=sys.stderr
)
# Some CLI versions return subscriptions in a separate list instead of the
# recursively expanded tree. Merge those if present.
for sid_obj in run(["az","account","management-group","subscription","show",
                    "--name",MG_ID,"-o","json"], default=[]) or []:
    if isinstance(sid_obj, dict):
        sid = sid_obj.get("name") or sid_obj.get("id","").split("/")[-1]
        if sid:
            subscriptions.setdefault(sid, {
                "subscription_id": sid,
                "management_group_path": MG_ID,
                "management_group": MG_ID
            })

selected_subscription_ids = {
    sid.strip().lower()
    for sid in os.environ.get("SUBSCRIPTION_IDS", "").split(",")
    if sid.strip()
}
if selected_subscription_ids:
    discovered_ids = {sid.lower() for sid in subscriptions}
    missing_ids = selected_subscription_ids - discovered_ids
    if missing_ids:
        print(
            "ERROR: SUBSCRIPTION_IDS contains subscriptions not discovered "
            f"under management group {MG_ID}: {', '.join(sorted(missing_ids))}",
            file=sys.stderr
        )
        sys.exit(1)
    subscriptions = {
        sid: subscription
        for sid, subscription in subscriptions.items()
        if sid.lower() in selected_subscription_ids
    }

subs = sorted(subscriptions.values(), key=lambda x: x["subscription_id"])

def az_for_sub(sid, args, default=None):
    return run(["az"] + args + ["--subscription", sid, "-o", "json"], default)


def run_azure_cli_json(sid, args, setting_label):
    try:
        process = subprocess.run(
            ["az"] + args + ["--subscription", sid, "-o", "json"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
    except OSError as error:
        print(
            f"WARNING: Unable to collect {setting_label} with Azure CLI: {error}",
            file=sys.stderr,
        )
        return None

    if process.returncode != 0:
        print(
            f"WARNING: Azure CLI could not collect {setting_label} "
            f"(exit code {process.returncode}).",
            file=sys.stderr,
        )
        return None
    if not process.stdout.strip():
        return None

    try:
        return json.loads(process.stdout)
    except json.JSONDecodeError as error:
        print(
            f"WARNING: Azure CLI returned invalid JSON for {setting_label}: "
            f"{error}",
            file=sys.stderr,
        )
        return None


def arg_query(sid, query):

    result = run(
        [
            "az",
            "graph",
            "query",
            "-q",
            query,
            "--subscriptions",
            sid,
            "-o",
            "json"
        ],
        {}
    )

    if isinstance(result, dict):
        return result.get("data", []) or []

    return result if isinstance(result, list) else []


def arg_disks_for_sub(sid):

    query = """
Resources
| where type =~ 'microsoft.compute/disks'
| extend VM = split(tostring(managedBy), '/')[-1]
| project
    id,
    name,
    resourceGroup,
    location,
    sku=tostring(sku.name),
    tier=tostring(sku.tier),
    diskSizeGB=tostring(properties.diskSizeGB),
    VM
"""

    return arg_query(sid, query)


def arg_ai_resources_for_sub(sid):

    return arg_query(
        sid,
        """
Resources
| where type has_any (
    'microsoft.cognitiveservices',
    'microsoft.machinelearningservices',
    'microsoft.search',
    'microsoft.botservice'
)
| project name, resourceGroup, location, sku, type, properties
"""
    )


def arg_logic_apps_for_sub(sid):

    return arg_query(
        sid,
        r"""
Resources
| where type =~ 'microsoft.logic/workflows'
    or (
        type =~ 'microsoft.web/sites'
        and tostring(kind) contains 'workflowapp'
    )
| project
    id,
    name,
    resourceGroup,
    location,
    type,
    kind,
    properties
"""
    )



def arg_dcrs_for_sub(sid):

    return arg_query(
        sid,
        """
Resources
| where type =~ 'microsoft.insights/datacollectionrules'
| project name, resourceGroup, location, type, properties
"""
    )


def collect_diagnostic_settings(resource_id, subscription_id):

    if not resource_id:
        return []

    result = run_azure_cli_json(
        subscription_id,
        [
            "monitor",
            "diagnostic-settings",
            "list",
            "--resource",
            resource_id,
        ],
        f"diagnostic settings for {resource_id}",
    )

    if result is None:
        return None

    if isinstance(result, dict):
        result = result.get("value", []) if isinstance(result.get("value"), list) else []

    if not isinstance(result, list):
        result = []

    resource_name = str(resource_id).rstrip("/").split("/")[-1]

    settings = []
    for item in result:
        if not isinstance(item, dict):
            continue

        destinations = []
        for key, label in (
            ("storageAccountId", "Storage Account"),
            ("workspaceId", "Log Analytics"),
            ("eventHubAuthorizationRuleId", "Event Hub"),
            ("serviceBusRuleId", "Service Bus"),
            ("marketplacePartnerId", "Marketplace"),
            ("partnerSolutionId", "Partner Solution"),
        ):
            if item.get(key):
                destinations.append(label)

        if item.get("logAnalyticsDestinationType"):
            destinations.append("Log Analytics")

        settings.append({
            "resourceId": resource_id,
            "resourceName": resource_name,
            "resourceType": item.get("targetResourceType") or item.get("resourceType") or "",
            "diagnosticsEnabled": bool(
                (item.get("logs") or [])
                or (item.get("metrics") or [])
                or item.get("storageAccountId")
                or item.get("workspaceId")
                or item.get("eventHubAuthorizationRuleId")
                or item.get("serviceBusRuleId")
                or item.get("marketplacePartnerId")
                or item.get("partnerSolutionId")
            ),
            "destinations": sorted(set(destinations)),
            "enabledLogCategories": sorted({
                str(log.get("category", ""))
                for log in item.get("logs", []) or []
                if isinstance(log, dict)
                and log.get("enabled")
                and log.get("category")
            }),
            "enabledLogCategoryGroups": sorted({
                str(log.get("categoryGroup", ""))
                for log in item.get("logs", []) or []
                if isinstance(log, dict)
                and log.get("enabled")
                and log.get("categoryGroup")
            }),
        })

    if settings:
        return settings

    return [{
        "resourceId": resource_id,
        "resourceName": resource_name,
        "resourceType": "",
        "diagnosticsEnabled": False,
        "destinations": [],
        "enabledLogCategories": [],
        "enabledLogCategoryGroups": [],
    }]


def sql_setting_state(value):
    if value is True:
        return "Enabled"
    if value is False:
        return "Disabled"
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in {"enabled", "disabled"}:
            return normalized.title()
    return "Not reported"


def collect_sql_server_security(sid, server, diagnostic_settings):
    server_name = str(server.get("name", ""))
    resource_group = str(server.get("resourceGroup", ""))
    if not server_name or not resource_group:
        print(
            "WARNING: SQL Server Entra and auditing settings were not queried "
            "because the server name or resource group was missing.",
            file=sys.stderr,
        )
        entra_admins = None
        entra_only = None
        audit_policy = None
    else:
        entra_admins = run_azure_cli_json(
            sid,
            [
                "sql",
                "server",
                "ad-admin",
                "list",
                "--resource-group",
                resource_group,
                "--server",
                server_name,
            ],
            f"Microsoft Entra administrator for SQL Server {server_name}",
        )
        entra_only = run_azure_cli_json(
            sid,
            [
                "sql",
                "server",
                "ad-only-auth",
                "get",
                "--resource-group",
                resource_group,
                "--name",
                server_name,
            ],
            f"Entra-only authentication for SQL Server {server_name}",
        )
        audit_policy = run_azure_cli_json(
            sid,
            [
                "sql",
                "server",
                "audit-policy",
                "show",
                "--resource-group",
                resource_group,
                "--name",
                server_name,
            ],
            f"auditing policy for SQL Server {server_name}",
        )

    if isinstance(entra_admins, list):
        entra_admin_state = (
            "Configured" if entra_admins else "Not configured"
        )
        entra_admin_count = len(entra_admins)
    else:
        entra_admin_state = "Not reported"
        entra_admin_count = "Not reported"

    entra_only_properties = (
        entra_only.get("properties", {})
        if isinstance(entra_only, dict)
        else {}
    )
    if isinstance(entra_only, dict):
        entra_only_value = entra_only.get(
            "azureADOnlyAuthentication",
            entra_only_properties.get(
                "azureADOnlyAuthentication",
                entra_only.get(
                    "azureAdOnlyAuthentication",
                    entra_only_properties.get("azureAdOnlyAuthentication"),
                ),
            ),
        )
    else:
        entra_only_value = None

    audit_properties = (
        audit_policy.get("properties", {})
        if isinstance(audit_policy, dict)
        else {}
    )
    policy_state = (
        audit_policy.get("state", audit_properties.get("state"))
        if isinstance(audit_policy, dict)
        else None
    )
    audit_destinations = set()
    if isinstance(audit_policy, dict):
        if (
            audit_policy.get("storageEndpoint")
            or audit_properties.get("storageEndpoint")
        ):
            audit_destinations.add("Storage")
        if (
            audit_policy.get("isAzureMonitorTargetEnabled")
            or audit_properties.get("isAzureMonitorTargetEnabled")
        ):
            audit_destinations.add("Azure Monitor")
        if (
            audit_policy.get("eventHubAuthorizationRuleId")
            or audit_properties.get("eventHubAuthorizationRuleId")
        ):
            audit_destinations.add("Event Hubs")

    resource_id = str(server.get("id", "")).lower()
    server_diagnostics = diagnostic_settings or []
    audit_categories = sorted({
        category
        for setting in server_diagnostics
        for category in setting.get("enabledLogCategories", [])
        if "audit" in category.lower()
    })
    audit_category_groups = sorted({
        category
        for setting in server_diagnostics
        for category in setting.get("enabledLogCategoryGroups", [])
        if "audit" in category.lower()
    })
    if audit_categories or audit_category_groups:
        for setting in server_diagnostics:
            audit_destinations.update(setting.get("destinations", []))

    if diagnostic_settings is None:
        audit_diagnostic_state = "Not reported"
    elif audit_categories or audit_category_groups:
        audit_diagnostic_state = "Configured"
    else:
        audit_diagnostic_state = "Not configured"

    return {
        "entraAdministrator": entra_admin_state,
        "entraAdministratorCount": entra_admin_count,
        "entraOnlyAuthentication": sql_setting_state(entra_only_value),
        "auditingPolicy": sql_setting_state(policy_state),
        "auditLogCategories": audit_categories,
        "auditLogCategoryGroups": audit_category_groups,
        "auditLogDestinations": sorted(audit_destinations),
        "auditDiagnosticSettings": audit_diagnostic_state,
    }


def arg_key_vaults_for_sub(sid):

    return arg_query(
        sid,
        """
Resources
| where type =~ 'microsoft.keyvault/vaults'
| project
    name,
    resourceGroup,
    location,
    tenantId=tostring(properties.tenantId),
    enableSoftDelete=tostring(properties.enableSoftDelete),
    enablePurgeProtection=tostring(properties.enablePurgeProtection),
    publicNetworkAccess=tostring(properties.publicNetworkAccess)
"""
    )


def normalize_disks(disks):

    normalized = []

    for disk in disks or []:
        properties = disk.get("properties") or {}
        sku = disk.get("sku") or {}
        sku_name = sku.get("name", "") if isinstance(sku, dict) else ""

        disk["disk_size_gb"] = (
            disk.get("diskSizeGB")
            or properties.get("diskSizeGB")
            or disk.get("diskSizeInGB")
        )
        disk["disk_sku"] = (
            disk.get("sku")
            if isinstance(disk.get("sku"), str)
            else sku_name
        )
        disk["performance_tier"] = (
            disk.get("tier")
            or properties.get("tier")
            or (sku.get("tier", "") if isinstance(sku, dict) else "")
            or sku_name
        )
        disk["disk_os_type"] = disk.get("osType") or properties.get("osType", "")
        disk["disk_state"] = disk.get("diskState") or properties.get("diskState", "")
        disk["attached_vm"] = (
            disk.get("managedBy")
            or properties.get("managedBy", "")
            or disk.get("VM", "")
        ).split("/")[-1]
        normalized.append(disk)

    return normalized

inventory = {
    "generated_utc": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).isoformat(),
    "management_group_id": MG_ID,
    "subscriptions": []
}

for idx, s in enumerate(subs, 1):
    sid = s["subscription_id"]
    print(f"[{idx}/{len(subs)}] Collecting {sid}", file=sys.stderr)

    sub = run(["az","account","show","--subscription",sid,"-o","json"], {})
    # Basic subscription metadata
    s.update({
        "display_name": sub.get("name", sid),
        "tenant_id": sub.get("tenantId", ""),
        "state": sub.get("state", "Unknown"),
        "cloud": sub.get("environmentName", "AzureCloud"),
    })

    rgs = az_for_sub(sid, ["group","list"], [])
    vnets = az_for_sub(sid, ["network","vnet","list"], [])
    nsgs = az_for_sub(sid, ["network","nsg","list"], [])
    rts = az_for_sub(
        sid,
        [
            "resource",
            "list",
            "--resource-type",
            "Microsoft.Network/routeTables"
        ],
        []
    )
    pips = az_for_sub(sid, ["network","public-ip","list"], [])
    peerings = []
    for v in vnets:
        vname = v.get("name")
        if vname:
            peerings.extend(az_for_sub(sid, ["network","vnet","peering","list","--vnet-name",vname,
                                             "--resource-group",v.get("resourceGroup","")], []))
    # The above command may fail where RG is absent in returned VNet JSON.
    # Retry peerings using the resource ID-derived RG if necessary.
    if not peerings:
        for v in vnets:
            vname = v.get("name")
            rg = v.get("resourceGroup")
            if vname and rg:
                peerings.extend(az_for_sub(sid, ["network","vnet","peering","list",
                                                 "--vnet-name",vname,"--resource-group",rg], []))

    vms = az_for_sub(sid, ["vm","list"], [])
    disks = arg_disks_for_sub(sid)
    if not disks:
        disks = az_for_sub(
            sid,
            ["disk", "list"],
            []
        )
    if not disks:
        disks = az_for_sub(
            sid,
            [
                "resource",
                "list",
                "--resource-type",
                "Microsoft.Compute/disks"
            ],
            []
        )
    disks = normalize_disks(disks)
    print(f"[{idx}/{len(subs)}] Managed disks collected: {len(disks)}", file=sys.stderr)
    storage = az_for_sub(sid, ["storage","account","list"], [])
    kvs = arg_key_vaults_for_sub(sid)
    if not kvs:
        kvs = az_for_sub(sid, ["keyvault", "list"], [])
    appgws = az_for_sub(sid, ["network","application-gateway","list"], [])
    firewalls = az_for_sub(sid, ["network","firewall","list"], [])
    firewall_policies = az_for_sub(sid, ["network","firewall","policy","list"], [])
    afd_profiles = az_for_sub(sid, ["afd","profile","list"], [])
    log_workspaces = az_for_sub(sid, ["monitor","log-analytics","workspace","list"], [])
    app_insights = az_for_sub(sid, ["monitor","app-insights","component","list"], [])
    action_groups = az_for_sub(sid, ["monitor","action-group","list"], [])
    recovery_vaults = az_for_sub(sid, ["backup","vault","list"], [])
    policy_assignments = az_for_sub(sid, ["policy","assignment","list"], [])
    policy_definitions = az_for_sub(sid, ["policy","definition","list"], [])
    role_assignments = az_for_sub(sid, ["role","assignment","list"], [])
    dcrs = arg_dcrs_for_sub(sid)
    if not dcrs:
        dcrs = az_for_sub(
            sid,
            [
                "resource",
                "list",
                "--resource-type",
                "Microsoft.Insights/dataCollectionRules"
            ],
            []
        )

    # =========================================================================
    # Additional Azure Services
    # =========================================================================

    app_services = az_for_sub(
        sid,
        ["webapp","list"],
        []
    )

    function_apps = az_for_sub(
        sid,
        ["functionapp","list"],
        []
    )

    app_service_plans = az_for_sub(
        sid,
        ["appservice","plan","list"],
        []
    )

    container_apps = az_for_sub(
        sid,
        ["containerapp","list"],
        []
    )

    container_envs = az_for_sub(
        sid,
        ["containerapp","env","list"],
        []
    )

    container_registries = az_for_sub(
        sid,
        ["acr","list"],
        []
    )

    sql_servers = az_for_sub(
        sid,
        ["sql","server","list"],
        []
    )

    postgres_servers = az_for_sub(
        sid,
        ["postgres","flexible-server","list"],
        []
    )

    mysql_servers = az_for_sub(
        sid,
        ["mysql","flexible-server","list"],
        []
    )

    cosmos_accounts = az_for_sub(
        sid,
        ["cosmosdb","list"],
        []
    )

    data_factories = az_for_sub(
        sid,
        ["datafactory","list"],
        []
    )

    service_bus = az_for_sub(
        sid,
        ["servicebus","namespace","list"],
        []
    )

    event_hubs = az_for_sub(
        sid,
        ["eventhubs","namespace","list"],
        []
    )

    private_endpoints = az_for_sub(
        sid,
        ["network","private-endpoint","list"],
        []
    )

    private_dns_zones = az_for_sub(
        sid,
        ["network","private-dns","zone","list"],
        []
    )

    load_balancers = az_for_sub(
        sid,
        ["network","lb","list"],
        []
    )

    bastions = az_for_sub(
        sid,
        ["network","bastion","list"],
        []
    )

    network_interfaces = az_for_sub(
        sid,
        ["network","nic","list"],
        []
    )

    network_watchers = az_for_sub(
        sid,
        ["network","watcher","list"],
        []
    )

    activity_log_alerts = az_for_sub(
        sid,
        ["monitor","activity-log","alert","list"],
        []
    )
   

    metric_alerts = az_for_sub(
        sid,
        ["monitor","metrics","alert","list"],
        []
    )

    # VM free-disk-space rules are commonly Log Alerts (scheduled query rules),
    # rather than Metric Alerts. Collect them alongside the other alert types.
    scheduled_query_alerts = az_for_sub(
        sid,
        ["monitor", "scheduled-query", "list"],
        []
    )
    if not scheduled_query_alerts:
        scheduled_query_alerts = az_for_sub(
            sid,
            ["resource", "list", "--resource-type", "Microsoft.Insights/scheduledQueryRules"],
            []
        )

    grafana = az_for_sub(
        sid,
        ["grafana","list"],
        []
    )

    workbooks = az_for_sub(
        sid,
        ["monitor","workbook","list"],
        []
    )
        #
    # Consumption Logic Apps
    #
    logic_apps = arg_logic_apps_for_sub(sid)

#
# Normalize state for both Consumption and Standard
#
    for app in logic_apps:

        props = app.get("properties") or {}

        app["state"] = (
            props.get("state")
            or props.get("workflowState")
            or app.get("state")
            or app.get("provisioningState")
            or ""
        )


    

    #
    # Standard Logic Apps
    #
    all_resources = az_for_sub(
        sid,
        ["resource", "list"],
        []
    )
    sql_databases = []
    for resource in all_resources:
        if str(resource.get("type", "")).lower() != (
            "microsoft.sql/servers/databases"
        ):
            continue
        database_name = str(resource.get("name", "")).rsplit("/", 1)[-1]
        if database_name.lower() == "master":
            continue
        resource_id_parts = str(resource.get("id", "")).rstrip("/").split("/")
        resource["serverName"] = next(
            (
                resource_id_parts[index + 1]
                for index, part in enumerate(resource_id_parts[:-1])
                if part.lower() == "servers"
            ),
            "",
        )
        sql_databases.append(resource)
    sql_managed_instances = [
        resource
        for resource in all_resources
        if str(resource.get("type", "")).lower()
        == "microsoft.sql/managedinstances"
    ]
    resource_types = {
        "aks_clusters": "microsoft.containerservice/managedclusters",
        "aro_clusters": "microsoft.redhatopenshift/openshiftclusters",
        "vm_scale_sets": "microsoft.compute/virtualmachinescalesets",
    }
    platform_resources = {
        inventory_key: [
            resource
            for resource in all_resources
            if str(resource.get("type", "")).lower() == resource_type
        ]
        for inventory_key, resource_type in resource_types.items()
    }

    logic_app_standard = [
        r
        for r in all_resources
        if (
            str(r.get("type", "")).lower()
            == "microsoft.web/sites"
            and "workflowapp" in str(r.get("kind", "")).lower()
        )
    ]

    #
    # Normalize Standard Logic Apps
    #
    for app in logic_app_standard:

        app["state"] = app.get(
            "state",
            "Running"
        )

    logic_apps.extend(
        logic_app_standard
    )

    #
    # Remove duplicates
    #
    seen = set()

    logic_apps = [
        x for x in logic_apps
        if not (
            x.get("id") in seen
            or seen.add(x.get("id"))
        )
    ]
    eventgrid_topics = az_for_sub(
        sid,
        ["eventgrid","topic","list"],
        []
    )

    apim_services = az_for_sub(
        sid,
        ["apim", "list"],
        []
    )
    if not apim_services:
        apim_services = arg_query(
            sid,
            """
Resources
| where type =~ 'microsoft.apimanagement/service'
| project id, name, resourceGroup, location, type, sku, properties, tags
"""
        )
    for apim in apim_services:
        apim["type"] = apim.get("type") or "Microsoft.ApiManagement/service"
        if not apim.get("resourceGroup"):
            resource_id_parts = str(apim.get("id") or "").split("/")
            for index, part in enumerate(resource_id_parts[:-1]):
                if part.lower() == "resourcegroups":
                    apim["resourceGroup"] = resource_id_parts[index + 1]
                    break
        properties = apim.get("properties") or {}
        for key in (
            "publicNetworkAccess",
            "virtualNetworkType",
            "gatewayUrl",
            "developerPortalUrl",
            "provisioningState",
        ):
            if apim.get(key) in (None, "") and properties.get(key) not in (None, ""):
                apim[key] = properties[key]


    # =========================================================================
    # AI / Foundry / Cognitive Services
    # =========================================================================

    ai_resources = arg_ai_resources_for_sub(sid)
    if not ai_resources:
        all_resources = az_for_sub(
            sid,
            ["resource", "list"],
            []
        )

        ai_resources = [
            r for r in all_resources
            if any(
                provider in r.get("type", "").lower()
                for provider in (
                    "microsoft.cognitiveservices",
                    "microsoft.machinelearningservices",
                    "microsoft.search",
                    "microsoft.botservice"
                )
            )
        ]
    

    # Enrich VMs with OS/size/zone information where available.
    vm_rows = []
    nic_by_id = {
        nic.get("id", "").lower(): nic
        for nic in network_interfaces
        if nic.get("id")
    }
    for vm in vms:
        image = ((vm.get("storageProfile") or {}).get("imageReference") or {})
        plan = vm.get("plan") or {}
        tags = vm.get("tags") or {}
        vm_nics = (vm.get("networkProfile") or {}).get("networkInterfaces") or []
        public_access = "Unknown"
        nic_rows = []
        if vm_nics:
            public_access = "Disabled"
            for vm_nic in vm_nics:
                nic_id = vm_nic.get("id") or ""
                nic = nic_by_id.get(nic_id.lower(), {})
                ip_configs = nic.get("ipConfigurations", []) or []
                private_ips = [
                    config.get("privateIPAddress", "")
                    for config in ip_configs
                    if config.get("privateIPAddress")
                ]
                subnet_ids = [
                    (config.get("subnet") or {}).get("id", "")
                    for config in ip_configs
                    if (config.get("subnet") or {}).get("id")
                ]
                public_ip_ids = []
                for ip_config in ip_configs:
                    public_ip = ip_config.get("publicIPAddress") or {}
                    if public_ip.get("id") or public_ip.get("ipAddress"):
                        public_access = "Enabled"
                        if public_ip.get("id"):
                            public_ip_ids.append(public_ip["id"])
                nic_rows.append({
                    "name": nic.get("name", nic_id.rsplit("/", 1)[-1]),
                    "id": nic_id,
                    "private_ips": private_ips,
                    "subnet_ids": sorted(set(subnet_ids)),
                    "nsg_id": (nic.get("networkSecurityGroup") or {}).get("id", ""),
                    "public_ip_ids": sorted(set(public_ip_ids)),
                })
        vm_rows.append({
            "name": vm.get("name",""),
            "resource_group": vm.get("resourceGroup",""),
            "location": vm.get("location",""),
            "size": (vm.get("hardwareProfile") or {}).get("vmSize",""),
            "os_type": ((vm.get("storageProfile") or {}).get("osDisk") or {}).get("osType",""),
            "image": image if isinstance(image, dict) else {},
            "marketplace_plan": plan if isinstance(plan, dict) else {},
            "tags": tags if isinstance(tags, dict) else {},
            "network_interfaces": nic_rows,
            "zone": (vm.get("zones") or [""])[0] if vm.get("zones") else "",
            "public_access": public_access,
            "id": vm.get("id",""),
            "type": vm.get("type", "Microsoft.Compute/virtualMachines")
        })

    # Flatten subnet information.
    subnet_rows = []
    for v in vnets:
        for sn in v.get("subnets", []) or []:
            subnet_rows.append({
                "id": sn.get("id",""),
                "vnet": v.get("name",""),
                "resource_group": v.get("resourceGroup",""),
                "location": v.get("location",""),
                "name": sn.get("name",""),
                "address_prefixes": sn.get("addressPrefixes") or ([sn.get("addressPrefix")] if sn.get("addressPrefix") else []),
                "nsg_id": (sn.get("networkSecurityGroup") or {}).get("id",""),
                "route_table_id": (sn.get("routeTable") or {}).get("id",""),
                "private_endpoint_network_policies": sn.get("privateEndpointNetworkPolicies"),
                "private_link_service_network_policies": sn.get("privateLinkServiceNetworkPolicies"),
                "delegations": [d.get("serviceName","") for d in (sn.get("delegations") or [])]
            })

    diagnostic_settings = []
    diagnostic_settings_by_resource_id = {}
    for resource_set in (
        vm_rows,
        storage,
        vnets,
        nsgs,
        firewalls,
        appgws,
        load_balancers,
        afd_profiles,
        apim_services,
        sql_servers,
    ):
        for resource in resource_set or []:
            resource_id = resource.get("id") or resource.get("resourceId")
            if resource_id:
                collected_settings = collect_diagnostic_settings(resource_id, sid)
                if collected_settings is None:
                    diagnostic_settings_by_resource_id[
                        str(resource_id).lower()
                    ] = None
                else:
                    diagnostic_settings.extend(collected_settings)
                    diagnostic_settings_by_resource_id[
                        str(resource_id).lower()
                    ] = collected_settings

    for sql_server in sql_servers or []:
        sql_server["security_review"] = collect_sql_server_security(
            sid,
            sql_server,
            diagnostic_settings_by_resource_id.get(
                str(sql_server.get("id", "")).lower()
            ),
        )

    s["inventory"] = {
        "resource_groups": rgs,
        "vnets": vnets,
        "subnets": subnet_rows,
        "nsgs": nsgs,
        "route_tables": rts,
        "peerings": peerings,
        "public_ips": pips,
        "vms": vm_rows,
        "aks_clusters": platform_resources["aks_clusters"],
        "aro_clusters": platform_resources["aro_clusters"],
        "vm_scale_sets": platform_resources["vm_scale_sets"],
        "disks": disks,
        "storage_accounts": storage,
        "key_vaults": kvs,
        "application_gateways": appgws,
        "firewalls": firewalls,
        "firewall_policies": firewall_policies,
        "frontdoor_profiles": afd_profiles,
        "log_analytics": log_workspaces,
        "application_insights": app_insights,
        "action_groups": action_groups,
        "recovery_vaults": recovery_vaults,
        "policy_assignments": policy_assignments,
        "policy_definitions": policy_definitions,
        "role_assignments": role_assignments,
        "app_services": app_services,
        "function_apps": function_apps,
        "app_service_plans": app_service_plans,
        "container_apps": container_apps,
        "container_app_environments": container_envs,
        "container_registries": container_registries,
        "sql_servers": sql_servers,
        "sql_databases": sql_databases,
        "sql_managed_instances": sql_managed_instances,
        "postgres_servers": postgres_servers,
        "mysql_servers": mysql_servers,
        "cosmos_accounts": cosmos_accounts,
        "data_factories": data_factories,
        "service_bus": service_bus,
        "event_hubs": event_hubs,
        "private_endpoints": private_endpoints,
        "private_dns_zones": private_dns_zones,
        "load_balancers": load_balancers,
        "bastions": bastions,
        "network_interfaces": network_interfaces,
        "network_watchers": network_watchers,
        "activity_log_alerts": activity_log_alerts,
        "metric_alerts": metric_alerts,
        "scheduled_query_alerts": scheduled_query_alerts,
        "diagnostic_settings": diagnostic_settings,
        "grafana": grafana,
        "workbooks": workbooks,
        "ai_resources": ai_resources,
        "logic_apps": logic_apps,
        "eventgrid_topics": eventgrid_topics,
        "apim_services": apim_services,
        "dcrs": dcrs,
                
    }
    inventory["subscriptions"].append(s)

inventory_file.write_text(
    json.dumps(
        inventory,
        indent=2
    )
)

#
# Save full inventory copy
#

Path("inventory.json").write_text(
    json.dumps(
        inventory,
        indent=2
    )
)


Path("resources.json").write_text(
    json.dumps(
        inventory,
        indent=2
    )
)


print(f"Discovered {len(subs)} subscription(s).", file=sys.stderr)
PY
fi

echo "[DOCX] Generating HLD..."

echo "Checking python-docx..."

python3 -c "import docx" >/dev/null 2>&1 || {

    echo "Installing python-docx..."

    python3 -m pip install --user python-docx

}

export TEMPLATE OUTPUT INVENTORY
export MG_STRUCTURE_FILE="${MG_STRUCTURE_FILE:-./management_group_structure.txt}"
export MG_STRUCTURE_IMAGE="${MG_STRUCTURE_IMAGE:-./management_group_structure.png}"
python3 - <<'PY'
import json, os, re, copy, sys, time
from pathlib import Path
from datetime import datetime, timezone
from docx import Document
from docx.shared import Inches, Pt
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.enum.table import WD_TABLE_ALIGNMENT, WD_CELL_VERTICAL_ALIGNMENT
from docx.oxml import OxmlElement
from docx.oxml.ns import qn

template = Path(os.environ["TEMPLATE"])
output = Path(os.environ["OUTPUT"])
data = json.loads(Path(os.environ["INVENTORY"]).read_text())
SENSITIVE_KEY_PATTERN = re.compile(
    r"(?:password|secret|token|credential|private.?key|license.?key|"
    r"snmp.?community|registration.?key|api.?key|access.?key|"
    r"connection.?string|shared.?access.?signature)",
    re.IGNORECASE,
)


def safe_tag_text(tags):
    return "; ".join(
        f"{key}={safe_tag_value(key, value)}"
        for key, value in sorted((tags or {}).items())
    )


def safe_tag_value(key, value):
    return "[REDACTED]" if SENSITIVE_KEY_PATTERN.search(str(key)) else value


def classify_vm_vendor(name, image, plan, tags):
    image = image if isinstance(image, dict) else {}
    plan = plan if isinstance(plan, dict) else {}
    tags = tags if isinstance(tags, dict) else {}
    values = {
        "image_publisher": str(image.get("publisher") or ""),
        "image_offer": str(image.get("offer") or ""),
        "image_sku": str(image.get("sku") or ""),
        "marketplace_plan": " ".join(
            str(plan.get(key) or "") for key in ("publisher", "product", "name")
        ),
        "vm_name": str(name or ""),
        "tags": " ".join(f"{key} {value}" for key, value in tags.items()),
    }
    evidence = {
        "publisher": values["image_publisher"],
        "offer": values["image_offer"],
        "sku": values["image_sku"],
        "plan": plan,
        "name": values["vm_name"],
        "tags": tags,
    }
    known = {
        "F5": ("BIG-IP", "F5 BIG-IP", ("f5", "big-?ip")),
        "Palo Alto": ("VM-Series", "Palo Alto VM-Series", (
            "palo[-_ ]?alto", "paloaltonetworks", "vm[-_ ]?series",
        )),
        "Fortinet": ("FortiGate", "Fortinet FortiGate", (
            "fortinet", "forti[-_ ]?gate",
        )),
        "Cisco": ("Cisco NVA", "Cisco NVA", (
            "cisco", "csr1000v", "catalyst[-_ ]?8000v",
        )),
        "Check Point": ("CloudGuard", "Check Point CloudGuard", (
            "check[-_ ]?point", "checkpoint", "cloudguard",
        )),
    }
    metadata_sources = (
        "image_publisher", "image_offer", "image_sku", "marketplace_plan",
    )
    scores = {}
    matches = {}
    for vendor, (_, _, aliases) in known.items():
        metadata = []
        weak = []
        for source, value in values.items():
            if any(
                re.search(r"(?<![a-z0-9])" + alias + r"(?![a-z0-9])", value, re.I)
                for alias in aliases
            ):
                (metadata if source in metadata_sources else weak).append(source)
        if metadata:
            scores[vendor] = (2, len(metadata))
        elif weak:
            scores[vendor] = (1, len(weak))
        matches[vendor] = metadata + weak

    if scores:
        best = max(scores.values())
        winners = [vendor for vendor, score in scores.items() if score == best]
        if len(winners) == 1:
            vendor = winners[0]
            product, detected_product, _ = known[vendor]
            return {
                "vendor": vendor,
                "product": product,
                "detected_product": detected_product,
                "confidence": "high" if best[0] == 2 else "medium",
                "detection_source": matches[vendor],
                "evidence": evidence,
            }
        return {
            "vendor": "Unknown",
            "product": "",
            "detected_product": "Conflicting vendor signals",
            "confidence": "low",
            "detection_source": sorted({
                source for vendor in winners for source in matches[vendor]
            }),
            "evidence": evidence,
        }

    metadata_text = " ".join(values[key].lower() for key in metadata_sources)
    if re.search(r"\b(?:nva|network[-_ ]virtual[-_ ]appliance)\b", metadata_text):
        product = values["image_offer"] or values["image_sku"] or "Network Virtual Appliance"
        return {
            "vendor": "Other NVA",
            "product": product,
            "detected_product": product,
            "confidence": "medium",
            "detection_source": [key for key in metadata_sources if values[key]],
            "evidence": evidence,
        }
    return {
        "vendor": "Unknown",
        "product": "",
        "detected_product": "Unknown",
        "confidence": "low",
        "detection_source": [],
        "evidence": evidence,
    }


for subscription in data.get("subscriptions", []) or []:
    for vm in (subscription.get("inventory") or {}).get("vms", []) or []:
        vm["vendor_detection"] = classify_vm_vendor(
            vm.get("name", ""),
            vm.get("image") or {},
            vm.get("marketplace_plan") or {},
            vm.get("tags") or {},
        )
if os.environ.get("REUSE_INVENTORY", "0") != "1":
    Path(os.environ["INVENTORY"]).write_text(json.dumps(data, indent=2))


def invoke_network_design_agent(subscriptions):
    def ai_log(message):
        print(f"[AI] {message}", file=sys.stdout, flush=True)

    def safe_error_detail(error):
        detail = re.sub(r"(?i)\bBearer\s+\S+", "Bearer [redacted]", str(error))
        detail = re.sub(
            r"(?i)((?:api[_-]?key|access[_-]?token|password|secret)\s*[=:]\s*)[^\s,;]+",
            r"\1[redacted]",
            detail,
        )
        detail = re.sub(
            r"(?i)/subscriptions/[^,\s'\";]+",
            "[Azure resource ID redacted]",
            detail,
        )
        return detail[:600]

    evidence = {"vnets": [], "subnets": [], "apim_services": []}
    resource_evidence = []
    context_inventory_types = {
        "vnets",
        "subnets",
        "nsgs",
        "route_tables",
        "peerings",
        "public_ips",
        "network_interfaces",
        "private_dns_zones",
        "network_watchers",
        "bastions",
        "app_service_plans",
    }
    architecture_inventory_types = {
        "vms",
        "application_gateways",
        "firewalls",
        "firewall_policies",
        "frontdoor_profiles",
        "load_balancers",
        "private_endpoints",
        "aks_clusters",
        "aro_clusters",
        "vm_scale_sets",
        "apim_services",
        "sql_servers",
        "sql_databases",
        "sql_managed_instances",
        "postgres_servers",
        "mysql_servers",
        "cosmos_accounts",
        "ai_resources",
        "app_services",
        "function_apps",
        "container_apps",
        "container_registries",
        "service_bus",
        "event_hubs",
        "storage_accounts",
        "key_vaults",
    }
    well_architected_inventory_types = {
        "vms",
        "aks_clusters",
        "aro_clusters",
        "vm_scale_sets",
        "sql_servers",
        "sql_databases",
        "sql_managed_instances",
        "postgres_servers",
        "mysql_servers",
        "cosmos_accounts",
        "app_services",
        "function_apps",
        "apim_services",
    }
    context_by_id = {}
    platform_detail_fields = {
        "aks_clusters": {
            "provisioningState": None,
            "kubernetesVersion": None,
            "currentKubernetesVersion": None,
            "powerState": None,
            "enableRBAC": None,
            "networkProfile": None,
            "agentPoolProfiles": None,
            "apiServerAccessProfile": None,
            "oidcIssuerProfile": None,
            "securityProfile": None,
            "addonProfiles": None,
            "autoUpgradeProfile": None,
            "sku": None,
            "azureMonitorProfile": None,
            "workloadAutoScalerProfile": None,
            "serviceMeshProfile": None,
        },
        "aro_clusters": {
            "provisioningState": None,
            "clusterProfile": {
                "version": None,
                "domain": None,
                "resourceGroupId": None,
                "fipsValidatedModules": None,
            },
            "networkProfile": None,
            "masterProfile": None,
            "workerProfiles": None,
            "apiserverProfile": None,
            "ingressProfiles": None,
        },
        "vm_scale_sets": {
            "provisioningState": None,
            "orchestrationMode": None,
            "upgradePolicy": None,
            "overprovision": None,
            "singlePlacementGroup": None,
            "platformFaultDomainCount": None,
            "virtualMachineProfile": {
                "storageProfile": None,
                "networkProfile": None,
                "priority": None,
                "evictionPolicy": None,
                "billingProfile": None,
                "securityProfile": None,
            },
        },
    }
    resource_detail_fields = {
        "network_interfaces": {
            "enableIPForwarding": None,
            "enableAcceleratedNetworking": None,
            "ipConfigurations": None,
            "networkSecurityGroup": None,
        },
        "nsgs": {
            "securityRules": None,
            "defaultSecurityRules": None,
        },
        "route_tables": {
            "disableBgpRoutePropagation": None,
            "routes": None,
        },
        "load_balancers": {
            "frontendIPConfigurations": None,
            "backendAddressPools": None,
            "probes": None,
            "loadBalancingRules": None,
        },
        "application_gateways": {
            "sku": None,
            "gatewayIPConfigurations": None,
            "frontendIPConfigurations": None,
            "backendAddressPools": None,
            "backendHttpSettingsCollection": None,
            "requestRoutingRules": None,
            "probes": None,
            "enableHttp2": None,
            "firewallPolicy": None,
            "webApplicationFirewallConfiguration": None,
        },
        "firewalls": {
            "sku": None,
            "threatIntelMode": None,
            "ipConfigurations": None,
            "firewallPolicy": None,
            "virtualHub": None,
        },
        "firewall_policies": {
            "threatIntelMode": None,
            "intrusionDetection": None,
            "ruleCollectionGroups": None,
        },
        "private_endpoints": {
            "subnet": None,
            "privateLinkServiceConnections": None,
            "manualPrivateLinkServiceConnections": None,
            "customDnsConfigs": None,
        },
        "vnets": {
            "addressSpace": None,
            "subnets": None,
            "virtualNetworkPeerings": None,
        },
        "subnets": {
            "addressPrefix": None,
            "addressPrefixes": None,
            "networkSecurityGroup": None,
            "routeTable": None,
            "delegations": None,
            "privateEndpointNetworkPolicies": None,
            "privateLinkServiceNetworkPolicies": None,
        },
    }
    summary_fields = (
        "sku",
        "kind",
        "state",
        "provisioningState",
        "publicNetworkAccess",
        "virtualNetworkType",
        "addressSpace",
        "address_prefixes",
        "os_type",
        "size",
        "image",
        "marketplace_plan",
        "security_review",
        "vendor_detection",
        "network_interfaces",
        "public_access",
        "gatewayUrl",
        "developerPortalUrl",
        "capacity",
        "tier",
        "accessTier",
        "minimumTlsVersion",
        "httpsOnly",
        "version",
        "backup",
        "highAvailability",
        "storage",
        "network",
        "zoneRedundant",
        "maxSizeBytes",
        "readScale",
        "autoPauseDelay",
        "serverName",
        "serverFarmId",
        "zone",
        "zones",
        "locations",
        "consistencyPolicy",
        "backupPolicy",
        "enableAutomaticFailover",
        "enableMultipleWriteLocations",
        "isVirtualNetworkFilterEnabled",
        "virtualNetworkRules",
        "disableLocalAuth",
        "workerTier",
        "status",
    )
    safe_property_fields = (
        "provisioningState",
        "publicNetworkAccess",
        "virtualNetworkType",
        "state",
        "gatewayUrl",
        "developerPortalUrl",
        "sku",
        "addressSpace",
        "accessTier",
        "minimumTlsVersion",
        "httpsOnly",
        "zoneRedundant",
        "capacity",
        "tier",
        "enableSoftDelete",
        "enablePurgeProtection",
        "identity",
        "version",
        "backup",
        "highAvailability",
        "storage",
        "network",
        "zoneRedundant",
        "maxSizeBytes",
        "readScale",
        "autoPauseDelay",
        "serverName",
        "serverFarmId",
        "zone",
        "zones",
        "locations",
        "consistencyPolicy",
        "backupPolicy",
        "enableAutomaticFailover",
        "enableMultipleWriteLocations",
        "isVirtualNetworkFilterEnabled",
        "virtualNetworkRules",
        "disableLocalAuth",
        "workerTier",
        "status",
    )

    sensitive_key_pattern = re.compile(
        r"(?:password|secret|token|credential|private.?key|license.?key|"
        r"snmp.?community|registration.?key|api.?key|access.?key|"
        r"connection.?string|shared.?access.?signature)",
        re.IGNORECASE,
    )

    def redact_sensitive_data(value):
        if isinstance(value, dict):
            return {
                str(key): (
                    "[REDACTED]"
                    if sensitive_key_pattern.search(str(key))
                    else redact_sensitive_data(item)
                )
                for key, item in value.items()
            }
        if isinstance(value, list):
            return [redact_sensitive_data(item) for item in value]
        return value

    def compact_value(value, depth=0, max_depth=2):
        if isinstance(value, str):
            return value[:200]
        if isinstance(value, (bool, int, float)) or value is None:
            return value
        if depth >= max_depth:
            return str(value)[:200]
        if isinstance(value, dict):
            return {
                str(key): compact_value(item, depth + 1, max_depth)
                for key, item in list(value.items())[:10]
            }
        if isinstance(value, list):
            return [
                compact_value(item, depth + 1, max_depth)
                for item in value[:8]
            ]
        return str(value)[:200]

    def project_platform_properties(value, fields):
        if isinstance(value, list):
            return [
                project_platform_properties(item, fields)
                for item in value[:8]
                if isinstance(item, (dict, list))
            ]
        if not isinstance(value, dict):
            return compact_value(value, max_depth=4)
        projected = {}
        for field, nested_fields in fields.items():
            if value.get(field) in (None, "", [], {}):
                continue
            item = value[field]
            projected[field] = (
                project_platform_properties(item, nested_fields)
                if isinstance(nested_fields, dict)
                else compact_value(item, max_depth=4)
            )
        return projected

    for subscription in subscriptions:
        inventory = subscription.get("inventory") or {}
        subscription_name = subscription.get(
            "display_name", subscription.get("subscription_id", "")
        )
        subscription_id = subscription.get("subscription_id", subscription_name)
        for resource_type, resources in inventory.items():
            if (
                resource_type not in architecture_inventory_types
                and resource_type not in context_inventory_types
            ) or not isinstance(resources, list):
                continue
            for index, resource in enumerate(resources):
                if not isinstance(resource, dict):
                    continue
                evidence_id = f"{subscription_id}:{resource_type}:{index}"
                azure_resource_id = resource.get("id", "")
                facts = {
                    "evidence_id": evidence_id,
                    "resource_id": azure_resource_id,
                    "resource_type": resource_type.replace("_", " ").title(),
                    "subscription": subscription_name,
                    "name": resource.get("name", ""),
                    "resource_group": resource.get(
                        "resourceGroup", resource.get("resource_group", "")
                    ),
                    "location": resource.get("location", ""),
                    "azure_type": resource.get("type", ""),
                }
                for field in summary_fields:
                    if resource.get(field) not in (None, "", [], {}):
                        facts[field] = compact_value(
                            resource[field],
                            max_depth=4 if field in (
                                "network_interfaces",
                                "vendor_detection",
                                "marketplace_plan",
                                "security_review",
                            ) else 2,
                        )
                properties = resource.get("properties")
                if isinstance(properties, dict):
                    detailed_fields = (
                        platform_detail_fields.get(resource_type)
                        or resource_detail_fields.get(resource_type)
                    )
                    safe_properties = (
                        project_platform_properties(properties, detailed_fields)
                        if detailed_fields
                        else {
                            field: properties[field]
                            for field in safe_property_fields
                            if properties.get(field) not in (None, "", [], {})
                        }
                    )
                    if safe_properties:
                        facts["properties"] = compact_value(
                            safe_properties,
                            max_depth=4 if detailed_fields else 2,
                        )
                if resource_type in platform_detail_fields:
                    facts["platform_detail_type"] = {
                        "aks_clusters": "AKS",
                        "aro_clusters": "ARO",
                        "vm_scale_sets": "Virtual Machine Scale Set",
                    }[resource_type]
                    identity = resource.get("identity")
                    if isinstance(identity, dict) and identity.get("type"):
                        facts["identity_type"] = identity["type"]
                facts = redact_sensitive_data(facts)
                facts["inventory_key"] = resource_type
                if (
                    resource_type in context_inventory_types
                    and isinstance(azure_resource_id, str)
                    and azure_resource_id
                ):
                    context_by_id[azure_resource_id.lower()] = facts
                else:
                    resource_evidence.append(facts)

        for vnet in inventory.get("vnets", []) or []:
            evidence["vnets"].append({
                "subscription": subscription_name,
                "resource_id": vnet.get("id", ""),
                "name": vnet.get("name", ""),
                "resource_group": vnet.get("resourceGroup", ""),
                "location": vnet.get("location", ""),
                "address_prefixes": (vnet.get("addressSpace") or {}).get(
                    "addressPrefixes", []
                ),
                "subnet_names": [
                    subnet.get("name", "")
                    for subnet in vnet.get("subnets", []) or []
                ],
                "subnet_ids": [
                    subnet.get("id", "")
                    for subnet in vnet.get("subnets", []) or []
                    if subnet.get("id")
                ],
                "tags": vnet.get("tags") or {},
            })
        for subnet in inventory.get("subnets", []) or []:
            evidence["subnets"].append({
                "subscription": subscription_name,
                "resource_id": subnet.get("id", ""),
                "vnet": subnet.get("vnet", ""),
                "name": subnet.get("name", ""),
                "resource_group": subnet.get("resource_group", ""),
                "location": subnet.get("location", ""),
                "address_prefixes": subnet.get("address_prefixes") or [],
                "nsg": resource_name_from_id(subnet.get("nsg_id", "")),
                "nsg_id": subnet.get("nsg_id", ""),
                "route_table": resource_name_from_id(subnet.get("route_table_id", "")),
                "route_table_id": subnet.get("route_table_id", ""),
                "delegations": subnet.get("delegations") or [],
                "private_endpoint_network_policies": subnet.get(
                    "private_endpoint_network_policies"
                ),
                "private_link_service_network_policies": subnet.get(
                    "private_link_service_network_policies"
                ),
            })
        for apim in inventory.get("apim_services", []) or []:
            properties = apim.get("properties") or {}
            evidence["apim_services"].append({
                "subscription": subscription_name,
                "name": apim.get("name", ""),
                "resource_group": apim.get("resourceGroup", ""),
                "location": apim.get("location", ""),
                "sku": apim.get("sku") or {},
                "capacity": (apim.get("sku") or {}).get("capacity"),
                "provisioning_state": (
                    apim.get("provisioningState")
                    or properties.get("provisioningState")
                ),
                "public_network_access": (
                    apim.get("publicNetworkAccess")
                    or properties.get("publicNetworkAccess")
                ),
                "virtual_network_type": (
                    apim.get("virtualNetworkType")
                    or properties.get("virtualNetworkType")
                ),
                "gateway_url": apim.get("gatewayUrl") or properties.get("gatewayUrl"),
                "developer_portal_url": (
                    apim.get("developerPortalUrl")
                    or properties.get("developerPortalUrl")
                ),
                "tags": apim.get("tags") or {},
            })

    evidence = redact_sensitive_data(evidence)
    resource_evidence = [
        resource
        for resource in resource_evidence
        if isinstance(resource.get("resource_id"), str)
        and re.match(
            r"^/subscriptions/[^/]+/(?:resourceGroups/[^/]+/)?providers/[^/]+/.+",
            resource["resource_id"],
            re.IGNORECASE,
        )
    ]
    known_resource_ids = {}
    for subscription in subscriptions:
        for resources in (subscription.get("inventory") or {}).values():
            if not isinstance(resources, list):
                continue
            for resource in resources:
                if isinstance(resource, dict) and isinstance(resource.get("id"), str):
                    resource_id = resource["id"].strip()
                    if resource_id:
                        known_resource_ids[resource_id.lower()] = resource_id
    def find_known_resource_ids(value):
        found = set()
        if isinstance(value, dict):
            for item in value.values():
                found.update(find_known_resource_ids(item))
        elif isinstance(value, list):
            for item in value:
                found.update(find_known_resource_ids(item))
        elif isinstance(value, str):
            normalized = value.strip().lower()
            if normalized in known_resource_ids:
                found.add(normalized)
            else:
                parent_id = normalized.rstrip("/")
                while "/" in parent_id:
                    parent_id = parent_id.rsplit("/", 1)[0]
                    if parent_id in known_resource_ids:
                        found.add(parent_id)
                        break
        return found

    for resource in resource_evidence:
        related_subnets = [
            subnet
            for subnet in evidence["subnets"]
            if str(subnet.get("resource_id") or "").lower()
            in find_known_resource_ids(resource)
        ]
        related_context_ids = set()
        frontier = [resource, related_subnets]
        for _ in range(2):
            linked_ids = set()
            for item in frontier:
                linked_ids.update(find_known_resource_ids(item))
            linked_ids.difference_update(
                {resource.get("resource_id", "").lower()}
            )
            linked_context_ids = linked_ids.intersection(context_by_id)
            new_context_ids = linked_context_ids - related_context_ids
            if not new_context_ids:
                break
            related_context_ids.update(new_context_ids)
            frontier = [
                context_by_id[resource_id]
                for resource_id in new_context_ids
            ]
        resource["related_subnets"] = related_subnets
        resource["related_resources"] = [
            context_by_id[resource_id]
            for resource_id in sorted(related_context_ids)
        ]
    if not any(evidence.values()) and not resource_evidence:
        ai_log(
            "SKIPPED: no VNet, subnet, APIM, or selected architecture-resource "
            "evidence was available for this inventory."
        )
        return {}

    try:
        from azure.ai.projects import AIProjectClient
        from azure.identity import DefaultAzureCredential
        from openai import RateLimitError
    except ImportError as error:
        raise RuntimeError(
            "Foundry agent enrichment requires azure-ai-projects, azure-identity, "
            "and openai. Install them with: python3 -m pip install "
            '"azure-ai-projects>=2.1.0" azure-identity openai'
        ) from error

    project_endpoint = os.environ.get(
        "FOUNDRY_PROJECT_ENDPOINT",
        "https://foundrylld01.services.ai.azure.com/api/projects/proj-lld",
    )
    agent_name = os.environ.get("FOUNDRY_AGENT_NAME", "LLD-agent")
    agent_version = os.environ.get("FOUNDRY_AGENT_VERSION", "1")
    if not project_endpoint.strip():
        raise ValueError("FOUNDRY_PROJECT_ENDPOINT must not be empty.")
    if not agent_name.strip():
        raise ValueError("FOUNDRY_AGENT_NAME must not be empty.")
    if not agent_version.strip():
        raise ValueError("FOUNDRY_AGENT_VERSION must not be empty.")
    try:
        max_input_chars = int(os.environ.get("FOUNDRY_MAX_INPUT_CHARS", "9000"))
    except ValueError as error:
        raise ValueError("FOUNDRY_MAX_INPUT_CHARS must be a positive integer.") from error
    if max_input_chars < 1000:
        raise ValueError("FOUNDRY_MAX_INPUT_CHARS must be at least 1000.")

    tracer = None
    tracer_provider = None
    if os.environ.get("FOUNDRY_TRACING_ENABLED", "1") != "0":
        try:
            from opentelemetry import trace
            from opentelemetry.exporter.otlp.proto.http.trace_exporter import (
                OTLPSpanExporter,
            )
            from opentelemetry.instrumentation.openai_v2 import OpenAIInstrumentor
            from opentelemetry.sdk.resources import Resource
            from opentelemetry.sdk.trace import TracerProvider
            from opentelemetry.sdk.trace.export import BatchSpanProcessor
            from opentelemetry.trace import Status, StatusCode
        except ImportError as error:
            ai_log(
                "TRACING UNAVAILABLE: OpenTelemetry tracing packages are not "
                "installed; the Agent request will still run. Install them with: "
                'python3 -m pip install "opentelemetry-instrumentation-openai-v2==2.1b0" '
                '"opentelemetry-sdk==1.34.1" '
                '"opentelemetry-exporter-otlp-proto-http==1.34.1"'
            )
        else:
            otlp_endpoint = os.environ.get(
                "FOUNDRY_OTEL_ENDPOINT",
                os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318"),
            ).rstrip("/")
            trace_endpoint = os.environ.get(
                "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT",
                f"{otlp_endpoint}/v1/traces",
            )
            os.environ.setdefault(
                "OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT", "false"
            )
            try:
                tracer_provider = TracerProvider(
                    resource=Resource.create(
                        {"service.name": "azure-hld-generator"}
                    )
                )
                tracer_provider.add_span_processor(
                    BatchSpanProcessor(OTLPSpanExporter(endpoint=trace_endpoint))
                )
                trace.set_tracer_provider(tracer_provider)
                OpenAIInstrumentor().instrument()
                tracer = trace.get_tracer("azure_hld_generator.foundry_agent")
                ai_log(
                    "TRACING ENABLED: OpenAI SDK instrumentation exports spans "
                    "to the configured OTLP HTTP collector; prompt/response "
                    "content capture is disabled."
                )
            except Exception as error:
                if tracer_provider is not None:
                    tracer_provider.shutdown()
                tracer_provider = None
                ai_log(
                    "TRACING INITIALIZATION FAILED: "
                    f"{type(error).__name__}: {safe_error_detail(error)}. "
                    "The Agent request will still run without tracing."
                )

    work_items = []
    for category, entries in (
        ("vnets", evidence["vnets"]),
        ("subnets", evidence["subnets"]),
        ("apim_services", evidence["apim_services"]),
    ):
        work_items.extend(
            {"kind": category, "data": entry} for entry in entries
        )
    work_items.extend(
        {"kind": "architecture_resource", "data": resource}
        for resource in resource_evidence
    )

    def serialized_size(item):
        return len(json.dumps(item, separators=(",", ":"), ensure_ascii=False))

    batches = []
    current_batch = []
    current_size = 0
    for item in work_items:
        item_size = serialized_size(item)
        if current_batch and current_size + item_size > max_input_chars:
            batches.append(current_batch)
            current_batch = []
            current_size = 0
        current_batch.append(item)
        current_size += item_size
    if current_batch:
        batches.append(current_batch)

    counts_by_kind = {
        kind: sum(item["kind"] == kind for item in work_items)
        for kind in ("vnets", "subnets", "apim_services", "architecture_resource")
    }
    ai_log(
        "ENABLED: "
        f"agent={agent_name}@{agent_version}; "
        f"evidence_items={len(work_items)} "
        f"(vnets={counts_by_kind['vnets']}, subnets={counts_by_kind['subnets']}, "
        f"apim={counts_by_kind['apim_services']}, "
        f"architecture_resources={counts_by_kind['architecture_resource']}); "
        f"max_batch_chars={max_input_chars}; batches={len(batches)}."
    )
    credential = DefaultAzureCredential()
    project_client = None
    try:
        project_client = AIProjectClient(
            endpoint=project_endpoint,
            credential=credential,
        )
        openai_client = project_client.get_openai_client()
    except Exception:
        if project_client is not None:
            project_client.close()
        credential.close()
        raise

    def retry_delay_seconds(error, attempt):
        headers = getattr(getattr(error, "response", None), "headers", {}) or {}
        retry_after_ms = headers.get("retry-after-ms")
        if retry_after_ms is not None:
            try:
                return max(float(retry_after_ms) / 1000, 0.25)
            except (TypeError, ValueError):
                pass
        retry_after = headers.get("retry-after")
        if retry_after is not None:
            try:
                return max(float(retry_after), 0.25)
            except (TypeError, ValueError):
                pass
        token_reset = headers.get("x-ratelimit-reset-tokens", "")
        match = re.fullmatch(r"\s*(\d+(?:\.\d+)?)s?\s*", str(token_reset))
        if match:
            return max(float(match.group(1)), 0.25)
        return min(2 ** (attempt + 1), 30)

    def create_agent_response(prompt):
        if tracer is None:
            return openai_client.responses.create(
                input=[{"role": "user", "content": prompt}],
                extra_body={
                    "agent_reference": {
                        "name": agent_name,
                        "version": agent_version,
                        "type": "agent_reference",
                    }
                },
            )

        with tracer.start_as_current_span(
            "foundry.agent.responses.create",
            attributes={
                "gen_ai.operation.name": "invoke_agent",
                "gen_ai.agent.name": agent_name,
                "gen_ai.agent.version": agent_version,
            },
        ) as span:
            try:
                response = openai_client.responses.create(
                    input=[{"role": "user", "content": prompt}],
                    extra_body={
                        "agent_reference": {
                            "name": agent_name,
                            "version": agent_version,
                            "type": "agent_reference",
                        }
                    },
                )
            except Exception as error:
                span.set_attribute("error.type", type(error).__name__)
                span.set_status(Status(StatusCode.ERROR))
                raise

            response_id = getattr(response, "id", None)
            response_status = getattr(response, "status", None)
            usage = getattr(response, "usage", None)
            if response_id:
                span.set_attribute("gen_ai.response.id", str(response_id))
            if response_status:
                span.set_attribute("gen_ai.response.status", str(response_status))
            if usage is not None:
                for usage_field in (
                    "input_tokens",
                    "output_tokens",
                    "total_tokens",
                ):
                    usage_value = getattr(usage, usage_field, None)
                    if isinstance(usage_value, (int, float)):
                        span.set_attribute(
                            f"gen_ai.usage.{usage_field}", usage_value
                        )
            span.set_status(Status(StatusCode.OK))
            return response

    def request_batch(batch, request_label, retry_attempt=0):
        batch_evidence = {
            "network_design": {
                "vnets": [
                    item["data"] for item in batch if item["kind"] == "vnets"
                ],
                "subnets": [
                    item["data"] for item in batch if item["kind"] == "subnets"
                ],
                "apim_services": [
                    item["data"]
                    for item in batch
                    if item["kind"] == "apim_services"
                ],
            },
            "resources": [
                item["data"]
                for item in batch
                if item["kind"] == "architecture_resource"
            ],
        }
        expected_resources = {
            resource["resource_id"].lower(): resource
            for resource in batch_evidence["resources"]
        }
        prompt = f"""
Follow the architecture-analysis instructions configured on this Foundry Agent.
Use only the supplied Azure inventory as observed Azure evidence. Return one
strict JSON object matching this response contract:

{{
  "vnet_notes": "string",
  "subnet_notes": "string",
  "apim_notes": "string",
  "resource_classifications": [{{
    "resource_id": "exact supplied Azure resource ID",
    "resource_name": "string",
    "azure_resource_type": "string",
    "vendor": "string",
    "product": "string",
    "category": "string",
    "technology": "string",
    "probable_role": "string",
    "environment": "string",
    "confidence": 0.0,
    "evidence": [{{
      "attribute": "string",
      "value": "string",
      "source": "azure_inventory",
      "evidence": "specific supplied fact"
    }}],
    "relationships": [{{
      "relationship": "string",
      "target_resource": "exact Azure resource ID present in supplied evidence",
      "purpose": "string"
    }}],
    "architecture_observations": ["string"],
    "recommendations": ["string"],
    "required_validation": ["string"],
    "well_architected_assessment": [{{
      "pillar": "Reliability | Security | Cost Optimization | Operational Excellence | Performance Efficiency",
      "observed": "concise Azure-inventory observation",
      "recommendation": "evidence-grounded action",
      "required_validation": "specific follow-up check",
      "priority": "High | Medium | Low | Informational",
      "evidence": [{{
        "attribute": "string",
        "value": "string",
        "source": "azure_inventory",
        "evidence": "specific supplied fact"
      }}]
    }}]
  }}],
  "architecture_summary": {{
    "network_architecture": ["string"],
    "security_architecture": ["string"],
    "application_delivery": ["string"],
    "connectivity": ["string"],
    "high_availability": ["string"]
  }},
  "findings": ["string"]
}}

Return exactly one classification for every item in "resources", and no others.
Preserve resource IDs, names and Azure resource types exactly as supplied.
Every claim must cite a supplied fact in "evidence". Distinguish observation,
inference, interpretation, recommendation and validation. Missing values mean
"not reported", never "absent", disabled or noncompliant. Do not claim appliance
internal configuration or in-cluster workload state. Only state relationships
supported by supplied IDs or explicit associations. Confidence must be numeric
between 0 and 1. Use empty strings/arrays when the evidence does not support a
conclusion. The network note string must be empty when its evidence array is
empty. Do not include Markdown fences or text outside the JSON object.

Provide a concise Well-Architected Review for every resource whose
"inventory_key" is one of: vms, aks_clusters, aro_clusters, vm_scale_sets,
sql_servers, sql_databases, sql_managed_instances, postgres_servers,
mysql_servers, cosmos_accounts,
app_services, function_apps, or apim_services. Use only relevant pillars:
Reliability, Security, Cost Optimization, Operational Excellence, and
Performance Efficiency. Return one or more assessment rows per such resource;
return an empty assessment array for other resource types. Return no more than
three concise, high-value rows per resource; do not create boilerplate rows
for all five pillars. Each row must cite one or
more exact facts already listed in that classification's "evidence". The
"observed" field states only what the inventory reports; the recommendation
and validation must be concise and actionable. If a setting needed for an
assessment is not reported, state that it is not reported and ask for the
specific validation instead of judging compliance. Do not calculate a
Well-Architected score or claim the resource passes/fails a pillar.
"priority" is review urgency only, not a compliance verdict; use Informational
for missing evidence unless a material issue is directly observed. Keep each
assessment to one pillar and avoid duplicating the general observations,
recommendations, or required_validation arrays.

Evidence citations may reference a scalar field nested in a supplied resource
object using a dotted attribute path such as "sku.capacity". Cite the exact
scalar value from the supplied inventory, even if the classification evidence
also summarizes its parent object as a combined value.

For every sql_servers resource, include Security review coverage for the
reported publicNetworkAccess value, Microsoft Entra administrator configuration
and Entra-only authentication as separate facts, plus the SQL auditing policy,
enabled audit diagnostic categories and destinations. Explain that an Entra
administrator being configured does not prove SQL authentication is disabled;
review the Entra-only authentication setting separately. If any of these values
are "Not reported", request validation instead of inferring a state. Keep these
checks concise and within the three-row limit.

Review focus by resource: AKS/ARO/VMSS reliability, security, scaling/cost,
upgrade/operations and performance from their collected Azure properties;
VM image/size/network/public exposure/availability evidence; SQL/PostgreSQL/
MySQL/Cosmos data-service SKU, network exposure, availability/backup/version
properties when supplied; App Service/Functions plan, SKU, state, HTTPS and
network evidence; APIM SKU/capacity, network exposure, gateway and provisioning
evidence. A missing property is a validation gap, not proof of a misconfiguration.

Design evidence:
{json.dumps(batch_evidence, ensure_ascii=False)}
"""
        evidence_counts = {
            kind: sum(item["kind"] == kind for item in batch)
            for kind in ("vnets", "subnets", "apim_services", "architecture_resource")
        }
        ai_log(
            f"REQUEST {request_label}: calling Agent with {len(batch)} evidence "
            f"item(s), prompt_chars={len(prompt)} "
            f"(vnets={evidence_counts['vnets']}, "
            f"subnets={evidence_counts['subnets']}, "
            f"apim={evidence_counts['apim_services']}, "
            f"resources={evidence_counts['architecture_resource']})."
        )
        request_started = time.monotonic()
        try:
            response = create_agent_response(prompt)
        except RateLimitError as error:
            if len(batch) > 1:
                delay = retry_delay_seconds(error, retry_attempt)
                print(
                    f"[AI] WARNING: rate limit for request {request_label}; splitting a batch "
                    f"of {len(batch)} evidence items and retrying sequentially "
                    f"after {delay:g}s.",
                    file=sys.stdout,
                    flush=True,
                )
                time.sleep(delay)
                midpoint = len(batch) // 2
                left = request_batch(batch[:midpoint], f"{request_label}a")
                right = request_batch(batch[midpoint:], f"{request_label}b")
                combined = {
                    key: "\n\n".join(
                        value for value in (left[key], right[key]) if value
                    )
                    for key in ("vnet_notes", "subnet_notes", "apim_notes")
                }
                combined["classification_by_id"] = {
                    **left["classification_by_id"],
                    **right["classification_by_id"],
                }
                combined["architecture_summary"] = {
                    key: left["architecture_summary"][key]
                    + right["architecture_summary"][key]
                    for key in left["architecture_summary"]
                }
                combined["findings"] = list(dict.fromkeys(
                    left["findings"] + right["findings"]
                ))
                return combined
            if retry_attempt < 3:
                delay = retry_delay_seconds(error, retry_attempt)
                ai_log(
                    f"WARNING: rate limit for single-item request {request_label}; "
                    f"retrying in {delay:g}s ({retry_attempt + 1}/3)."
                )
                time.sleep(delay)
                return request_batch(batch, request_label, retry_attempt + 1)
            raise RuntimeError(
                "Foundry token rate limit persisted for a single evidence item "
                "after three retries. "
                "Retry later or reduce the evidence fields."
            ) from error
        except Exception as error:
            ai_log(
                f"REQUEST {request_label} FAILED after "
                f"{time.monotonic() - request_started:.1f}s: "
                f"{type(error).__name__}: {safe_error_detail(error)}"
            )
            raise

        output_text = getattr(response, "output_text", None)
        usage = getattr(response, "usage", None)
        usage_summary = ""
        if usage is not None:
            usage_parts = [
                f"{name}={getattr(usage, name)}"
                for name in ("input_tokens", "output_tokens", "total_tokens")
                if getattr(usage, name, None) is not None
            ]
            if usage_parts:
                usage_summary = "; " + ", ".join(usage_parts)
        response_id = getattr(response, "id", None)
        response_status = getattr(response, "status", None)
        response_metadata = []
        if response_id:
            response_metadata.append(f"id={response_id}")
        if response_status:
            response_metadata.append(f"status={response_status}")
        if usage_summary:
            response_metadata.append(usage_summary.lstrip("; "))
        ai_log(
            f"RESPONSE {request_label}: received after "
            f"{time.monotonic() - request_started:.1f}s; "
            f"output_chars={len(output_text) if isinstance(output_text, str) else 0}"
            f"{'; ' + '; '.join(response_metadata) if response_metadata else ''}."
        )
        if not isinstance(output_text, str) or not output_text.strip():
            raise RuntimeError("Foundry Agent returned no output text.")
        ai_log(f"PARSE {request_label}: decoding Agent JSON output.")
        try:
            notes = json.loads(output_text)
        except json.JSONDecodeError as error:
            raise RuntimeError(
                "Foundry Agent response was not valid JSON."
            ) from error
        ai_log(
            f"VALIDATE {request_label}: checking response fields, evidence "
            "citations, resource IDs, and relationship targets."
        )
        expected_keys = {
            "vnet_notes",
            "subnet_notes",
            "apim_notes",
            "resource_classifications",
            "architecture_summary",
            "findings",
        }
        if not isinstance(notes, dict) or set(notes) != expected_keys:
            raise RuntimeError(
                "Foundry Agent response does not match the required architecture JSON schema."
            )
        note_keys = {"vnet_notes", "subnet_notes", "apim_notes"}
        if any(not isinstance(notes[key], str) for key in note_keys):
            raise RuntimeError("Foundry Agent design-note values must all be strings.")
        for key, category in (
            ("vnet_notes", "vnets"),
            ("subnet_notes", "subnets"),
            ("apim_notes", "apim_services"),
        ):
            if not batch_evidence["network_design"][category] and notes[key].strip():
                print(
                    f"WARNING: Discarding {key} from this batch because it "
                    "contained no matching evidence.",
                    file=sys.stderr,
                )
                notes[key] = ""

        classifications = notes["resource_classifications"]
        if not isinstance(classifications, list):
            raise RuntimeError(
                "Foundry Agent resource_classifications must be a JSON array."
            )
        classification_fields = {
            "resource_id",
            "resource_name",
            "azure_resource_type",
            "vendor",
            "product",
            "category",
            "technology",
            "probable_role",
            "environment",
            "confidence",
            "evidence",
            "relationships",
            "architecture_observations",
            "recommendations",
            "required_validation",
            "well_architected_assessment",
        }
        allowed_well_architected_pillars = {
            "Reliability",
            "Security",
            "Cost Optimization",
            "Operational Excellence",
            "Performance Efficiency",
        }
        allowed_review_priorities = {
            "High",
            "Medium",
            "Low",
            "Informational",
        }
        classification_by_id = {}
        for item in classifications:
            if (
                not isinstance(item, dict)
                or set(item) != classification_fields
                or not isinstance(item["resource_id"], str)
            ):
                raise RuntimeError(
                    "Foundry Agent returned a malformed resource classification."
                )
            resource_id = item["resource_id"].strip().lower()
            if (
                resource_id not in expected_resources
                or resource_id in classification_by_id
            ):
                raise RuntimeError(
                    "Foundry Agent returned an unknown or duplicate resource ID."
                )
            resource = expected_resources[resource_id]
            if item["resource_id"].strip().lower() != resource["resource_id"].lower():
                raise RuntimeError(
                    "Foundry Agent changed the authoritative Azure resource ID."
                )
            text_fields = (
                "resource_name",
                "azure_resource_type",
                "vendor",
                "product",
                "category",
                "technology",
                "probable_role",
                "environment",
            )
            if any(not isinstance(item[field], str) for field in text_fields):
                raise RuntimeError(
                    "Foundry Agent classification string fields are malformed."
                )
            confidence = item["confidence"]
            if (
                isinstance(confidence, bool)
                or not isinstance(confidence, (int, float))
                or not 0 <= confidence <= 1
            ):
                raise RuntimeError(
                    "Foundry Agent confidence must be a number from 0 to 1."
                )
            if not all(
                isinstance(item[field], list)
                and all(isinstance(value, str) for value in item[field])
                for field in (
                    "architecture_observations",
                    "recommendations",
                    "required_validation",
                )
            ):
                raise RuntimeError(
                    "Foundry Agent observation, recommendation, and validation "
                    "fields must be arrays of strings."
                )
            if not isinstance(item["evidence"], list):
                raise RuntimeError("Foundry Agent evidence must be a JSON array.")
            if not item["evidence"]:
                raise RuntimeError(
                    "Foundry Agent classifications must cite at least one evidence item."
                )
            validated_evidence = []
            for citation in item["evidence"]:
                if (
                    not isinstance(citation, dict)
                    or set(citation) != {"attribute", "value", "source", "evidence"}
                    or not all(
                        isinstance(citation[field], str)
                        for field in ("attribute", "value", "source", "evidence")
                    )
                    or not citation["attribute"].strip()
                    or not citation["evidence"].strip()
                    or citation["source"] != "azure_inventory"
                ):
                    raise RuntimeError(
                        "Foundry Agent evidence citations must identify "
                        "azure_inventory facts."
                    )
                validated_evidence.append(citation)

            def match_validated_citation(citation):
                if (
                    not isinstance(citation, dict)
                    or set(citation) != {"attribute", "value", "source", "evidence"}
                    or not all(
                        isinstance(citation[field], str)
                        for field in ("attribute", "value", "source", "evidence")
                    )
                    or not citation["attribute"].strip()
                    or not citation["evidence"].strip()
                    or citation["source"] != "azure_inventory"
                ):
                    raise RuntimeError(
                        "Well-Architected assessment citations must identify "
                        "azure_inventory facts."
                    )

                for validated_citation in validated_evidence:
                    if (
                        validated_citation["attribute"].strip().casefold()
                        == citation["attribute"].strip().casefold()
                        and validated_citation["value"].strip()
                        == citation["value"].strip()
                        and validated_citation["source"] == citation["source"]
                    ):
                        return validated_citation

                attribute_parts = [
                    part.strip().casefold()
                    for part in citation["attribute"].split(".")
                    if part.strip()
                ]
                observed_value = resource
                for attribute_part in attribute_parts:
                    if not isinstance(observed_value, dict):
                        observed_value = None
                        break
                    matching_key = next(
                        (
                            key
                            for key in observed_value
                            if str(key).casefold() == attribute_part
                        ),
                        None,
                    )
                    if matching_key is None:
                        observed_value = None
                        break
                    observed_value = observed_value[matching_key]

                if (
                    attribute_parts
                    and isinstance(observed_value, (str, int, float, bool))
                    and str(observed_value).strip() == citation["value"].strip()
                ):
                    return {
                        "attribute": citation["attribute"],
                        "value": str(observed_value),
                        "source": "azure_inventory",
                        "evidence": (
                            f"{citation['attribute']}={observed_value} "
                            "from supplied Azure inventory"
                        ),
                    }
                if os.environ.get("AI_DEBUG_CITATIONS", "").strip().lower() in {
                    "1",
                    "true",
                    "yes",
                }:
                    print(
                        "[AI] CITATION DEBUG: "
                        + json.dumps(
                            {
                                "request": request_label,
                                "resource_id": resource.get("resource_id", ""),
                                "rejected_citation": citation,
                                "validated_citations": [
                                    {
                                        "attribute": item["attribute"],
                                        "value": item["value"],
                                        "source": item["source"],
                                    }
                                    for item in validated_evidence
                                ],
                            },
                            ensure_ascii=False,
                        ),
                        file=sys.stderr,
                        flush=True,
                    )
                raise RuntimeError(
                    "Well-Architected assessment citations must reference an "
                    "attribute and value in the resource's validated evidence."
                )

            assessments = item["well_architected_assessment"]
            if not isinstance(assessments, list):
                raise RuntimeError(
                    "Foundry Agent well_architected_assessment must be an array."
                )
            if (
                resource.get("inventory_key") in well_architected_inventory_types
                and not assessments
            ):
                raise RuntimeError(
                    "Foundry Agent omitted the Well-Architected Review for "
                    f"{resource.get('inventory_key')} resource "
                    f"{resource['resource_id']}."
                )
            if (
                resource.get("inventory_key") not in well_architected_inventory_types
                and assessments
            ):
                raise RuntimeError(
                    "Foundry Agent returned an out-of-scope Well-Architected "
                    f"Review for {resource.get('inventory_key')} resource "
                    f"{resource['resource_id']}."
                )
            if len(assessments) > 3:
                raise RuntimeError(
                    "Foundry Agent returned more than three Well-Architected "
                    f"rows for {resource.get('inventory_key')} resource "
                    f"{resource['resource_id']}."
                )
            validated_assessments = []
            for assessment in assessments:
                if (
                    not isinstance(assessment, dict)
                    or set(assessment)
                    != {
                        "pillar",
                        "observed",
                        "recommendation",
                        "required_validation",
                        "priority",
                        "evidence",
                    }
                    or not all(
                        isinstance(assessment[field], str)
                        for field in (
                            "pillar",
                            "observed",
                            "recommendation",
                            "required_validation",
                            "priority",
                        )
                    )
                    or assessment["pillar"] not in allowed_well_architected_pillars
                    or assessment["priority"] not in allowed_review_priorities
                    or not assessment["observed"].strip()
                    or not assessment["recommendation"].strip()
                    or not assessment["required_validation"].strip()
                    or not isinstance(assessment["evidence"], list)
                    or not assessment["evidence"]
                ):
                    raise RuntimeError(
                        "Foundry Agent returned a malformed Well-Architected "
                        "assessment row."
                    )
                assessment_evidence = []
                for citation in assessment["evidence"]:
                    assessment_evidence.append(
                        match_validated_citation(citation)
                    )
                validated_assessments.append({
                    **assessment,
                    "evidence": assessment_evidence,
                })
            if not isinstance(item["relationships"], list):
                raise RuntimeError("Foundry Agent relationships must be a JSON array.")
            validated_relationships = []
            for relationship in item["relationships"]:
                if (
                    not isinstance(relationship, dict)
                    or set(relationship)
                    != {"relationship", "target_resource", "purpose"}
                    or not all(
                        isinstance(relationship[field], str)
                        for field in ("relationship", "target_resource", "purpose")
                    )
                ):
                    raise RuntimeError(
                        "Foundry Agent returned a malformed resource relationship."
                    )
                target_id = relationship["target_resource"].strip().lower()
                if target_id not in known_resource_ids:
                    raise RuntimeError(
                        "Foundry Agent relationship references a resource ID "
                        "not present in the collected inventory."
                    )
                validated_relationships.append({
                    **relationship,
                    "target_resource": known_resource_ids[target_id],
                })
            if item["resource_name"] != resource["name"]:
                print(
                    "WARNING: Agent resource name differed from Azure inventory; "
                    "retaining the Azure value.",
                    file=sys.stderr,
                )
            if item["azure_resource_type"] != resource["azure_type"]:
                print(
                    "WARNING: Agent resource type differed from Azure inventory; "
                    "retaining the Azure value.",
                    file=sys.stderr,
                )
            classification_by_id[resource_id] = {
                **item,
                "resource_id": resource["resource_id"],
                "resource_name": resource["name"],
                "azure_resource_type": resource["azure_type"],
                "evidence": validated_evidence,
                "relationships": validated_relationships,
                "well_architected_assessment": validated_assessments,
                "confidence": float(confidence),
                "evidence_id": resource["evidence_id"],
                "resource_type": resource["resource_type"],
                "subscription": resource["subscription"],
                "resource_group": resource["resource_group"],
                "location": resource["location"],
                "platform_detail_type": resource.get("platform_detail_type", ""),
            }
        missing_classifications = set(expected_resources) - set(classification_by_id)
        if missing_classifications:
            raise RuntimeError(
                "Foundry Agent omitted classifications for resource IDs: "
                + ", ".join(
                    expected_resources[resource_id]["resource_id"]
                    for resource_id in sorted(missing_classifications)
                )
            )
        summary_categories = {
            "network_architecture",
            "security_architecture",
            "application_delivery",
            "connectivity",
            "high_availability",
        }
        architecture_summary = notes["architecture_summary"]
        if (
            not isinstance(architecture_summary, dict)
            or set(architecture_summary) != summary_categories
            or any(
                not isinstance(items, list)
                or not all(isinstance(value, str) for value in items)
                for items in architecture_summary.values()
            )
        ):
            raise RuntimeError(
                "Foundry Agent architecture_summary does not match the required schema."
            )
        if (
            not isinstance(notes["findings"], list)
            or not all(isinstance(value, str) for value in notes["findings"])
        ):
            raise RuntimeError("Foundry Agent findings must be an array of strings.")
        citation_count = sum(
            len(item["evidence"]) for item in classification_by_id.values()
        )
        relationship_count = sum(
            len(item["relationships"]) for item in classification_by_id.values()
        )
        well_architected_count = sum(
            len(item["well_architected_assessment"])
            for item in classification_by_id.values()
        )
        ai_log(
            f"VALIDATED {request_label}: classifications="
            f"{len(classification_by_id)}/{len(expected_resources)}, "
            f"citations={citation_count}, relationships={relationship_count}, "
            f"well_architected_rows={well_architected_count}, "
            f"findings={len(notes['findings'])}; schema and inventory references passed."
        )
        notes["classification_by_id"] = classification_by_id
        return notes

    aggregated_notes = {
        "vnet_notes": [],
        "subnet_notes": [],
        "apim_notes": [],
    }
    classification_by_id = {}
    aggregated_architecture = {
        key: []
        for key in (
            "network_architecture",
            "security_architecture",
            "application_delivery",
            "connectivity",
            "high_availability",
        )
    }
    aggregated_findings = []
    ai_log(
        f"PREPARED: {len(resource_evidence)} architecture resource(s), "
        f"{len(work_items)} total evidence item(s), {len(batches)} sequential "
        "batch(es). Evidence payloads are not printed."
    )
    try:
        for batch_number, batch in enumerate(batches, start=1):
            ai_log(
                f"BATCH {batch_number}/{len(batches)}: starting with "
                f"{len(batch)} evidence item(s)."
            )
            batch_notes = request_batch(batch, str(batch_number))
            for key in aggregated_notes:
                if batch_notes[key].strip():
                    aggregated_notes[key].append(batch_notes[key].strip())
            classification_by_id.update(batch_notes["classification_by_id"])
            for category, entries in batch_notes["architecture_summary"].items():
                aggregated_architecture[category].extend(entries)
            aggregated_findings.extend(batch_notes["findings"])
    finally:
        project_client.close()
        credential.close()
        if tracer_provider is not None:
            try:
                spans_flushed = tracer_provider.force_flush(timeout_millis=10000)
                tracer_provider.shutdown()
                if spans_flushed:
                    ai_log("TRACING FLUSHED: exported pending Agent spans.")
                else:
                    ai_log(
                        "TRACING EXPORT WARNING: the OTLP exporter did not "
                        "confirm delivery; verify the collector endpoint is "
                        "running and reachable."
                    )
            except Exception as error:
                ai_log(
                    "TRACING EXPORT WARNING: "
                    f"{type(error).__name__}: {safe_error_detail(error)}"
                )

    ai_log(
        f"MERGE: combining validated Agent analysis for "
        f"{len(classification_by_id)} resource(s) with authoritative Azure inventory."
    )
    result = {
        key: "\n\n".join(values) for key, values in aggregated_notes.items()
    }
    result["resource_classifications"] = [
        classification_by_id[resource["resource_id"].lower()]
        for resource in resource_evidence
        if resource["resource_id"].lower() in classification_by_id
    ]
    result["architecture_summary"] = {
        category: list(dict.fromkeys(entries))
        for category, entries in aggregated_architecture.items()
    }
    result["findings"] = list(dict.fromkeys(aggregated_findings))
    return result


AUTHOR = os.environ.get("HLD_AUTHOR", "Cloud4C")
REVIEWER = os.environ.get("HLD_REVIEWER", "TBD")
APPROVER = os.environ.get("HLD_APPROVER", "TBD")
CLASSIFICATION = os.environ.get("HLD_CLASSIFICATION", "Confidential")

doc = Document(str(template))

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def cell_text(cell, text):
    # A list value is rendered as a Word bullet list within a table cell. The
    # first item is a status label; all following items are alert-rule bullets.
    if isinstance(text, dict) and "alert_groups" in text:
        cell.text = ""
        cell.paragraphs[0].add_run(str(text.get("status", "Yes")))
        for group_name, entries in text.get("alert_groups", []):
            if not entries:
                continue
            group_paragraph = cell.add_paragraph()
            group_run = group_paragraph.add_run(group_name)
            group_run.bold = True
            for entry in entries:
                cell.add_paragraph(str(entry), style="List Bullet")
    elif isinstance(text, (list, tuple)):
        cell.text = ""
        entries = [str(value) for value in text if value not in (None, "")]
        if entries:
            cell.paragraphs[0].add_run(entries[0])
            for entry in entries[1:]:
                cell.add_paragraph(entry, style="List Bullet")
    else:
        cell.text = "" if text is None else str(text)
    for p in cell.paragraphs:
        for r in p.runs:
            r.font.size = Pt(8.5)

def clear_cell(cell):
    cell.text = ""

def set_repeat_table_header(row):
    trPr = row._tr.get_or_add_trPr()
    tblHeader = OxmlElement("w:tblHeader")
    tblHeader.set(qn("w:val"), "true")
    trPr.append(tblHeader)

def shade_cell(cell, fill="D9EAF7"):
    tcPr = cell._tc.get_or_add_tcPr()
    shd = OxmlElement("w:shd")
    shd.set(qn("w:fill"), fill)
    tcPr.append(shd)

def add_table(headers, rows, widths=None):
    t = doc.add_table(rows=1, cols=len(headers))
    t.alignment = WD_TABLE_ALIGNMENT.CENTER
    t.style = "Table Grid"
    hdr = t.rows[0]
    set_repeat_table_header(hdr)
    for i,h in enumerate(headers):
        cell_text(hdr.cells[i], h)
        shade_cell(hdr.cells[i])
        hdr.cells[i].vertical_alignment = WD_CELL_VERTICAL_ALIGNMENT.CENTER
    for row in rows:
        cells = t.add_row().cells
        for i, value in enumerate(row):
            cell_text(cells[i], value)
            cells[i].vertical_alignment = WD_CELL_VERTICAL_ALIGNMENT.CENTER
    if widths:
        for row in t.rows:
            for i,w in enumerate(widths):
                if i < len(row.cells):
                    row.cells[i].width = Inches(w)
    return t

def add_heading(text, level=1):
    heading_text = re.sub(
        r"^\s*\d+(?:\.\d+)*\s+",
        "",
        str(text)
    )
    return doc.add_heading(heading_text, level=level)

def add_para(text="", style=None):
    p = doc.add_paragraph(style=style)
    p.add_run(str(text))
    return p


def add_model_notes(heading, text):
    if not isinstance(text, str) or not text.strip():
        return
    add_heading(heading, 3)
    for paragraph in re.split(r"\n\s*\n", text.strip()):
        if paragraph.strip():
            add_para(paragraph.strip())


def add_text_evidence(path, heading, level=2):
    if not path.exists():
        return False
    content = path.read_text(encoding="utf-8").strip()
    if not content:
        return False
    add_heading(heading, level)
    add_para(
        "This evidence was pasted from the Azure Portal Management Groups view. "
        "It is included as supplied and is not used to recreate or modify Azure Management Groups."
    )
    for line in content.splitlines():
        paragraph = doc.add_paragraph()
        run = paragraph.add_run(line)
        run.font.name = "Consolas"
        run.font.size = Pt(8)
    return True

def add_image_evidence(path, heading, caption):
    if not path.exists():
        return False
    try:
        add_heading(heading, 3)
        add_para(
            "This screenshot was captured from the Azure Portal Management Groups view. "
            "It is included as supplied and is not used to recreate or modify Azure Management Groups."
        )
        doc.add_picture(str(path), width=Inches(6.4))
        add_caption(caption)
        return True
    except Exception as error:
        add_para(f"Management Group screenshot could not be embedded: {error}")
        return False

def add_bullets(items):

    for item in items:

        p = doc.add_paragraph()

        p.add_run("• ")

        p.add_run(str(item))


def add_caption(text):

    p = doc.add_paragraph()

    p.add_run(str(text))

    p.alignment = WD_ALIGN_PARAGRAPH.CENTER

def unique(items):
    return sorted(set(x for x in items if x not in (None, "")))

def rg_from_id(rid):
    if not rid: return ""
    m = re.search(r"/resourceGroups/([^/]+)", rid, re.I)
    return m.group(1) if m else ""

def resource_name_from_id(rid):
    if not rid: return ""
    return str(rid).rstrip("/").split("/")[-1]

def sub_from_id(rid):
    if not rid: return ""
    m = re.search(r"/subscriptions/([^/]+)", rid, re.I)
    return m.group(1) if m else ""


def monitoring_coverage(resource_type, resources, metric_alerts, diagnostics):
    total_resources = len(resources or [])

    diag_by_id = {}
    for diag in diagnostics or []:
        if not isinstance(diag, dict):
            continue
        rid = str(diag.get("resourceId") or "").lower()
        if rid:
            diag_by_id[rid] = diag

    resources_with_alerts = 0
    resources_with_diagnostics = 0
    for resource in resources or []:
        rid = str(resource.get("id") or resource.get("resourceId") or "").lower()
        if rid and any(alert_targets_resource(alert, resource) for alert in metric_alerts or []):
            resources_with_alerts += 1
        if rid and rid in diag_by_id and bool(diag_by_id[rid].get("diagnosticsEnabled")):
            resources_with_diagnostics += 1

    alert_coverage = round((resources_with_alerts / total_resources) * 100, 2) if total_resources else 0
    diag_coverage = round((resources_with_diagnostics / total_resources) * 100, 2) if total_resources else 0

    return {
        "totalResources": total_resources,
        "resourcesWithAlerts": resources_with_alerts,
        "resourcesWithDiagnostics": resources_with_diagnostics,
        "alertCoveragePct": alert_coverage,
        "diagnosticCoveragePct": diag_coverage,
    }

def alert_scopes(alert):
    values = []
    if not isinstance(alert, dict):
        return values
    values.extend(alert.get("scopes") or [])
    properties = alert.get("properties") or {}
    if isinstance(properties, dict):
        values.extend(properties.get("scopes") or [])
        condition = properties.get("condition") or {}
        if isinstance(condition, dict):
            values.extend(condition.get("allOf", []) or [])
    normalized = []
    for value in values:
        if isinstance(value, str):
            normalized.append(value.rstrip("/").lower())
        elif isinstance(value, dict):
            scope = value.get("scope") or value.get("resourceId")
            if scope:
                normalized.append(str(scope).rstrip("/").lower())
    return sorted(set(normalized))

def scope_applies(scope, resource_id):
    scope = str(scope or "").rstrip("/").lower()
    resource_id = str(resource_id or "").rstrip("/").lower()
    return bool(scope and resource_id and (resource_id == scope or resource_id.startswith(scope + "/")))

def scope_is_exact_resource(scope, resource_id):
    """Return True only when an alert is scoped to this exact Azure resource.

    Subscription- and resource-group-scoped alerts are valid alerts, but are not
    resource alert rules.  Treating either as a match makes the same alert appear
    against every resource below that parent scope.
    """
    scope = str(scope or "").rstrip("/").lower()
    resource_id = str(resource_id or "").rstrip("/").lower()
    return bool(scope and resource_id and scope == resource_id)

def alert_label(alert):
    return alert.get("name") or alert.get("id", "").rstrip("/").split("/")[-1] or "Unnamed alert"

def alert_type(alert):
    resource_type = str(alert.get("type") or "").lower()
    if "activitylogalerts" in resource_type:
        return "Activity Log"
    if "scheduledqueryrules" in resource_type:
        return "Log Query"
    return "Metric"

def alert_enabled_value(alert):
    properties = alert.get("properties") or {}
    value = alert.get("enabled")
    if value in (None, "") and isinstance(properties, dict):
        value = properties.get("enabled", properties.get("enabledState"))
    if isinstance(value, bool):
        return "Yes" if value else "No"
    if str(value or "").strip().lower() in {"true", "yes", "enabled"}:
        return "Yes"
    if str(value or "").strip().lower() in {"false", "no", "disabled"}:
        return "No"
    return str(value or "Unknown")

def alert_field_value(alert, field):
    properties = alert.get("properties") or {}
    value = alert.get(field)
    if value is None or value == "":
        if isinstance(properties, dict):
            value = properties.get(field)
    return "Unknown" if value is None or value == "" else str(value)

def alert_target_resource_types(alert):
    """Return Azure resource types explicitly targeted by an alert rule."""
    properties = alert.get("properties") or {}
    target_types = (
        properties.get("targetResourceTypes")
        or properties.get("targetResourceType")
        or alert.get("targetResourceTypes")
        or alert.get("targetResourceType")
        or []
    )
    if isinstance(target_types, str):
        target_types = [target_types]

    # Activity Log Alerts store their resource-type filter in condition.allOf.
    condition = (properties.get("condition") or alert.get("condition")  or {} )
    if isinstance(condition, dict):
        for item in condition.get("allOf", []) or []:
            if not isinstance(item, dict):
                continue
            field = str(item.get("field") or "").replace("_", "").lower()
            if field in {"resourcetype", "resource type"}:
                value = item.get("equals") or item.get("containsAny") or item.get("contains") or []
                target_types.extend(value if isinstance(value, list) else [value])
            elif field in {"operationname", "operation name"}:
                value = item.get("equals") or item.get("containsAny") or item.get("contains") or []
                for operation in value if isinstance(value, list) else [value]:
                    parts = str(operation or "").strip("/").split("/")
                    # Azure operation names end in an action such as write,
                    # delete, or action. The preceding provider/type path is
                    # the target resource type.
                    if len(parts) >= 3 and parts[-1].lower() in {"read", "write", "delete", "action"}:
                        target_types.append("/".join(parts[:-1]))
    normalized = set()

    for item in target_types:

        if not item:
            continue

        value = str(item).lower()

        normalized.add(value)

        #
        # Resource Group normalization
        #
        if value == "microsoft.resources/subscriptions/resourcegroups":
            normalized.add(
                "microsoft.resources/resourcegroups"
            )

    return normalized

def alert_targets_resource(alert, resource):
    """
    Determine whether an alert applies to the Azure resource.

    Supports:
      1. Direct resource-level alert scope
      2. Resource-group scoped alerts targeting the resource type
      3. Subscription scoped alerts targeting the resource type

    Applies to:
      - Metric Alerts
      - Activity Log Alerts
      - Log Query / Scheduled Query Alerts
    """

    resource_id = str(
        resource.get("id")
        or resource.get("resourceId")
        or ""
    ).strip()

    if not resource_id:
        return False

    resource_id_lower = resource_id.lower()

    #
    # Azure resource type
    #
    resource_type = str(
        resource.get("type")
        or ""
    ).strip().lower()

    #
    # Resource Group
    #
    resource_rg = str(
        resource.get("resourceGroup")
        or resource.get("resource_group")
        or rg_from_id(resource_id)
    ).strip().lower()

    #
    # Subscription ID
    #
    subscription_id = ""

    try:
        id_parts = resource_id_lower.split("/")
        subscription_index = id_parts.index("subscriptions")
        subscription_id = id_parts[subscription_index + 1]
    except (ValueError, IndexError):
        pass

    scopes = alert_scopes(alert)

    # ================================================================
    # 1. DIRECT RESOURCE SCOPE
    # ================================================================

    for scope in scopes:

        scope = str(scope or "").strip().lower().rstrip("/")

        if not scope:
            continue

        if scope == resource_id_lower.rstrip("/"):
            return True

    # ================================================================
    # 2. TARGET RESOURCE TYPES
    # ================================================================

    target_types = alert_target_resource_types(alert)

    target_types = {
        str(item).strip().lower().rstrip("/")
        for item in target_types
        if str(item).strip()
    }

    #
    # Resource must have a type
    #
    if not resource_type:
        return False

    #
    # If target types exist,
    # ensure the resource type matches.
    #
    if target_types:

        type_matches = any(
            resource_type == t
            or resource_type.startswith(t + "/")
            or t.startswith(resource_type + "/")
            for t in target_types
        )

        if not type_matches:
            return False

    # ================================================================
    # 3. RESOURCE GROUP SCOPED ALERT
    # ================================================================

    if resource_rg and subscription_id:

        expected_rg_scope = (
            f"/subscriptions/{subscription_id}/resourcegroups/{resource_rg}"
        )

        for scope in scopes:

            scope = str(scope or "").strip().lower().rstrip("/")

            if scope != expected_rg_scope:
                continue

            #
            # No resource type found.
            # Skip instead of applying to everything.
            #
            if not target_types:
                continue

            #
            # Resource type already validated above.
            #
            return True

    # ================================================================
    # 4. SUBSCRIPTION SCOPED ALERT
    # ================================================================

    if subscription_id:

        expected_subscription_scope = (
            f"/subscriptions/{subscription_id}"
        )

        for scope in scopes:

            scope = str(scope or "").strip().lower().rstrip("/")

            if scope != expected_subscription_scope:
                continue

            #
            # No resource type extracted.
            # Do NOT match every resource.
            #
            if not target_types:
                continue

            #
            # Resource type already validated above.
            #
            return True

    # ================================================================
    # 5. FALLBACK
    # ================================================================

    return False
    """
    Determine whether an alert applies to the Azure resource.

    Supports:
      1. Direct resource-level alert scope
      2. Resource-group scoped alerts targeting the resource type
      3. Subscription scoped alerts targeting the resource type

    Applies to:
      - Metric Alerts
      - Activity Log Alerts
      - Log Query / Scheduled Query Alerts
    """

    resource_id = str(
        resource.get("id") or resource.get("resourceId") or ""
    ).strip()

    if not resource_id:
        return False

    resource_id_lower = resource_id.lower()

    # Azure resource type, for example:
    # Microsoft.Compute/virtualMachines
    # Microsoft.App/managedEnvironments
    resource_type = str(
        resource.get("type") or ""
    ).strip().lower()

    # Resource group
    resource_rg = str(
        resource.get("resourceGroup")
        or resource.get("resource_group")
        or rg_from_id(resource_id)
    ).strip().lower()

    # Subscription ID from resource ID
    subscription_id = ""
    id_parts = resource_id_lower.split("/")

    try:
        subscription_index = id_parts.index("subscriptions")
        subscription_id = id_parts[subscription_index + 1]
    except (ValueError, IndexError):
        pass

    scopes = alert_scopes(alert)

    # ================================================================
    # 1. DIRECT RESOURCE SCOPE
    # ================================================================
    #
    # This is the existing behaviour and preserves your working
    # VM metric-alert detection.
    #
    for scope in scopes:
        scope = str(scope or "").strip().lower().rstrip("/")

        if not scope:
            continue

        if scope == resource_id_lower.rstrip("/"):
            return True

    # ================================================================
    # 2. DETERMINE RESOURCE TYPES TARGETED BY THE ALERT
    # ================================================================
    #
    # alert_target_resource_types() already handles:
    #
    # - targetResourceType
    # - targetResourceTypes
    # - Activity Log condition.allOf -> resourceType
    # - Activity Log operationName
    #
    target_types = alert_target_resource_types(alert)

    target_types = {
        str(item).strip().lower().rstrip("/")
        for item in target_types
        if str(item).strip()
    }

    # If the resource has no type, we cannot safely perform
    # resource-type matching.
    if not resource_type or not target_types:
        return False

    # Exact or compatible Azure resource type match
    type_matches = any(
    resource_type == t
    or resource_type.startswith(t + "/")
    or t.startswith(resource_type + "/")
    for t in target_types
    )

    if not type_matches:
        return False

    # ================================================================
    # 3. RESOURCE-GROUP SCOPED ALERT
    # ================================================================
    #
    # Example:
    #
    # Alert scope:
    # /subscriptions/xxx/resourceGroups/rg-monitoring
    #
    # Resource:
    # /subscriptions/xxx/resourceGroups/rg-monitoring/providers/
    # Microsoft.App/managedEnvironments/cae-01
    #
    # If the alert explicitly targets Microsoft.App/managedEnvironments,
    # then it applies to this resource.
    #
    if resource_rg:

        expected_rg_scope = (
            f"/subscriptions/{subscription_id}/resourcegroups/{resource_rg}"
            if subscription_id
            else ""
        )

        for scope in scopes:

            scope = str(scope or "").strip().lower().rstrip("/")

            if scope != expected_rg_scope:
                continue

        #
        # Alert scoped at RG level and
        # applies to all resources in RG
        #
        if not target_types:
            return True

        #
        # Type-specific RG alert
        #
        if (
            resource_type in target_types
            or any(
                resource_type.startswith(t + "/")
                for t in target_types
            )
        ):
            return True
    return False

    # ================================================================
    # 4. SUBSCRIPTION SCOPED ALERT
    # ================================================================
    #
    # Example:
    #
    # Alert scope:
    # /subscriptions/xxx
    #
    # Target resource type:
    # Microsoft.App/managedEnvironments
    #
    # Resource:
    # Microsoft.App/managedEnvironments/cae-01
    #
    if subscription_id:

        expected_subscription_scope = (
            f"/subscriptions/{subscription_id}"
        )

        for scope in scopes:

            scope = str(scope or "").strip().lower().rstrip("/")

            if scope != expected_subscription_scope:
                continue

            #
            # Metric alert directly at subscription level
            #
            if not target_types:
                return True

            #
            # Activity Log Alert / Log Alert
            # matching resource type
            #
            if (
                resource_type in target_types
                or any(
                    resource_type.startswith(t + "/")
                    for t in target_types
                )
            ):
                return True

    return False

def resource_alert_status(resource, alerts):
    groups = {"Metric": [], "Activity Log": [], "Log Query": []}
    for alert in alerts or []:
        if alert_enabled_value(alert) != "Yes" or not alert_targets_resource(alert, resource):
            continue
        groups.setdefault(alert_type(alert), []).append(alert_label(alert))

    alert_groups = [
        ("Metric Alerts", sorted(set(groups["Metric"]))),
        ("Activity Log Alerts", sorted(set(groups["Activity Log"]))),
        ("Log Query Alerts", sorted(set(groups["Log Query"]))),
    ]
    return {"status": "Yes", "alert_groups": alert_groups} if any(items for _, items in alert_groups) else "No"

subs = data.get("subscriptions", [])
selected_subscription_ids = {
    sid.strip().lower()
    for sid in os.environ.get("SUBSCRIPTION_IDS", "").split(",")
    if sid.strip()
}
if selected_subscription_ids:
    available_ids = {
        str(subscription.get("subscription_id", "")).lower()
        for subscription in subs
    }
    missing_ids = selected_subscription_ids - available_ids
    if missing_ids:
        print(
            "ERROR: SUBSCRIPTION_IDS contains subscriptions not found in "
            f"{os.environ['INVENTORY']}: {', '.join(sorted(missing_ids))}",
            file=sys.stderr
        )
        sys.exit(1)
    subs = [
        subscription
        for subscription in subs
        if str(subscription.get("subscription_id", "")).lower()
        in selected_subscription_ids
    ]

model_enrichment_enabled = os.environ.get("MODEL_ENRICHMENT_ENABLED", "1")
if model_enrichment_enabled not in {"0", "1"}:
    raise ValueError("MODEL_ENRICHMENT_ENABLED must be either 0 or 1.")
model_design_notes = {}
if model_enrichment_enabled == "1":
    print(
        "[AI] ENABLED: the script will attempt a Foundry Agent call after "
        "inventory collection.",
        flush=True,
    )
    try:
        model_design_notes = invoke_network_design_agent(subs)
    except Exception as error:
        error_detail = re.sub(
            r"(?i)\bBearer\s+\S+", "Bearer [redacted]", str(error)
        )
        error_detail = re.sub(
            r"(?i)((?:api[_-]?key|access[_-]?token|password|secret)\s*[=:]\s*)[^\s,;]+",
            r"\1[redacted]",
            error_detail,
        )
        error_detail = re.sub(
            r"(?i)/subscriptions/[^,\s'\";]+",
            "[Azure resource ID redacted]",
            error_detail,
        )
        print(
            "[AI] ERROR: Foundry Agent analysis failed "
            f"({type(error).__name__}: {error_detail[:600]}); "
            "continuing with deterministic Azure inventory.",
            flush=True,
        )
else:
    print(
        "[AI] DISABLED: MODEL_ENRICHMENT_ENABLED=0; no Foundry Agent call "
        "will be made.",
        flush=True,
    )

# ---------------------------------------------------------------------------
# Use the uploaded document as the formatting baseline, but remove its
# environment-specific sample content after the confidentiality statement.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Use the uploaded document as the formatting baseline.
# DO NOT delete XML body elements because it removes section definitions
# and causes:
# IndexError: list index out of range
# when add_table() is called.
# ---------------------------------------------------------------------------

print("Template loaded")

print(
    "Document sections:",
    len(doc.sections)
)

# ============================================================================
# Dynamic Rendering Engine
# ============================================================================

def collect_rows(resource_key, mapper):

    rows=[]

    for s in subs:

        items = s.get(
            "inventory",
            {}
        ).get(
            resource_key,
            []
        )

        for item in items:

            try:

                row = mapper(
                    item,
                    s
                )

                rows.append(row)

            except Exception:
                pass

    return rows


def render_section(
    heading,
    headers,
    rows,
    level=2,
    description=""
):

    if len(rows) == 0:

        return False

    add_heading(
        heading,
        level
    )

    if description:
        add_para(description)

    add_table(
        headers,
        rows
    )

    add_para(
        f"Status: Deployed – details generated"
    )

    return True



def get_status(rows):

    if rows is None:
        return "Deployed – collection failed"

    if len(rows) == 0:
        return "Not deployed"

    return "Deployed – details generated"


def generic_catalog_item(title, description=None):

    catalog_name = re.sub(r"^\s*\d+(?:\.\d+)*\s*", "", title).strip().lower()

    return {

        "title": title,

        "description": description or (
            f"This section inventories {catalog_name} "
            "returned by the Azure control plane."
        ),

        "headers": [
            "Name",
            "Resource Group",
            "Subscription",
            "Location",
            "Type",
            "State",
            "Public Network Access"
        ],

        "mapper": lambda r,s: [
            r.get("name", ""),
            r.get("resourceGroup", r.get("resource_group", "")),
            s.get("display_name", s.get("subscription_id", "")),
            r.get("location", ""),
            r.get("type", ""),
            r.get("provisioningState", r.get("state", "")),
            public_network_access(r)
        ]

    }


def sku_value(resource, key):

    sku = resource.get("sku") or {}

    return sku.get(key, "") if isinstance(sku, dict) else ""


def public_network_access(resource):

    value = resource.get("publicNetworkAccess")
    if value not in (None, ""):
        return value

    properties = resource.get("properties") or {}
    return properties.get("publicNetworkAccess", "")


def plan_name(resource):

    profile = resource.get("hostingEnvironmentProfile") or {}
    profile_id = profile.get("id", "") if isinstance(profile, dict) else ""
    plan_id = resource.get("serverFarmId") or profile_id

    return plan_id.split("/")[-1] if plan_id else ""


def plan_resource(resource, subscription):

    name = plan_name(resource)

    for plan in subscription.get("inventory", {}).get("app_service_plans", []):
        if plan.get("name", "") == name:
            return plan

    return resource


# ============================================================================
# Resource Catalog
# ============================================================================

RESOURCE_CATALOG = {

    "4. Network Design": {

        "private_endpoints": {

            "title": "4.12 Private Endpoints",

            "description": "Private Endpoints provide private connectivity from virtual networks to Azure services without exposing traffic to the public internet.",

            "headers": [
                "Name",
                "Resource Group",
                "Location"
            ],

            "mapper": lambda r,s: [
                r.get("name",""),
                r.get("resourceGroup",""),
                r.get("location","")
            ]

        },

        "load_balancers": {

            "title": "4.13 Load Balancers",

            "description": "Load Balancers distribute inbound network traffic across healthy backend instances and expose the configured Azure SKU.",

            "headers": [
                "Name",
                "Resource Group",
                "Location",
                "SKU"
            ],

            "mapper": lambda r,s: [

                r.get("name",""),

                r.get("resourceGroup",""),

                r.get("location",""),

                (
                    r.get("sku",{})
                    .get("name","")
                    if isinstance(
                        r.get("sku"),
                        dict
                    )
                    else ""
                )

            ]

        }

    },

    "5. Compute And Storage": {

        "disks": {

            "title": "5.4 Managed Disks",

            "description": "Managed disks provide persistent block storage for Azure virtual machines, including capacity, performance tier, OS type and attachment state.",

            "headers": [

                "Disk Name",
                "Resource Group",
                "Subscription",
                "Location",
                "SKU",
                "Size (GiB)",
                "OS Type",
                "State",
                "Performance Tier",
                "Attached VM"

            ],

            "mapper": lambda d,s: [

                d.get("name",""),

                d.get("resourceGroup",""),

                s.get("display_name",""),

                d.get("location",""),

                d.get("disk_sku", ""),

                d.get("disk_size_gb", ""),

                d.get("disk_os_type", ""),

                d.get("disk_state", ""),

                d.get("performance_tier", ""),

                d.get("attached_vm", "")

            ]

        },

        "storage_accounts": {

            "title": "5.5 Storage Accounts",

            "description": "Storage accounts provide Azure data services; the inventory highlights account kind, SKU, public blob access and minimum TLS settings.",

            "headers": [

                "Storage Account",
                "Resource Group",
                "Subscription",
                "Location",
                "Kind",
                "SKU",
                "Blob Public Access",
                "Min TLS",
                "Public Network Access"

            ],

            "mapper": lambda r,s: [

                r.get("name",""),

                r.get("resourceGroup",""),

                s.get("display_name",""),

                r.get("location",""),

                r.get("kind",""),

                (
                    r.get("sku",{})
                    .get("name","")
                    if isinstance(
                        r.get("sku"),
                        dict
                    )
                    else ""
                ),

                r.get(
                    "allowBlobPublicAccess",
                    ""
                ),

                r.get(
                    "minimumTlsVersion",
                    ""
                ),

                public_network_access(r)

            ]

        },

        "app_services": {

            "title": "5.6 App Services",

            "description": "App Services host web applications on Azure App Service plans and are reported with their resource group, location and hosting plan.",

            "headers": [

                "Name",
                "Resource Group",
                "Subscription",
                "Location",
                "Plan",
                "SKU",
                "Tier",
                "Worker Size",
                "State",
                "Public Network Access"

            ],

            "mapper": lambda r,s: [

                r.get("name",""),

                r.get("resourceGroup",""),

                s.get("display_name", s.get("subscription_id", "")),

                r.get("location",""),

                plan_name(r),
                sku_value(plan_resource(r, s), "name"),
                sku_value(plan_resource(r, s), "tier"),
                sku_value(plan_resource(r, s), "size"),
                r.get("state", ""),
                public_network_access(r)

            ]

        },

        "function_apps": {

            "title": "5.7 Function Apps",

            "description": "Function Apps provide event-driven serverless compute and are reported with their resource group, location and hosting plan.",

            "headers": [

                "Name",
                "Resource Group",
                "Subscription",
                "Location",
                "Plan",
                "SKU",
                "Tier",
                "Worker Size",
                "State",
                "Public Network Access"

            ],

            "mapper": lambda r,s: [

                r.get("name",""),

                r.get("resourceGroup",""),

                s.get("display_name", s.get("subscription_id", "")),

                r.get("location",""),

                plan_name(r),
                sku_value(plan_resource(r, s), "name"),
                sku_value(plan_resource(r, s), "tier"),
                sku_value(plan_resource(r, s), "size"),
                r.get("state", ""),
                public_network_access(r)

            ]

        },

        "logic_apps": {

            "title": "5.8 Logic Apps",

            "description": (
                "Logic Apps provide workflow automation and integration services. "
                "The inventory includes both Consumption and Standard Logic Apps "
                "discovered across subscriptions, together with their resource group, "
                "subscription, deployment model, region and operational state."
                ),

            "headers": [

                "Name",
                "Resource Group",
                "Subscription",
                "Location",
                "Deployment Model",
                "State"

            ],

            "mapper": lambda r,s: [

                r.get("name",""),

                r.get("resourceGroup",""),

                s.get("display_name",""),

                r.get("location",""),

                (
                    "Standard"
                    if "workflowapp"
                    in str(r.get("kind","")).lower()
                    else "Consumption"
                ),

                r.get("state",r.get(provisioningState),"")

            ],
            

        },

        "container_apps": {

            "title": "5.9 Container Apps",

            "description": "Container Apps run containerized workloads on Azure-managed infrastructure and are linked to their managed environment.",

            "headers": [

                "Name",
                "Resource Group",
                "Location",
                "Environment"

            ],

            "mapper": lambda r,s: [

                r.get("name",""),

                r.get("resourceGroup",""),

                r.get("location",""),

                (
                    r.get(
                        "managedEnvironmentId",
                        ""
                    ).split("/")[-1]

                    if r.get(
                        "managedEnvironmentId"
                    )

                    else ""
                )

            ]

        }

    },

    "9. AI Platform": {

        "ai_resources": {

            "title": "9.1 AI Services",

            "description": "AI resources include readable Azure Cognitive Services, Machine Learning, AI Search and Bot Service resources discovered in each subscription.",

            "headers": [

                "Name",
                "Resource Group",
                "Region",
                "SKU",
                "Provider Type",
                "Public Network Access"

            ],

            "mapper": lambda r,s: [

                r.get("name",""),

                r.get("resourceGroup",""),

                r.get("location",""),

                (
                    r.get("sku",{})
                    .get("name","")
                    if isinstance(
                        r.get("sku"),
                        dict
                    )
                    else ""
                ),

                r.get("type",""),

                public_network_access(r)

            ]

        }

    },

    "10. Monitor": {

        "dcrs": {

            "title": "10.2 Data Collection Rules",

            "description": "Data Collection Rules define how Azure Monitor gathers, transforms and routes telemetry from monitored resources.",

            "headers": [

                "Name",
                "Resource Group",
                "Location"

            ],

            "mapper": lambda r,s: [

                r.get("name",""),

                r.get("resourceGroup",""),

                r.get("location","")

            ]

        }

    },

    "9. Resource Inventory Catalog": {

        "resource_groups": generic_catalog_item("5.10 Resource Groups"),
        "vnets": generic_catalog_item("4.12 Virtual Networks"),
        "subnets": {

            "title": "4.13 Subnets",

            "description": "Subnets divide a virtual network into addressable segments and show their parent VNet, address ranges and attached security controls.",

            "headers": [
                "Subnet",
                "VNet",
                "Resource Group",
                "Subscription",
                "Location",
                "Address Prefixes",
                "NSG",
                "Route Table",
                "Delegations"
            ],

            "mapper": lambda r,s: [
                r.get("name", ""),
                r.get("vnet", ""),
                r.get("resource_group", ""),
                s.get("display_name", s.get("subscription_id", "")),
                r.get("location", ""),
                ", ".join(r.get("address_prefixes") or []),
                resource_name_from_id(r.get("nsg_id", "")),
                resource_name_from_id(r.get("route_table_id", "")),
                ", ".join(r.get("delegations") or [])
            ]

        },
        "nsgs": generic_catalog_item("4.14 Network Security Groups"),
        "route_tables": generic_catalog_item("4.15 Route Tables"),
        "peerings": generic_catalog_item("4.16 VNet Peerings"),
        "public_ips": generic_catalog_item("4.17 Public IP Addresses"),
        "vms": generic_catalog_item("5.3 Virtual Machines"),
        "aks_clusters": {
            "title": "5.4 Azure Kubernetes Service Clusters",
            "description": "AKS inventory is read from Azure Resource Manager and reports the Kubernetes version, SKU tier, provisioning state, and configured node pools. Workload-level Kubernetes state is not collected.",
            "headers": [
                "Cluster",
                "Resource Group",
                "Subscription",
                "Region",
                "Kubernetes Version",
                "SKU Tier",
                "Provisioning State",
                "Node Pools",
            ],
            "mapper": lambda r, s: [
                r.get("name", ""),
                r.get("resourceGroup", ""),
                s.get("display_name", s.get("subscription_id", "")),
                r.get("location", ""),
                (r.get("properties") or {}).get(
                    "currentKubernetesVersion",
                    (r.get("properties") or {}).get("kubernetesVersion", ""),
                ),
                ((r.get("properties") or {}).get("sku") or {}).get("tier", ""),
                (r.get("properties") or {}).get("provisioningState", ""),
                ", ".join(
                    pool.get("name", "")
                    for pool in (r.get("properties") or {}).get("agentPoolProfiles", [])
                    if isinstance(pool, dict) and pool.get("name")
                ),
            ],
        },
        "aro_clusters": {
            "title": "5.5 Azure Red Hat OpenShift Clusters",
            "description": "ARO cluster inventory reports Azure control-plane properties only; it does not inspect OpenShift workloads or in-cluster configuration.",
            "headers": [
                "Cluster",
                "Resource Group",
                "Subscription",
                "Region",
                "OpenShift Version",
                "Provisioning State",
                "API Visibility",
                "Worker Pools",
            ],
            "mapper": lambda r, s: [
                r.get("name", ""),
                r.get("resourceGroup", ""),
                s.get("display_name", s.get("subscription_id", "")),
                r.get("location", ""),
                ((r.get("properties") or {}).get("clusterProfile") or {}).get(
                    "version", ""
                ),
                (r.get("properties") or {}).get("provisioningState", ""),
                ((r.get("properties") or {}).get("apiserverProfile") or {}).get(
                    "visibility", ""
                ),
                ", ".join(
                    pool.get("name", "")
                    for pool in (r.get("properties") or {}).get("workerProfiles", [])
                    if isinstance(pool, dict) and pool.get("name")
                ),
            ],
        },
        "vm_scale_sets": {
            "title": "5.6 Virtual Machine Scale Sets",
            "description": "VM Scale Set inventory reports model-level SKU, capacity, orchestration, upgrade, and provisioning settings exposed by Azure Resource Manager.",
            "headers": [
                "Scale Set",
                "Resource Group",
                "Subscription",
                "Region",
                "VM SKU",
                "Capacity",
                "Orchestration Mode",
                "Upgrade Mode",
                "Provisioning State",
            ],
            "mapper": lambda r, s: [
                r.get("name", ""),
                r.get("resourceGroup", ""),
                s.get("display_name", s.get("subscription_id", "")),
                r.get("location", ""),
                (r.get("sku") or {}).get("name", ""),
                (r.get("sku") or {}).get("capacity", ""),
                (r.get("properties") or {}).get("orchestrationMode", ""),
                ((r.get("properties") or {}).get("upgradePolicy") or {}).get(
                    "mode", ""
                ),
                (r.get("properties") or {}).get("provisioningState", ""),
            ],
        },
        "key_vaults": {

            "title": "7.1 Key Vaults",

            "description": "Key Vault security settings show tenant association, soft-delete protection, purge protection and public network exposure.",

            "headers": [
                "Key Vault",
                "Resource Group",
                "Subscription",
                "Location",
                "Tenant",
                "Soft Delete",
                "Purge Protection",
                "Public Network Access"
            ],

            "mapper": lambda r,s: [
                r.get("name", ""),
                r.get("resourceGroup", ""),
                s.get("display_name", s.get("subscription_id", "")),
                r.get("location", ""),
                (r.get("properties") or {}).get("tenantId", r.get("tenantId", "")),
                (r.get("properties") or {}).get("enableSoftDelete", r.get("enableSoftDelete", "")),
                (r.get("properties") or {}).get("enablePurgeProtection", r.get("enablePurgeProtection", "")),
                public_network_access(r)
            ]

        },
        "apim_services": {

            "title": "5.21 API Management Services",

            "description": "API Management service inventory includes its Azure SKU/capacity, public network access setting and gateway endpoint as exposed by the control plane.",

            "headers": [
                "Service",
                "Resource Group",
                "Subscription",
                "Region",
                "SKU",
                "Capacity",
                "Public Network Access",
                "Virtual Network Type",
                "Gateway URL",
                "Provisioning State"
            ],

            "mapper": lambda r,s: [
                r.get("name", ""),
                r.get("resourceGroup", r.get("resource_group", "")),
                s.get("display_name", s.get("subscription_id", "")),
                r.get("location", ""),
                sku_value(r, "name"),
                sku_value(r, "capacity"),
                public_network_access(r) or "Not reported",
                r.get("virtualNetworkType", (r.get("properties") or {}).get("virtualNetworkType", "")),
                r.get("gatewayUrl", (r.get("properties") or {}).get("gatewayUrl", "")),
                r.get("provisioningState", (r.get("properties") or {}).get("provisioningState", ""))
            ]

        },
        "application_gateways": generic_catalog_item("4.18 Application Gateways"),
        "firewalls": generic_catalog_item("4.19 Azure Firewalls"),
        "firewall_policies": generic_catalog_item("4.20 Firewall Policies"),
        "frontdoor_profiles": generic_catalog_item("4.21 Front Door Profiles"),
        "log_analytics": generic_catalog_item("10.1 Log Analytics Workspaces"),
        "application_insights": generic_catalog_item("10.1 Application Insights"),
        "action_groups": generic_catalog_item("10.1 Monitor Action Groups"),
        "recovery_vaults": generic_catalog_item("5.11 Recovery Services Vaults"),
        "policy_assignments": generic_catalog_item("11.1 Policy Assignments"),
        "policy_definitions": generic_catalog_item("11.2 Policy Definitions"),
        "role_assignments": generic_catalog_item("6.1 Role Assignments"),
        "app_service_plans": {

            "title": "5.10 App Service Plans",

            "description": "App Service Plans define the compute tier, SKU, worker size and capacity used by App Services and Function Apps.",

            "headers": [
                "Plan",
                "Resource Group",
                "Subscription",
                "Location",
                "SKU",
                "Tier",
                "Size",
                "Capacity",
                "Worker Tier",
                "Status"
            ],

            "mapper": lambda r,s: [
                r.get("name", ""),
                r.get("resourceGroup", ""),
                s.get("display_name", s.get("subscription_id", "")),
                r.get("location", ""),
                sku_value(r, "name"),
                sku_value(r, "tier"),
                sku_value(r, "size"),
                sku_value(r, "capacity"),
                r.get("workerTier", ""),
                r.get("status", "")
            ]

        },
        "container_app_environments": generic_catalog_item("5.11 Container App Environments"),
        "container_registries": generic_catalog_item("5.12 Container Registries"),
        "sql_servers": {
            "title": "5.13 SQL Servers",
            "description": (
                "Azure SQL logical-server inventory reports public network "
                "access, Microsoft Entra administrator and Entra-only "
                "authentication settings, and auditing policy and diagnostic "
                "log configuration. Configured audit routing does not prove "
                "that audit events are being received or retained."
            ),
            "headers": [
                "SQL Server",
                "Resource Group",
                "Subscription",
                "Region",
                "Public Network Access",
                "Entra Administrator",
                "Entra-only Authentication",
                "Auditing Policy",
                "Audit Diagnostic Settings",
                "Audit Log Categories",
                "Audit Destinations",
            ],
            "mapper": lambda r, s: [
                r.get("name", ""),
                r.get("resourceGroup", r.get("resource_group", "")),
                s.get("display_name", s.get("subscription_id", "")),
                r.get("location", ""),
                public_network_access(r) or "Not reported",
                (r.get("security_review") or {}).get(
                    "entraAdministrator", "Not reported"
                ),
                (r.get("security_review") or {}).get(
                    "entraOnlyAuthentication", "Not reported"
                ),
                (r.get("security_review") or {}).get(
                    "auditingPolicy", "Not reported"
                ),
                (r.get("security_review") or {}).get(
                    "auditDiagnosticSettings", "Not reported"
                ),
                ", ".join(
                    (r.get("security_review") or {}).get(
                        "auditLogCategories", []
                    )
                    + (r.get("security_review") or {}).get(
                        "auditLogCategoryGroups", []
                    )
                ) or "Not reported",
                ", ".join(
                    (r.get("security_review") or {}).get(
                        "auditLogDestinations", []
                    )
                ) or "Not reported",
            ],
        },
        "sql_databases": generic_catalog_item("Azure SQL Databases"),
        "sql_managed_instances": generic_catalog_item("Azure SQL Managed Instances"),
        "postgres_servers": generic_catalog_item("5.14 PostgreSQL Servers"),
        "mysql_servers": generic_catalog_item("MySQL Flexible Servers"),
        "cosmos_accounts": generic_catalog_item("5.15 Cosmos DB Accounts"),
        "data_factories": generic_catalog_item("5.16 Data Factories"),
        "service_bus": generic_catalog_item("5.17 Service Bus Namespaces"),
        "event_hubs": generic_catalog_item("5.18 Event Hubs Namespaces"),
        "private_dns_zones": generic_catalog_item("4.22 Private DNS Zones"),
        "bastions": generic_catalog_item("4.23 Bastions"),
        "network_interfaces": generic_catalog_item("4.24 Network Interfaces"),
        "network_watchers": generic_catalog_item("4.25 Network Watchers"),
        "activity_log_alerts": generic_catalog_item("10.3 Activity Log Alerts"),
        "metric_alerts": generic_catalog_item("10.4 Metric Alerts"),
        "grafana": generic_catalog_item("10.5 Grafana"),
        "workbooks": generic_catalog_item("10.6 Monitor Workbooks"),
        "logic_apps": generic_catalog_item("5.19 Logic Apps"),
        "eventgrid_topics": generic_catalog_item("5.20 Event Grid Topics")

    }

} 


CATALOG_RESOURCE_GROUPS = {

    "4. Network Design": {
        "private_endpoints",
        "load_balancers",
        "private_dns_zones",
        "bastions",
        "network_interfaces",
        "network_watchers"
    },

    "5. Compute And Storage": {
        "disks",
        "storage_accounts",
        "app_services",
        "function_apps",
        "app_service_plans",
        "container_apps",
        "container_app_environments",
        "container_registries",
        "aks_clusters",
        "aro_clusters",
        "vm_scale_sets",
        "sql_servers",
        "sql_databases",
        "sql_managed_instances",
        "postgres_servers",
        "mysql_servers",
        "cosmos_accounts",
        "data_factories",
        "service_bus",
        "event_hubs",
        "apim_services",
        "logic_apps",
        "eventgrid_topics"
    },

    "9. AI Platform": {"ai_resources"},
    "7. Key Vault": {"key_vaults"},
    "10. Monitor": {"dcrs"}
}


def render_catalog_section(target_chapter):

    allowed_keys = CATALOG_RESOURCE_GROUPS.get(target_chapter, set())

    for chapter, items in RESOURCE_CATALOG.items():

        if chapter != target_chapter:
            items = {
                inventory_key: meta
                for inventory_key, meta in items.items()
                if inventory_key in allowed_keys
            }

        if not items:
            continue

        chapter_has_data = False

        rendered = []

        for inventory_key, meta in items.items():

            rows = collect_rows(
                inventory_key,
                meta["mapper"]
            )

            if len(rows):
                rendered.append(
                    (
                        meta["title"],
                        meta["headers"],
                        rows,
                        meta.get("description", "")
                    )
                )

                chapter_has_data = True

        if not chapter_has_data:
            continue

        for title, headers, rows, description in rendered:

            render_section(
                title,
                headers,
                rows,
                description=description
            )

# Update cover title and control values.
for p in doc.paragraphs:

    if p.text.strip() == "Low Level Design Document":
        p.text = "High Level Design Document"

    elif p.text.strip() == "ESolution":
        p.text = "ESolution"

# Update document-control tables
if len(doc.tables) >= 7:

    t = doc.tables[0]

    if len(t.rows) >= 2:

        cell_text(
            t.rows[1].cells[0],
            "Draft"
        )

        cell_text(
            t.rows[1].cells[1],
            AUTHOR
        )

        cell_text(
            t.rows[1].cells[2],
            datetime.now().strftime(
                "%d/%m/%Y"
            )
        )

    t = doc.tables[1]

    if len(t.rows) >= 2:

        cell_text(
            t.rows[1].cells[0],
            CLASSIFICATION
        )

        cell_text(
            t.rows[1].cells[1],
            "Azure Management Group"
        )

    t = doc.tables[2]

    if len(t.rows) >= 2:

        cell_text(
            t.rows[1].cells[0],
            "Draft"
        )

        cell_text(
            t.rows[1].cells[1],
            REVIEWER
        )

    t = doc.tables[3]

    if len(t.rows) >= 2:

        cell_text(
            t.rows[1].cells[0],
            "Draft"
        )

        cell_text(
            t.rows[1].cells[1],
            APPROVER
        )

    t = doc.tables[5]

    if len(t.rows) >= 2:

        cell_text(
            t.rows[1].cells[0],
            "V 1.0"
        )

        cell_text(
            t.rows[1].cells[1],
            "Initial automated HLD generated from Azure"
        )

        cell_text(
            t.rows[1].cells[2],
            datetime.now().strftime(
                "%d/%m/%Y"
            )
        )

#
# IMPORTANT
#
# Don't remove tables.
# Don't remove XML body nodes.
# Don't remove content after confidentiality.
#
# Instead append generated HLD content
# after a page break.
#

doc.add_page_break()

# Update cover title and control values.
for p in doc.paragraphs:
    if p.text.strip() == "Low Level Design Document":
        p.text = "High Level Design Document"
    elif p.text.strip() == "ESolution":
        p.text = "ESolution"

# The template's first seven tables are document-control tables.
if len(doc.tables) >= 7:
    t = doc.tables[0]
    if len(t.rows) >= 2:
        cell_text(t.rows[1].cells[0], "Draft")
        cell_text(t.rows[1].cells[1], AUTHOR)
        cell_text(t.rows[1].cells[2], datetime.now().strftime("%d/%m/%Y"))
    t = doc.tables[1]
    if len(t.rows) >= 2:
        cell_text(t.rows[1].cells[0], CLASSIFICATION)
        cell_text(t.rows[1].cells[1], "Azure Management Group")
    t = doc.tables[2]
    if len(t.rows) >= 2:
        cell_text(t.rows[1].cells[0], "Draft")
        cell_text(t.rows[1].cells[1], REVIEWER)
        cell_text(t.rows[1].cells[2], "")
    t = doc.tables[3]
    if len(t.rows) >= 2:
        cell_text(t.rows[1].cells[0], "Draft")
        cell_text(t.rows[1].cells[1], APPROVER)
        cell_text(t.rows[1].cells[2], "")
    t = doc.tables[5]
    if len(t.rows) >= 2:
        cell_text(t.rows[1].cells[0], "V 1.0")
        cell_text(t.rows[1].cells[1], "Initial automated HLD generated from Azure")
        cell_text(t.rows[1].cells[2], datetime.now().strftime("%d/%m/%Y"))

# Remove all tables after the confidentiality table. The first seven tables
# belong to document control/confidentiality and are retained.
# while len(doc.tables) > 7:
#     tbl = doc.tables[-1]._element
#     tbl.getparent().remove(tbl)

# Remove any remaining body content after the confidentiality heading again,
# because deleting XML children above also removes old tables.
# Add a generated contents field.
p = doc.add_paragraph()
r = p.add_run("Contents")
r.bold = True
r.font.size = Pt(16)
fld = OxmlElement("w:fldSimple")
fld.set(qn("w:instr"), 'TOC \\o "1-3" \\h \\z \\u')
p._p.append(fld)

# ---------------------------------------------------------------------------
# 1. Introduction
# ---------------------------------------------------------------------------
add_heading("1. Introduction", 1)
add_para(
    "This High Level Architecture document describes the current Azure cloud "
    "foundation discovered beneath the specified Management Group. It provides "
    "an environment-wide view of subscriptions, management-group hierarchy, "
    "networking, compute, storage, identity, security, monitoring, governance "
    "and supporting Azure services."
)
add_para(
    "The document is generated from the Azure control plane using the permissions "
    "of the signed-in identity. It is therefore an inventory-backed HLD rather "
    "than a manually maintained design snapshot."
)
add_heading("1.1 Scope", 2)
add_para(
    f"Management Group in scope: {data.get('management_group_id','')}. "
    f"The generator discovered {len(subs)} subscription(s) beneath this scope."
)
add_para(
    "The scope covers all subscriptions returned by the Management Group hierarchy "
    "query and the Azure resources readable within each subscription."
)
add_heading("1.2 Target Audience", 2)
add_para(
    "This design is intended for Azure infrastructure, network, security, "
    "identity, operations, governance, application and project stakeholders."
)
add_table(
    ["Audience", "Purpose"],
    [
        ["Azure / Cloud Team", "Validate Azure platform architecture and resource inventory."],
        ["Network Team", "Validate VNets, subnets, peering, NSGs, routes, firewalls and ingress."],
        ["Security Team", "Validate Key Vault, Defender, Sentinel, policy and security controls."],
        ["Identity Team", "Validate RBAC and identity-related platform services."],
        ["Operations Team", "Validate monitoring, backup and operational readiness."],
        ["Project / Architecture Team", "Review overall architecture, scope and design assumptions."],
    ]
)
add_caption("Table 1: Intended Audience")

# ---------------------------------------------------------------------------
# 2. Proposed Solution
# ---------------------------------------------------------------------------
add_heading("2. Proposed Solution", 1)
add_para(
    "The Azure estate is represented as a Management Group hierarchy containing "
    "multiple subscriptions. Workloads and shared platform services are separated "
    "by subscription boundaries, while Azure native networking and security "
    "services provide controlled connectivity and centralized governance."
)
add_bullets([
    "Management Group is the governance boundary for subscription-level organization.",
    "Subscriptions provide workload, platform, security and operational isolation.",
    "Virtual networks and subnets provide network segmentation.",
    "VNet peering, routing and security controls determine east-west and north-south traffic paths.",
    "Azure Firewall / Application Gateway / Front Door resources, where present, provide inspection and ingress capabilities.",
    "Azure Monitor, Log Analytics, Application Insights and action groups, where present, provide observability.",
    "Azure Policy assignments and RBAC assignments provide governance and access control."
])

# ---------------------------------------------------------------------------
# 3. Azure Configuration
# ---------------------------------------------------------------------------
add_heading("3. Azure Configuration", 1)
add_heading("3.1 Subscription", 2)
add_para(
    "The following table is generated from the Management Group hierarchy and "
    "therefore represents all discovered subscriptions rather than a fixed project list."
)
rows = []
for s in subs:
    rows.append([
        s.get("management_group",""),
        s.get("management_group_path",""),
        s.get("display_name",s.get("subscription_id","")),
        s.get("subscription_id",""),
        s.get("state",""),
        s.get("cloud","")
    ])
add_table(["Management Group","Hierarchy Path","Subscription","Subscription ID","State","Cloud"], rows)
add_caption("Table 2: Management Group and Subscription Inventory")

add_heading("3.1.1 Azure Region", 3)
regions = unique(
    r.get("location","")
    for s in subs for r in s.get("inventory",{}).get("resource_groups",[])
)
regions += unique(
    r.get("location","")
    for s in subs for r in s.get("inventory",{}).get("vnets",[])
)
regions = unique(regions)
if not regions:
    regions = ["Not available from current read permissions"]
add_table(["Azure Region","Observed Use"], [[r, "Resources discovered in this region"] for r in regions])
add_caption("Table 3: Azure Regions")

add_heading("3.2 Azure Management Groups", 2)
add_para("Management Group hierarchy discovered from Azure:")
add_table(
    ["Management Group Path","Subscription","Subscription ID"],
    [[s.get("management_group_path",""),s.get("display_name",""),s.get("subscription_id","")] for s in subs]
)
add_caption("Table 4: Management Group Structure")
add_text_evidence(
    Path(os.environ.get("MG_STRUCTURE_FILE", "./management_group_structure.txt")),
    "3.2.1 Portal Management Group Structure Evidence",
    level=3
)
add_image_evidence(
    Path(os.environ.get("MG_STRUCTURE_IMAGE", "./management_group_structure.png")),
    "3.2.2 Portal Management Group Screenshot Evidence",
    "Figure: Management Group structure captured from the Azure Portal"
)

add_heading("3.3 Naming Convention", 2)
add_para(
    "The HLD records names exactly as exposed by Azure. Naming standards should "
    "be governed centrally; the observed prefixes below can be used as an input "
    "to the formal naming-standard review."
)
name_patterns = {}
for s in subs:
    for rg in s.get("inventory",{}).get("resource_groups",[]):
        n = rg.get("name","")
        prefix = n.split("-")[0] if n else ""
        if prefix:
            name_patterns[prefix] = name_patterns.get(prefix,0)+1
add_table(["Observed Prefix","Resource Group Count"], [[k,v] for k,v in sorted(name_patterns.items())])
add_caption("Table 5: Observed Naming Prefixes")

add_heading("3.3.1 Azure Components", 3)
add_table(["Component","Observed Count"], [
    ["Resource Groups", sum(len(s.get("inventory",{}).get("resource_groups",[])) for s in subs)],
    ["Virtual Networks", sum(len(s.get("inventory",{}).get("vnets",[])) for s in subs)],
    ["Virtual Machines", sum(len(s.get("inventory",{}).get("vms",[])) for s in subs)],
    ["Managed Disks", sum(len(s.get("inventory",{}).get("disks",[])) for s in subs)],
    ["Storage Accounts", sum(len(s.get("inventory",{}).get("storage_accounts",[])) for s in subs)],
    ["Key Vaults", sum(len(s.get("inventory",{}).get("key_vaults",[])) for s in subs)],
    ["NSGs", sum(len(s.get("inventory",{}).get("nsgs",[])) for s in subs)],
    ["Route Tables", sum(len(s.get("inventory",{}).get("route_tables",[])) for s in subs)],
    ["Public IPs", sum(len(s.get("inventory",{}).get("public_ips",[])) for s in subs)],
    ["Application Gateways", sum(len(s.get("inventory",{}).get("application_gateways",[])) for s in subs)],
    ["Azure Firewalls", sum(len(s.get("inventory",{}).get("firewalls",[])) for s in subs)],
])
add_caption("Table 6: Azure Component Inventory")

add_heading("3.3.2 Azure Region", 3)
add_para("Regions are derived from the resource locations discovered during the collection run.")

add_heading("3.3.3 Environment", 3)
add_para(
    "Environment classification is not inferred from resource names. Where an "
    "environment is encoded in a resource name, the original Azure name is retained "
    "and should be validated against the organization's approved naming standard."
)

add_heading("3.3.4 VM Role", 3)
add_para(
    "VM role is not inferred unless it is explicitly represented by the VM/resource "
    "name. The inventory records VM names, size, OS type, image reference and availability zone."
)

add_heading("3.4 Tags", 2)
tag_counts = {}
tag_values = {}
for s in subs:
    for rg in s.get("inventory",{}).get("resource_groups",[]):
        for k,v in (rg.get("tags") or {}).items():
            tag_counts[k] = tag_counts.get(k,0)+1
            tag_values.setdefault(k,set()).add(str(safe_tag_value(k, v)))
    for vm in s.get("inventory",{}).get("vms",[]):
        for k,v in (vm.get("tags") or {}).items():
            tag_counts[k] = tag_counts.get(k,0)+1
            tag_values.setdefault(k,set()).add(str(safe_tag_value(k, v)))
if tag_counts:
    tag_rows = [[k,tag_counts[k],"; ".join(sorted(tag_values.get(k,set()))[:10])] for k in sorted(tag_counts)]
else:
    tag_rows = [["No tags returned","",""]]
add_table(["Tag Name","Observed Resources","Sample Values"], tag_rows)
add_caption("Table 7: Observed Tagging")

add_heading("3.4.1 Requirement", 3)
add_para("Resources should follow the organization's mandatory tagging standard for ownership, environment, application, cost allocation and operational accountability.")

add_heading("3.4.2 Solution", 3)
add_para("The generator inventories tags exposed by the Azure control plane. Mandatory-tag enforcement should be implemented through Azure Policy at the appropriate Management Group scope.")

add_heading("3.5 Resource Groups", 2)
for s in subs:
    add_heading(f"{s.get('display_name',s.get('subscription_id',''))}", 3)
    rgs = s.get("inventory",{}).get("resource_groups",[])
    if not rgs:
        add_para("No resource groups returned.")
        continue
    add_table(
        ["Resource Group","Location","Provisioning State","Tags"],
        [[r.get("name",""),r.get("location",""),r.get("provisioningState",""),safe_tag_text(r.get("tags") or {})] for r in rgs]
    )
    add_caption(f"Resource Groups: {s.get('display_name','')}")

# ---------------------------------------------------------------------------
# 4. Network
# ---------------------------------------------------------------------------
add_heading("4. Network Design", 1)
add_heading("4.1 Overview", 2)
add_para(
    "Azure virtual networking provides logical segmentation through VNets and subnets. "
    "NSGs, user-defined routes, VNet peering and network security appliances determine "
    "permitted communication paths. The following inventory represents the currently "
    "deployed network topology visible to the caller."
)
add_heading("4.2 High Level Architecture Design", 2)
add_para(
    "The architecture should be interpreted from the discovered network objects: "
    "VNets form network domains, peering provides inter-VNet connectivity where configured, "
    "and route tables/firewalls provide traffic steering and inspection where configured."
)
add_heading("4.3 VNET CONFIGURATION", 2)
vnet_rows = []
for s in subs:
    for v in s.get("inventory",{}).get("vnets",[]):
        prefixes = (v.get("addressSpace") or {}).get("addressPrefixes",[])
        vnet_rows.append([
            v.get("name",""), v.get("resourceGroup",""), v.get("location",""),
            s.get("display_name",""), ", ".join(prefixes),
            str(len(v.get("subnets") or []))
        ])
add_table(["VNet","Resource Group","Location","Subscription","Address Space","Subnets"], vnet_rows)
add_caption("Table 8: VNet Configuration")

add_heading("4.3.1 Subnet Configuration", 3)
sub_rows=[]
for s in subs:
    for sn in s.get("inventory",{}).get("subnets",[]):
        sub_rows.append([
            sn.get("vnet",""), sn.get("name",""), s.get("display_name",""),
            ", ".join(sn.get("address_prefixes") or []),
            resource_name_from_id(sn.get("nsg_id","")),
            resource_name_from_id(sn.get("route_table_id","")),
            sn.get("private_endpoint_network_policies","")
        ])
add_table(["VNet","Subnet","Subscription","Address Prefix","NSG","Route Table","PE Policies"], sub_rows)
add_caption("Table 9: Subnet Configuration")
add_model_notes("4.3.2 VNet Design Notes", model_design_notes.get("vnet_notes", ""))
add_model_notes("4.3.3 Subnet Design Notes", model_design_notes.get("subnet_notes", ""))

add_heading("4.4 VNET Peering", 2)
peer_rows=[]
for s in subs:
    for p in s.get("inventory",{}).get("peerings",[]):
        remote = (p.get("remoteVirtualNetwork") or {}).get("id","")
        peer_rows.append([
            p.get("name",""), s.get("display_name",""),
            p.get("provisioningState",""), remote,
            p.get("peeringState",""), p.get("allowForwardedTraffic",""),
            p.get("allowGatewayTransit",""), p.get("useRemoteGateways","")
        ])
add_table(["Peering","Subscription","State","Remote VNet","Peering State","Forwarded","Gateway Transit","Remote Gateway"], peer_rows)
add_caption("Table 10: VNet Peering")

add_heading("4.5 NETWORK SECURITY GROUPS", 2)
nsg_rows=[]
for s in subs:
    for n in s.get("inventory",{}).get("nsgs",[]):
        rules = n.get("securityRules") or []
        nsg_rows.append([
            n.get("name",""), n.get("resourceGroup",""), s.get("display_name",""),
            n.get("location",""), str(len(rules))
        ])
add_table(["NSG","Resource Group","Subscription","Location","Rules"], nsg_rows)
add_caption("Table 11: Network Security Groups")

add_heading("4.6 ROUTE TABLES", 2)
rt_rows=[]

for s in subs:

    for rt in s.get(
        "inventory",
        {}
    ).get(
        "route_tables",
        []
    ):

        route_details=[]

        for route in rt.get(
            "routes",
            []
        ):

            route_details.append(

                f"{route.get('name','')} | "
                f"{route.get('addressPrefix','')} | "
                f"{route.get('nextHopType','')} | "
                f"{route.get('nextHopIpAddress','')}"

            )

        rt_rows.append([

            rt.get("name",""),

            rt.get("resourceGroup",""),

            s.get("display_name",""),

            rt.get("location",""),

            len(rt.get("routes",[])),

            "; ".join(route_details[:20])

        ])

add_table(
[
 "Route Table",
 "Resource Group",
 "Subscription",
 "Location",
 "Route Count",
 "Configured Routes"
],
rt_rows
)

add_caption(
    "Table 12: Route Tables"
)
add_heading("4.7 Traffic Flows", 2)
add_heading("4.7.1 SUBNET-TO-SUBNET / VNET-to-VNET COMMUNICATION", 3)
add_para("Traffic between subnets is controlled by effective routes and NSGs. Traffic between VNets depends on peering and any configured next-hop/security appliance routing.")
add_heading("4.7.2 Outbound Traffic", 3)
add_para("Outbound traffic behavior should be validated from effective routes and firewall configuration. Public IPs and NAT resources are inventoried below.")
add_heading("4.7.3 Internet Inbound", 3)
add_para("Internet-facing entry points are represented by discovered public IPs, Application Gateways, Azure Firewall public IPs and Front Door profiles where present.")
add_heading("4.7.4 Virtual Network Gateways", 3)
add_para("Virtual Network Gateway resources should be reviewed separately where present. The generic inventory below does not infer VPN/ExpressRoute design when the relevant resource is not returned.")

add_heading("4.8 Azure Firewalls", 2)
fw_rows=[]
for s in subs:
    for fw in s.get("inventory",{}).get("firewalls",[]):
        fw_rows.append([
            fw.get("name",""),fw.get("resourceGroup",""),s.get("display_name",""),
            fw.get("location",""),fw.get("sku",{}).get("tier",""),
            fw.get("sku",{}).get("name",""),
            (fw.get("ipConfigurations") or [{}])[0].get("privateIPAddress","") if fw.get("ipConfigurations") else ""
        ])
add_table(["Firewall","Resource Group","Subscription","Location","Tier","SKU","Private IP"],fw_rows)
add_caption("Table 13: Azure Firewall Inventory")

add_heading("4.9 Azure Application Gateway", 2)
ag_rows=[]
for s in subs:
    for ag in s.get("inventory",{}).get("application_gateways",[]):
        ag_rows.append([
            ag.get("name",""),ag.get("resourceGroup",""),s.get("display_name",""),
            ag.get("location",""),(ag.get("sku") or {}).get("name",""),
            (ag.get("sku") or {}).get("tier",""),
            str(len(ag.get("frontendIPConfigurations") or [])),
            str(len(ag.get("backendAddressPools") or [])),
            str(len(ag.get("httpListeners") or []))
        ])
add_table(["Application Gateway","Resource Group","Subscription","Location","SKU","Tier","Frontends","Backends","Listeners"],ag_rows)
add_caption("Table 14: Application Gateway Inventory")

add_heading("4.10 Azure Front Door", 2)
fd_rows=[]
for s in subs:
    for fd in s.get("inventory",{}).get("frontdoor_profiles",[]):
        fd_rows.append([fd.get("name",""),fd.get("resourceGroup",""),s.get("display_name",""),fd.get("location","")])
add_table(["Front Door Profile","Resource Group","Subscription","Location"],fd_rows)
add_caption("Table 15: Azure Front Door Inventory")

add_heading("4.11 Public IP Addresses", 2)
pip_rows=[]
for s in subs:
    for p in s.get("inventory",{}).get("public_ips",[]):
        pip_rows.append([
            p.get("name",""),p.get("resourceGroup",""),s.get("display_name",""),
            p.get("location",""),p.get("ipAddress",""),
            p.get("sku",{}).get("name",""),p.get("publicIPAllocationMethod","")
        ])
add_table(["Public IP","Resource Group","Subscription","Location","IP Address","SKU","Allocation"],pip_rows)
add_caption("Table 16: Public IP Inventory")

render_catalog_section("4. Network Design")

# ---------------------------------------------------------------------------
# 5. Compute and Storage
# ---------------------------------------------------------------------------
add_heading("5. Compute And Storage", 1)
add_heading("5.1 Operating System Information", 2)
os_counts={}
for s in subs:
    for vm in s.get("inventory",{}).get("vms",[]):
        k=vm.get("os_type") or "Unknown"
        os_counts[k]=os_counts.get(k,0)+1
add_table(["OS Type","VM Count"], [[k,v] for k,v in sorted(os_counts.items())])
add_caption("Table 17: Operating System Summary")

add_heading("5.2 Infrastructure Hardening", 2)
add_para(
    "Hardening should be validated against the organization's approved baseline, "
    "Microsoft Cloud Security Benchmark and/or CIS benchmark. This generated HLD "
    "does not claim compliance merely from the existence of a resource; policy and "
    "security assessment results should be used for compliance evidence."
)

add_heading("5.3 Virtual Machines", 2)
for s in subs:
    vms=s.get("inventory",{}).get("vms",[])
    if not vms: continue
    add_heading(s.get("display_name",s.get("subscription_id","")),3)
    add_table(
                ["VM Name","Resource Group","Location","Size","OS","Image","Zone","Public Access"],
        [[v.get("name",""),v.get("resource_group",""),v.get("location",""),v.get("size",""),
          v.get("os_type",""),((v.get("image") or {}).get("offer","") + " " + (v.get("image") or {}).get("sku","")).strip(),
                    v.get("zone",""),v.get("public_access","Unknown")] for v in vms]
    )
    add_caption(f"Virtual Machines: {s.get('display_name','')}")

render_catalog_section("5. Compute And Storage")
add_model_notes("5.22 API Management Design Notes", model_design_notes.get("apim_notes", ""))

resource_classifications = model_design_notes.get("resource_classifications", [])
architecture_summary = model_design_notes.get("architecture_summary", {})
if any(architecture_summary.values()):
    add_heading("5.23 Agent Architecture Summary", 2)
    for category, heading in (
        ("network_architecture", "Network Architecture"),
        ("security_architecture", "Security Architecture"),
        ("application_delivery", "Application Delivery"),
        ("connectivity", "Connectivity"),
        ("high_availability", "High Availability"),
    ):
        entries = architecture_summary.get(category, [])
        if entries:
            add_heading(heading, 3)
            add_bullets(entries)

agent_findings = model_design_notes.get("findings", [])
well_architected_rows = []
for resource in resource_classifications:
    for assessment in resource.get("well_architected_assessment", []):
        citations = assessment.get("evidence", [])
        observed = [assessment.get("observed", "")]
        observed.extend(
            f"Evidence: {citation.get('attribute', '')}="
            f"{citation.get('value', '')}"
            for citation in citations
        )
        resource_details = [
            resource.get("resource_type", ""),
            resource.get("resource_name", ""),
            resource.get("resource_group", ""),
            resource.get("subscription", ""),
        ]
        well_architected_rows.append([
            [value for value in resource_details if value],
            assessment.get("pillar", ""),
            [value for value in observed if value],
            assessment.get("recommendation", ""),
            assessment.get("required_validation", ""),
            assessment.get("priority", ""),
        ])

if agent_findings or well_architected_rows:
    add_heading("5.24 Agent Findings and Well-Architected Review", 2)
    add_para(
        "Review is based only on collected Azure control-plane evidence. "
        "It is not a formal Well-Architected assessment or compliance score. "
        "Items marked for validation identify information not established by "
        "the current inventory."
    )
    if well_architected_rows:
        add_table(
            [
                "Resource / Scope",
                "Pillar",
                "Observed / Evidence",
                "Recommendation",
                "Required Validation",
                "Review Priority",
            ],
            well_architected_rows,
        )
        add_caption(
            "Table: Resource-Level Well-Architected Review "
            "(VMs, AKS, ARO, VMSS, databases, apps, Functions and APIM)"
        )
    if agent_findings:
        add_heading("Agent Findings", 3)
        add_table(
            ["#", "Finding / Required Review"],
            [
                [index, finding]
                for index, finding in enumerate(agent_findings, start=1)
            ],
        )

detected_nvas = {}
classification_by_resource_id = {
    resource.get("resource_id", "").lower(): resource
    for resource in resource_classifications
    if resource.get("resource_id")
}
vendor_mismatch_warnings = []
for subscription in subs:
    inventory_section = subscription.get("inventory", {})
    for vm in inventory_section.get("vms", []) or []:
        detection = vm.get("vendor_detection") or {}
        vendor = detection.get("vendor", "Unknown")
        agent_classification = classification_by_resource_id.get(
            str(vm.get("id", "")).lower(), {}
        )
        agent_vendor = agent_classification.get("vendor", "")
        vendor_aliases = {
            "f5 networks": "f5",
            "palo alto networks": "palo alto",
            "fortigate": "fortinet",
            "check point software technologies": "check point",
        }
        normalized_vendor = vendor_aliases.get(vendor.lower(), vendor.lower())
        normalized_agent_vendor = vendor_aliases.get(
            agent_vendor.lower(), agent_vendor.lower()
        )
        if (
            vendor not in ("", "Unknown")
            and agent_vendor
            and normalized_vendor != normalized_agent_vendor
        ):
            vendor_mismatch_warnings.append((
                str(vm.get("id", "")).lower(),
                f"{vm.get('name', 'Unnamed VM')}: deterministic Azure evidence "
                f"classifies {vendor}; Foundry Agent classifies {agent_vendor}. "
                "Manual validation is required.",
            ))
        if vendor not in ("", "Unknown"):
            detected_nvas.setdefault(vendor, []).append((subscription, vm, detection))

if detected_nvas:
    add_heading("5.4 Vendor-Specific Network Virtual Appliances", 2)
    add_para(
        "Vendor identification uses Azure image/Marketplace metadata first, with VM names "
        "and tags as medium-confidence evidence. These tables document Azure-side "
        "network associations only; they do not represent appliance-internal configuration."
    )
    for vendor_index, (vendor, records) in enumerate(sorted(detected_nvas.items()), 1):
        add_heading(f"5.4.{vendor_index} {vendor} Azure Topology", 3)
        detection_rows = []
        topology_rows = []
        for subscription, vm, detection in records:
            image = vm.get("image") or {}
            image = image if isinstance(image, dict) else {}
            plan = vm.get("marketplace_plan") or {}
            plan = plan if isinstance(plan, dict) else {}
            tags = vm.get("tags") or {}
            tags = tags if isinstance(tags, dict) else {}
            plan_text = " / ".join(
                str(plan.get(key) or "")
                for key in ("publisher", "product", "name")
                if plan.get(key)
            )
            tags_text = safe_tag_text(tags)
            detection_rows.append([
                vm.get("name", ""),
                subscription.get("display_name", ""),
                detection.get("detected_product", detection.get("product", vendor)),
                detection.get("confidence", ""),
                ", ".join(detection.get("detection_source", []) or []),
                image.get("publisher", ""),
                image.get("offer", ""),
                image.get("sku", ""),
                plan_text,
                tags_text,
            ])

            inventory_section = subscription.get("inventory", {})
            subnet_by_id = {
                str(subnet.get("id") or "").lower(): subnet
                for subnet in inventory_section.get("subnets", []) or []
                if subnet.get("id")
            }
            for nic in vm.get("network_interfaces", []) or [{}]:
                subnet_names = []
                nsg_ids = [nic.get("nsg_id", "")]
                route_table_ids = []
                for subnet_id in nic.get("subnet_ids", []) or []:
                    subnet = subnet_by_id.get(str(subnet_id).lower(), {})
                    subnet_names.append(
                        f"{subnet.get('vnet', '')}/{subnet.get('name', '')}".strip("/")
                        or resource_name_from_id(subnet_id)
                    )
                    nsg_ids.append(subnet.get("nsg_id", ""))
                    route_table_ids.append(subnet.get("route_table_id", ""))
                topology_rows.append([
                    vm.get("name", ""),
                    subscription.get("display_name", ""),
                    nic.get("name", ""),
                    ", ".join(nic.get("private_ips", []) or []),
                    ", ".join(subnet_names),
                    ", ".join(sorted({
                        resource_name_from_id(value) for value in nsg_ids if value
                    })),
                    ", ".join(sorted({
                        resource_name_from_id(value) for value in route_table_ids if value
                    })),
                    ", ".join(
                        resource_name_from_id(value)
                        for value in nic.get("public_ip_ids", []) or []
                    ),
                ])
        add_table(
            [
                "VM Name", "Subscription", "Detected Product", "Confidence",
                "Detection Sources", "Image Publisher", "Image Offer", "Image SKU",
                "Marketplace Plan", "Tags",
            ],
            detection_rows,
        )
        add_caption(f"{vendor} vendor detection evidence")
        vendor_resource_ids = {
            str(vm.get("id", "")).lower() for _, vm, _ in records
        }
        vendor_warnings = [
            warning
            for resource_id, warning in vendor_mismatch_warnings
            if resource_id in vendor_resource_ids
        ]
        if vendor_warnings:
            add_para("Classification mismatch warning: " + " ".join(vendor_warnings))
        add_table(
            [
                "VM Name", "Subscription", "NIC", "Private IPs", "Subnet",
                "NSG", "Route Table", "Public IP",
            ],
            topology_rows,
        )
        add_caption(f"{vendor} Azure-side topology")

# ---------------------------------------------------------------------------
# 6. IAM
# ---------------------------------------------------------------------------
add_heading("6. Identity and Access Management", 1)
add_heading("6.1 Entra ID / RBAC", 2)
rbac_rows=[]
for s in subs:
    ras=s.get("inventory",{}).get("role_assignments",[])
    # Only summarize; principal object IDs are not expanded into names by this
    # read-only generator to avoid unreliable identity-name inference.
    role_counts={}
    for a in ras:
        role=(a.get("roleDefinitionName") or a.get("roleDefinitionId") or "Unknown")
        role_counts[role]=role_counts.get(role,0)+1
    for role,count in sorted(role_counts.items()):
        rbac_rows.append([s.get("display_name",""),role,count])
add_table(["Subscription","Role Definition","Assignment Count"],rbac_rows)
add_caption("Table 20: RBAC Summary")

add_para(
    "RBAC should follow least privilege, separation of duties and privileged identity "
    "management requirements. The generated assignment count is inventory evidence; "
    "it does not by itself establish that an assignment is appropriate."
)

# ---------------------------------------------------------------------------
# 7. Key Vault
# ---------------------------------------------------------------------------
add_heading("7. Key Vault", 1)
render_catalog_section("7. Key Vault")

# ---------------------------------------------------------------------------
# 8. Security
# ---------------------------------------------------------------------------
add_heading("8. Security", 1)
add_heading("8.1 Microsoft Sentinel", 2)
add_para(
    "Sentinel configuration is represented in the HLD through supporting Log Analytics "
    "workspaces and monitoring resources. Detailed connector, analytics-rule and UEBA "
    "configuration should be collected from the Sentinel workspace when those controls "
    "are in scope and readable."
)
add_heading("8.1.1 Microsoft Sentinel Overview", 3)
add_para("The generator inventories Log Analytics workspaces that can serve as Sentinel workspaces.")
add_heading("8.1.2 Data connectors enabled", 3)
add_para("Not asserted by this generic inventory collector.")
add_heading("8.1.3 Workbooks Enabled", 3)
add_para("Not asserted by this generic inventory collector.")
add_heading("8.1.4 UEBA Enabled", 3)
add_para("Not asserted by this generic inventory collector.")
add_heading("8.1.5 Analytical Rules Enabled", 3)
add_para("Not asserted by this generic inventory collector.")
add_heading("8.1.6 Data Retention and Daily Cap", 3)
add_para("Workspace-level settings should be validated against the approved security and logging requirements.")

add_heading("8.2 Microsoft Defender for Cloud", 2)
add_para(
    "Defender plan status is subscription-scoped and should be validated using "
    "Microsoft Defender for Cloud configuration. This generic HLD does not mark a "
    "plan as enabled unless the corresponding control-plane data is collected."
)

if any(
    (subscription.get("inventory") or {}).get("ai_resources")
    for subscription in subs
):
    add_heading("9. AI Platform", 1)
    render_catalog_section("9. AI Platform")

# ---------------------------------------------------------------------------
# 10. Monitor
# ---------------------------------------------------------------------------
add_heading("10. Monitor", 1)
add_heading("10.1 INFRASTRUCTURE MONITOR", 2)
mon_rows=[]
for s in subs:
    for w in s.get("inventory",{}).get("log_analytics",[]):
        mon_rows.append(["Log Analytics",w.get("name",""),w.get("resourceGroup",""),s.get("display_name",""),w.get("location","")])
    for ai in s.get("inventory",{}).get("application_insights",[]):
        mon_rows.append(["Application Insights",ai.get("name",""),ai.get("resourceGroup",""),s.get("display_name",""),ai.get("location","")])
    for ag in s.get("inventory",{}).get("action_groups",[]):
        mon_rows.append(["Action Group",ag.get("name",""),ag.get("resourceGroup",""),s.get("display_name",""),ag.get("location","")])
add_table(["Monitor Resource Type","Name","Resource Group","Subscription","Location"],mon_rows)
add_caption("Table 22: Monitoring Resources")

render_catalog_section("10. Monitor")

add_heading("10.3 Virtual Machines Monitoring", 2)
resource_alert_rules = []
for s in subs:
    # Include direct Metric Alerts plus Log Query and Activity Log Alerts that
    # explicitly target a resource type at subscription/resource-group scope.
    resource_alert_rules.extend(s.get("inventory", {}).get("metric_alerts", []) or [])
    resource_alert_rules.extend(s.get("inventory", {}).get("scheduled_query_alerts", []) or [])
    resource_alert_rules.extend(s.get("inventory", {}).get("activity_log_alerts", []) or [])
vm_rows=[]
for s in subs:
    for vm in s.get("inventory", {}).get("vms", []) or []:
        alert_enabled = resource_alert_status(vm, resource_alert_rules)
        vm_rows.append([vm.get("name", ""), s.get("display_name", ""), alert_enabled])
if vm_rows:
    add_table(["VM Name", "Subscription", "Alert Enabled"], vm_rows)
    add_caption("Table 23: Virtual Machines Monitoring")
vm_coverage = monitoring_coverage("Virtual Machines", [vm for s in subs for vm in (s.get("inventory", {}).get("vms", []) or [])], resource_alert_rules, [])
add_para(f"Total VMs: {vm_coverage['totalResources']}; VMs With applicable alert rules: {vm_coverage['resourcesWithAlerts']}.")

add_heading("10.4 Storage Monitoring", 2)
storage_rows=[]
for s in subs:
    for storage in s.get("inventory", {}).get("storage_accounts", []) or []:
        alert_enabled = resource_alert_status(storage, resource_alert_rules)
        storage_rows.append([storage.get("name", ""), s.get("display_name", ""), alert_enabled])
if storage_rows:
    add_table(["Storage Account", "Subscription", "Alert Enabled"], storage_rows)
    add_caption("Table 24: Storage Monitoring")
storage_coverage = monitoring_coverage("Storage Accounts", [storage for s in subs for storage in (s.get("inventory", {}).get("storage_accounts", []) or [])], resource_alert_rules, [])
add_para(f"Total Storage Accounts: {storage_coverage['totalResources']}; Storage Accounts With applicable alert rules: {storage_coverage['resourcesWithAlerts']}. Coverage: {storage_coverage['alertCoveragePct']}%.")

add_heading("10.5 Azure Networks Monitoring", 2)
network_resource_sets = [
    ("VNets", "vnets"),
    ("NSGs", "nsgs"),
    ("Azure Firewalls", "firewalls"),
    ("Application Gateways", "application_gateways"),
    ("API Management Services", "apim_services"),
]
for label, key in network_resource_sets:
    rows=[]
    for s in subs:
        for resource in s.get("inventory", {}).get(key, []) or []:
            alert_enabled = resource_alert_status(resource, resource_alert_rules)
            rows.append([resource.get("name", ""), s.get("display_name", ""), alert_enabled])
    if rows:
        add_table(["Resource Name", "Subscription", "Alert Enabled"], rows)
        add_caption(f"Table 25: {label} Monitoring")
    network_coverage = monitoring_coverage(label, [resource for s in subs for resource in (s.get("inventory", {}).get(key, []) or [])], resource_alert_rules, [])
    add_para(f"{label} coverage: {network_coverage['totalResources']} total; {network_coverage['resourcesWithAlerts']} with applicable alert rules.")

add_heading("10.6 Load Balancers / Ingress Monitoring", 2)
load_balancer_tables = [
    ("Load Balancers", "load_balancers"),
    ("Front Door Profiles", "frontdoor_profiles"),
]
for label, key in load_balancer_tables:
    rows=[]
    for s in subs:
        for resource in s.get("inventory", {}).get(key, []) or []:
            alert_enabled = resource_alert_status(resource, resource_alert_rules)
            rows.append([resource.get("name", ""), s.get("display_name", ""), alert_enabled])
    if rows:
        add_table(["Resource Name", "Subscription", "Alert Enabled"], rows)
        add_caption(f"Table 26: {label} Monitoring")
    load_coverage = monitoring_coverage(label, [resource for s in subs for resource in (s.get("inventory", {}).get(key, []) or [])], resource_alert_rules, [])
    add_para(f"{label} coverage: {load_coverage['totalResources']} total; {load_coverage['resourcesWithAlerts']} with applicable alert rules.")

add_heading("10.7 Additional Resource Monitoring", 2)
add_para(
    "The following tables show applicable alert rules for other discovered Azure "
    "resources. A rule is listed only when it is directly scoped to the resource, "
    "or explicitly targets that resource type at subscription or resource-group scope."
)
additional_monitoring_resources = [
    ("Resource Groups", "resource_groups"),
    ("Managed Disks", "disks"),
    ("Key Vaults", "key_vaults"),
    ("App Services", "app_services"),
    ("Function Apps", "function_apps"),
    ("App Service Plans", "app_service_plans"),
    ("Container Apps", "container_apps"),
    ("Container App Environments", "container_app_environments"),
    ("Container Registries", "container_registries"),
    ("SQL Servers", "sql_servers"),
    ("PostgreSQL Servers", "postgres_servers"),
    ("Cosmos DB Accounts", "cosmos_accounts"),
    ("Data Factories", "data_factories"),
    ("Service Bus Namespaces", "service_bus"),
    ("Event Hubs Namespaces", "event_hubs"),
    ("Logic Apps", "logic_apps"),
    ("Event Grid Topics", "eventgrid_topics"),
    ("Route Tables", "route_tables"),
    ("Public IP Addresses", "public_ips"),
    ("Private Endpoints", "private_endpoints"),
    ("Private DNS Zones", "private_dns_zones"),
    ("Bastion Hosts", "bastions"),
    ("Network Interfaces", "network_interfaces"),
    ("Network Watchers", "network_watchers"),
    ("Firewall Policies", "firewall_policies"),
    ("Log Analytics Workspaces", "log_analytics"),
    ("Application Insights", "application_insights"),
    ("Recovery Services Vaults", "recovery_vaults"),
    ("AI Services", "ai_resources"),
]
for alert_index, (label, key) in enumerate(additional_monitoring_resources, 1):
    rows = []
    for s in subs:
        for resource in s.get("inventory", {}).get(key, []) or []:
            rows.append([
                resource.get("name", ""),
                resource.get("resourceGroup", resource.get("resource_group", "")),
                s.get("display_name", ""),
                resource_alert_status(resource, resource_alert_rules),
            ])
    if rows:
        add_heading(f"10.7.{alert_index} {label}", 3)
        add_table(["Resource Name", "Resource Group", "Subscription", "Alert Rules"], rows)
        add_caption(f"Monitoring Alert Rules: {label}")

add_heading("10.8 Logs In Azure Monitoring", 2)
log_rows=[]
for s in subs:
    for workspace in s.get("inventory", {}).get("log_analytics", []) or []:
        log_rows.append([workspace.get("name", ""), workspace.get("resourceGroup", ""), s.get("display_name", ""), workspace.get("location", "")])
if log_rows:
    add_table(["Name", "Resource Group", "Subscription", "Location"], log_rows)
    add_caption("Table 27: Log Analytics Workspaces")
appi_rows=[]
for s in subs:
    for app in s.get("inventory", {}).get("application_insights", []) or []:
        appi_rows.append([app.get("name", ""), app.get("resourceGroup", ""), s.get("display_name", ""), app.get("location", "")])
if appi_rows:
    add_table(["Name", "Resource Group", "Subscription", "Location"], appi_rows)
    add_caption("Table 28: Application Insights")
dcr_rows=[]
for s in subs:
    for dcr in s.get("inventory", {}).get("dcrs", []) or []:
        dcr_rows.append([dcr.get("name", ""), dcr.get("resourceGroup", ""), s.get("display_name", ""), dcr.get("location", "")])
if dcr_rows:
    add_table(["Name", "Resource Group", "Subscription", "Location"], dcr_rows)
    add_caption("Table 29: Data Collection Rules")
add_para(f"Total Workspaces: {sum(len(s.get('inventory', {}).get('log_analytics', [])) for s in subs)}; Total Application Insights Components: {sum(len(s.get('inventory', {}).get('application_insights', [])) for s in subs)}; Total Data Collection Rules: {sum(len(s.get('inventory', {}).get('dcrs', [])) for s in subs)}.")

add_heading("Monitoring Alert Inventory", 2)
alert_rows=[]
for s in subs:
    for alert in (
        (s.get("inventory", {}).get("metric_alerts", []) or [])
        + (s.get("inventory", {}).get("activity_log_alerts", []) or [])
        + (s.get("inventory", {}).get("scheduled_query_alerts", []) or [])
    ):
        props = alert.get("properties") or {}
        scopes = alert_scopes(alert)
        monitored = ", ".join([resource_name_from_id(scope) or scope for scope in scopes]) if scopes else (props.get("targetResourceType") or alert.get("targetResourceType") or "")
        alert_rows.append([
            alert_label(alert),
            s.get("display_name", ""),
            alert_field_value(alert, "severity"),
            alert_enabled_value(alert),
            monitored,
            alert_type(alert),
        ])
if alert_rows:
    add_table(["Alert Name", "Subscription", "Severity", "Enabled", "Monitored Resource", "Alert Type"], alert_rows)
    add_caption("Table 30: Monitoring Alert Inventory")

# ---------------------------------------------------------------------------
# 11. Policy
# ---------------------------------------------------------------------------
add_heading("11. Azure Policy", 1)
add_para(
    "Azure Policy provides centralized governance across Management Groups and "
    "subscriptions. Assignments discovered at subscription scope are listed below. "
    "Management Group-level assignments should be reviewed separately when inherited "
    "policy visibility is required."
)
policy_rows=[]
for s in subs:
    for p in s.get("inventory",{}).get("policy_assignments",[]):
        scope=p.get("scope","")
        policy_rows.append([
            p.get("name",""),p.get("displayName",""),s.get("display_name",""),
            scope,p.get("enforcementMode",""),p.get("notScopes","")
        ])
add_table(["Assignment","Display Name","Subscription","Scope","Enforcement","Not Scopes"],policy_rows)
add_caption("Table 23: Azure Policy Assignments")

# ---------------------------------------------------------------------------
# Appendix
# ---------------------------------------------------------------------------
add_heading("12. Appendix", 1)
add_heading("12.1 Subscription Inventory Summary", 2)
summary_rows=[]
for s in subs:
    inv=s.get("inventory",{})
    summary_rows.append([
        s.get("display_name",""),s.get("subscription_id",""),
        len(inv.get("resource_groups",[])),len(inv.get("vnets",[])),
        len(inv.get("vms",[])),len(inv.get("storage_accounts",[])),
        len(inv.get("key_vaults",[])),len(inv.get("apim_services",[])),
        len(inv.get("policy_assignments",[]))
    ])
add_table(["Subscription","ID","RGs","VNets","VMs","Storage","Key Vaults","APIM Services","Policies"],summary_rows)
add_caption("Table 24: Subscription Summary")

if resource_classifications:
    add_heading("12.2 AI-Generated Architecture Classification", 2)
    add_para(
        "Classifications are agent analysis of supplied Azure evidence. Resource "
        "IDs, names, types, locations, and other Azure facts remain authoritative "
        "from the collected inventory. Appliance internals and workload state are "
        "not inferred from Azure control-plane metadata."
    )
    add_table(
        [
            "Resource Type",
            "Name / Resource ID",
            "Vendor / Product",
            "Category / Technology",
            "Probable Role",
            "Environment / Confidence",
            "Evidence",
        ],
        [
            [
                resource.get("azure_resource_type", ""),
                "\n".join(
                    value for value in (
                        resource.get("resource_name", ""),
                        resource.get("resource_id", ""),
                        " / ".join(
                            value for value in (
                                resource.get("resource_group", ""),
                                resource.get("subscription", ""),
                            ) if value
                        ),
                    ) if value
                ),
                " / ".join(
                    value for value in (
                        resource.get("vendor", ""),
                        resource.get("product", ""),
                    ) if value
                ),
                " / ".join(
                    value for value in (
                        resource.get("category", ""),
                        resource.get("technology", ""),
                    ) if value
                ),
                resource.get("probable_role", ""),
                " / ".join(
                    value for value in (
                        resource.get("environment", ""),
                        f"{resource.get('confidence', 0):.2f}",
                    ) if value
                ),
                "; ".join(
                    f"{citation.get('attribute', '')}={citation.get('value', '')} "
                    f"[{citation.get('source', '')}]"
                    for citation in resource.get("evidence", [])
                ),
            ]
            for resource in resource_classifications
        ],
    )
    add_caption("Table 25: AI-Generated Architecture Classification")

add_heading("12.3 Glossary of Terms", 2)
add_table(["Term","Definition"],[
    ["HLD","High Level Design"],
    ["VNet","Azure Virtual Network"],
    ["NSG","Network Security Group"],
    ["UDR","User Defined Route"],
    ["RBAC","Role-Based Access Control"],
    ["MG","Azure Management Group"],
    ["VM","Virtual Machine"],
    ["WAF","Web Application Firewall"],
    ["SIEM","Security Information and Event Management"],
    ["SOAR","Security Orchestration, Automation and Response"],
    ["RPO","Recovery Point Objective"],
    ["RTO","Recovery Time Objective"],
])

# Ask Word to update fields (especially TOC) when opened.
settings = doc.settings.element
update = OxmlElement("w:updateFields")
update.set(qn("w:val"), "true")
settings.append(update)

# Footer note on generated provenance, if the template has a footer.
for section in doc.sections:
    if section.footer.paragraphs:
        fp = section.footer.paragraphs[0]
        fp.text = f"Generated from Azure Management Group {data.get('management_group_id','')} | {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}"
        fp.alignment = WD_ALIGN_PARAGRAPH.CENTER
        for r in fp.runs:
            r.font.size = Pt(7)

doc.save(str(output))
print(f"Generated: {output}")
PY
python_status=$?
if [[ "$python_status" -ne 0 ]]; then
  echo "ERROR: HLD generation failed (Python exit code $python_status)." >&2
  exit "$python_status"
fi

echo
echo "=============================================================="
echo "HLD generation complete."
echo "Output: $OUTPUT"
echo "Subscriptions discovered: $(python3 -c 'import json; print(len(json.load(open("'"$INVENTORY"'"))["subscriptions"]))')"
echo "=============================================================="
echo "Open the DOCX in Microsoft Word and allow the Table of Contents to update."
