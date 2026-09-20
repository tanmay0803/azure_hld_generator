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
#   REUSE_INVENTORY="1" to skip Azure discovery and reuse inventory.json
#   MG_STRUCTURE_FILE="./management_group_structure.txt" for portal-pasted evidence
#   MG_STRUCTURE_IMAGE="./management_group_structure.png" for portal screenshot evidence
#
# Notes:
#   - Read-only discovery only. No Azure resources are changed.
#   - The generated document reports what Azure exposes to the current identity.
#   - Resources for which the caller lacks read permission are recorded as
#     "Not accessible" rather than invented.
# ==============================================================================

set -uo pipefail

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

subs = sorted(subscriptions.values(), key=lambda x: x["subscription_id"])

def az_for_sub(sid, args, default=None):
    return run(["az"] + args + ["--subscription", sid, "-o", "json"], default)


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

    result = run(
        [
            "az",
            "monitor",
            "diagnostic-settings",
            "list",
            "--resource",
            resource_id,
            "--subscription",
            subscription_id,
            "-o",
            "json"
        ],
        []
    )

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
            "destinations": sorted(set(destinations))
        })

    if settings:
        return settings

    return [{
        "resourceId": resource_id,
        "resourceName": resource_name,
        "resourceType": "",
        "diagnosticsEnabled": False,
        "destinations": []
    }]


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
    logic_apps = az_for_sub(
        sid,
        ["logic","workflow","list"],
        []
    )
    eventgrid_topics = az_for_sub(
        sid,
        ["eventgrid","topic","list"],
        []
    )


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
        osdisk = (vm.get("storageProfile") or {}).get("osDisk") or {}
        vm_nics = (vm.get("networkProfile") or {}).get("networkInterfaces") or []
        public_access = "Unknown"
        if vm_nics:
            public_access = "Disabled"
            for vm_nic in vm_nics:
                nic = nic_by_id.get((vm_nic.get("id") or "").lower(), {})
                for ip_config in nic.get("ipConfigurations", []) or []:
                    public_ip = ip_config.get("publicIPAddress") or {}
                    if public_ip.get("id") or public_ip.get("ipAddress"):
                        public_access = "Enabled"
                        break
                if public_access == "Enabled":
                    break
        vm_rows.append({
            "name": vm.get("name",""),
            "resource_group": vm.get("resourceGroup",""),
            "location": vm.get("location",""),
            "size": (vm.get("hardwareProfile") or {}).get("vmSize",""),
            "os_type": ((vm.get("storageProfile") or {}).get("osDisk") or {}).get("osType",""),
            "image": ((vm.get("storageProfile") or {}).get("imageReference") or {}),
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
    for resource_set in (
        vm_rows,
        storage,
        vnets,
        nsgs,
        firewalls,
        appgws,
        load_balancers,
        afd_profiles,
    ):
        for resource in resource_set or []:
            resource_id = resource.get("id") or resource.get("resourceId")
            if resource_id:
                diagnostic_settings.extend(collect_diagnostic_settings(resource_id, sid))

    s["inventory"] = {
        "resource_groups": rgs,
        "vnets": vnets,
        "subnets": subnet_rows,
        "nsgs": nsgs,
        "route_tables": rts,
        "peerings": peerings,
        "public_ips": pips,
        "vms": vm_rows,
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
        "postgres_servers": postgres_servers,
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

echo "Generating Word HLD..."

echo "Checking python-docx..."

python3 -c "import docx" >/dev/null 2>&1 || {

    echo "Installing python-docx..."

    python3 -m pip install --user python-docx

}

export TEMPLATE OUTPUT INVENTORY
export MG_STRUCTURE_FILE="${MG_STRUCTURE_FILE:-./management_group_structure.txt}"
export MG_STRUCTURE_IMAGE="${MG_STRUCTURE_IMAGE:-./management_group_structure.png}"
python3 - <<'PY'
import json, os, re, copy, sys
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
    condition = properties.get("condition") or {}
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
    return {str(item).lower() for item in target_types if item}

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
        or ""
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
    type_matches = (
        resource_type in target_types
        or any(
            resource_type.endswith("/" + target_type)
            for target_type in target_types
        )
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

            if expected_rg_scope and scope == expected_rg_scope:
                return True

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

            if scope == expected_subscription_scope:
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

    return {

        "title": title,

        "description": description or (
            f"This section inventories {title.split('.', 1)[-1].strip().lower()} "
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

            "description": "Logic Apps implement workflow automation and are reported with their resource group, location and current state.",

            "headers": [

                "Name",
                "Resource Group",
                "Location",
                "State"

            ],

            "mapper": lambda r,s: [

                r.get("name",""),

                r.get("resourceGroup",""),

                r.get("location",""),

                r.get("state","")

            ]

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
        "sql_servers": generic_catalog_item("5.13 SQL Servers"),
        "postgres_servers": generic_catalog_item("5.14 PostgreSQL Servers"),
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
        "sql_servers",
        "postgres_servers",
        "cosmos_accounts",
        "data_factories",
        "service_bus",
        "event_hubs",
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
            tag_values.setdefault(k,set()).add(str(v))
    for vm in s.get("inventory",{}).get("vms",[]):
        for k,v in (vm.get("tags") or {}).items():
            tag_counts[k] = tag_counts.get(k,0)+1
            tag_values.setdefault(k,set()).add(str(v))
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
        [[r.get("name",""),r.get("location",""),r.get("provisioningState",""),"; ".join(f"{k}={v}" for k,v in (r.get("tags") or {}).items())] for r in rgs]
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
        len(inv.get("key_vaults",[])),len(inv.get("policy_assignments",[]))
    ])
add_table(["Subscription","ID","RGs","VNets","VMs","Storage","Key Vaults","Policies"],summary_rows)
add_caption("Table 24: Subscription Summary")

add_heading("12.2 Glossary of Terms", 2)
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

echo
echo "=============================================================="
echo "HLD generation complete."
echo "Output: $OUTPUT"
echo "Subscriptions discovered: $(python3 -c 'import json; print(len(json.load(open("'"$INVENTORY"'"))["subscriptions"]))')"
echo "=============================================================="
echo "Open the DOCX in Microsoft Word and allow the Table of Contents to update."



