# SQL Always On Availability Group POC
## Azure High Availability Alternative to Shared Disk Across Availability Zones

---

# 1. Executive Summary

This Proof of Concept (POC) was conducted to validate a supported Microsoft Azure architecture for SQL Server High Availability across Availability Zones.

The original requirement was to use a Shared Disk between SQL cluster nodes deployed in different Availability Zones.

During the design review, it was identified that Azure Shared Disks are zonal resources and cannot be simultaneously attached to virtual machines located in different Availability Zones.

To address this limitation, a SQL Server Always On Availability Group (AG) solution was implemented using:

- Active Directory Domain Services
- Windows Server Failover Clustering (WSFC)
- SQL Server Always On Availability Groups
- Synchronous Commit Replication

This architecture provides database-level high availability without requiring shared storage.

---

# 2. Objective

Validate:

- Cross-zone SQL Server High Availability
- Synchronous database replication
- Database failover capability
- No dependency on Azure Shared Disks
- Supportability of the architecture in Azure

---

# 3. Environment Overview

| Component | Configuration |
|------------|-------------|
| Domain Controller | VMDC01 |
| Domain Name | poc.local |
| DNS Server | 172.16.0.4 |
| Primary SQL Node | VMDB01 |
| Secondary SQL Node | VMDV02(VMDB02 typo in portal) |
| SQL Edition | SQL Server Developer Edition |
| Availability Zones | Zone 1 and Zone 2 |
| Replication Type | Always On Availability Groups |
| Synchronization Mode | Synchronous Commit |
| Storage Model | Independent Managed Disks |
| Shared Disk | Not Used |

---

# 4. Architecture

```text
                     +------------------+
                     |      VMDC01      |
                     | Active Directory |
                     | DNS Server       |
                     | 172.16.0.4       |
                     +---------+--------+
                               |
                               |
              ---------------------------------
              |                               |
              |                               |
      +-------+--------+            +---------+-------+
      |    VMDB01      |            |     VMDV02      |
      | SQL Server     |            | SQL Server      |
      | Zone 1         |            | Zone 2          |
      | 172.17.1.4     |            | 172.18.1.4      |
      +-------+--------+            +---------+-------+
              |                               |
              +-------------------------------+
                       VNet Peering

                 Windows Failover Cluster

               SQL Always On Availability Group

                     Synchronous Commit
```

---

# 5. Networking Configuration

## Virtual Networks

### VNet-A
```text
VMDB01
172.17.1.4
Zone 1
```

### VNet-B
```text
VMDV02
172.18.1.4
Zone 2
```

### VNet-C
```text
VMDC01
172.16.0.4
```

---

# 6. Connectivity Validation

Connectivity validation was performed using:

```powershell
Test-NetConnection
```

Validated ports:

| Port | Purpose |
|--------|---------|
| 53 | DNS |
| 88 | Kerberos |
| 389 | LDAP |
| 445 | SMB |
| 1433 | SQL Server |
| 5022 | Availability Group Endpoint |

Validation Result:

```text
TcpTestSucceeded = True
```

for all required communication paths.

---

# 7. Active Directory Deployment

## AD DS Installation

Installed:

```powershell
Install-WindowsFeature AD-Domain-Services -IncludeManagementTools
```

Created Forest:

```text
poc.local
```

---

## DNS Configuration

Both SQL Servers were configured to use:

```text
172.16.0.4
```

as the primary DNS Server.

Validation:

```powershell
Resolve-DnsName vmdc01.poc.local
```

Successful.

---

## Domain Join

Domain joined:

```text
VMDB01
VMDV02
```

Validation:

```powershell
(Get-CimInstance Win32_ComputerSystem).PartOfDomain
```

Result:

```text
True
```

---

# 8. SQL Server Deployment

Installed SQL Server Developer Edition on:

```text
VMDB01
VMDV02
```

Installed SQL Server Management Studio (SSMS) on:

```text
VMDB01
```

Remote SQL administration of VMDV02 was performed through SSMS from VMDB01.

---

# 9. SQL Connectivity Validation

Validated SQL connectivity between nodes using:

```powershell
Test-NetConnection <Target-IP> -Port 1433
```

Result:

```text
TcpTestSucceeded = True
```

---

# 10. Failover Clustering

Installed on both SQL nodes:

```powershell
Install-WindowsFeature Failover-Clustering -IncludeManagementTools
```

---

## Cluster Validation

Executed:

```powershell
Test-Cluster -Node vmdb01,vmdv02
```

Result:

```text
ClusterConditionallyApproved
```

Warnings noted:

- Different subnets
- Different DNS suffix search lists
- Software update level differences

No blocking failures were reported.

---

## Cluster Creation

Executed:

```powershell
New-Cluster `
-Name SQLCLUSTER `
-Node vmdb01,vmdv02 `
-NoStorage
```

Result:

```text
Cluster Created Successfully
```

---

# 11. SQL Always On Configuration

Enabled Always On High Availability on:

```text
VMDB01
VMDV02
```

Validation:

```sql
SELECT SERVERPROPERTY('IsHadrEnabled')
```

Result:

```text
1
```

---

# 12. Availability Group Configuration

Availability Group Name:

```text
POCAG
```

Primary Replica:

```text
VMDB01
```

Secondary Replica:

```text
VMDV02
```

Availability Mode:

```text
Synchronous Commit
```

Failover Mode:

```text
Manual Failover (Validated)
```

---

# 13. Database Preparation

Created:

```sql
CREATE DATABASE POCDB
```

Created table:

```sql
dbo.TestData
```

Recovery Model updated:

```sql
ALTER DATABASE POCDB
SET RECOVERY FULL
```

---

# 14. Issues Encountered

## Issue 1

Availability Group State:

```text
DISCONNECTED
NOT_HEALTHY
```

### Investigation

Validated:

- AG endpoints
- SQL connectivity
- Endpoint URLs
- TCP 5022 communication

---

## Issue 2

SQL Service Account

Initial Service Account:

```text
NT Service\MSSQLSERVER
```

Created dedicated AD account:

```text
poc\sqlsvc
```

Updated SQL Service to run under:

```text
poc\sqlsvc
```

Restarted SQL services.

Resolved endpoint authentication issues.

---

## Issue 3

Secondary Replica Readability

Received error:

```text
Msg 976
Target database participating in Availability Group is not accessible.
```

### Root Cause

Replica configured as Secondary and not configured for direct read operations.

### Resolution

Validated through failover testing instead of readable secondary access.

---

# 15. Replication Validation

Inserted records into:

```sql
POCDB.dbo.TestData
```

Observed successful database synchronization between replicas.

Availability Group state changed to:

```text
CONNECTED
HEALTHY
```

---

# 16. Failover Validation

Performed manual failover using:

```text
Availability Group Wizard
```

Result:

Before:

```text
VMDB01 = Primary
VMDV02 = Secondary
```

After:

```text
VMDV02 = Primary
VMDB01 = Secondary
```

Database remained available throughout failover process.

---



![alt text](image.png)

![From VMDV02 secondary DBserver](image-1.png)

![Failover to VMDB01(originally primary)](image-2.png)

![Same rows reflecting in VMDB01 after writes from vmdv02](image-3.png)

# 17. POC Outcome

| Requirement | Result |
|------------|---------|
| Cross-Zone SQL Deployment | Successful |
| Cross-VNet Connectivity | Successful |
| Active Directory Integration | Successful |
| Failover Cluster Deployment | Successful |
| Availability Group Deployment | Successful |
| Synchronous Replication | Successful |
| Database Seeding | Successful |
| Manual Failover | Successful |
| Shared Disk Dependency | Eliminated |

---

# 18. Conclusion

The POC successfully demonstrated a Microsoft-supported architecture for SQL Server High Availability across Azure Availability Zones without using Azure Shared Disks.

The final solution utilized:

- Azure Availability Zones
- VNet Peering

# 19. Quorum Configuration

A Cloud Witness was configured using Azure Storage Account services.

Configuration: 
Provides quorum in a two-node cluster.
Eliminates split-brain scenarios.
Removes dependency on shared disk witness.
Microsoft recommended witness type for Azure deployments.

# 20. Production Readiness Assessment

| Area | Status |
|------|--------|
| Active Directory | ✅ |
| DNS | ✅ |
| WSFC | ✅ |
| SQL Always On AG | ✅ |
| Cross-Zone Replication | ✅ |
| Cloud Witness | ✅ |
| SQL Service Account | ✅ |
| VNet Peering | ✅ |
| Synchronous Commit | ✅ |
| Manual Failover Tested | ✅ |
| Shared Disk Dependency Removed | ✅ |

---

# 21. Formal Architecture Assessment

## 21.1 Executive Assessment

The implemented solution is a valid SQL Server high-availability design. It provided both:

- **Infrastructure-level redundancy:** VM replicas were placed in separate Azure Availability Zones.
- **Database-level redundancy:** SQL Server Always On Availability Groups maintained a synchronized copy of the database on each replica.

The design did not depend on shared storage. Each SQL Server replica used its own local managed disks, while the Availability Group replicated database changes between the replicas.

One important qualification applies: the POC validated **manual failover**, not automatic failover. Automatic failover requires synchronous commit, a WSFC quorum, compatible failover targets, and the Availability Group to be configured with automatic failover. Therefore, the current evidence supports database redundancy and manual failover, but not an automatic-failover claim.

## 21.2 Answers to the Architecture Review Questions

### 1. Redundancy level provided

The solution provided both infrastructure-level and database-level redundancy.

Availability Zones protect against failure of the underlying zone-level infrastructure. Always On AG protects the availability of the database by maintaining a separate database copy on another SQL Server instance.

These are different protection layers and should not be treated as interchangeable.

### 2. Does synchronous AG qualify as database-level redundancy?

Yes. With synchronous commit, the primary replica confirms a transaction only after the secondary has hardened the corresponding log record. This provides a synchronized database copy and can achieve a near-zero data-loss objective during a qualified failover.

The actual RPO is still dependent on replica health, synchronization state, workload, and the point at which failover occurs. An AG that is disconnected or not healthy must not be described as providing synchronous protection at that time.

### 3. Benefits of replicas in different Availability Zones

Cross-zone placement provides protection against a failure affecting one Availability Zone, including zone-level power, cooling, networking, or host/infrastructure incidents. It also reduces the chance that both SQL replicas are lost in the same localized infrastructure event.

Cross-zone placement does not by itself replicate databases, provide automatic failover, or make a single managed disk attachable across zones. SQL Server AG supplies the database replication layer.

### 4. Availability Zones plus AG

The statement is correct with one refinement:

> Availability Zones provide infrastructure placement redundancy. Availability Zones combined with a healthy, synchronized SQL Server Always On AG provide infrastructure resilience plus database-copy redundancy.

The combined design does not automatically guarantee automatic failover. That depends on the AG failover configuration, WSFC quorum, listener and client connectivity, health detection, and operational testing.

### 5. WSFC, FCI, and AG

| Technology | Primary purpose | Storage model | Redundancy scope |
|------------|-----------------|---------------|------------------|
| WSFC | Cluster membership, quorum, health monitoring, and coordinated failover | No shared database storage required by WSFC itself | Cluster control plane |
| SQL Server FCI | Makes one SQL Server instance fail over between cluster nodes | Requires shared storage for the instance databases and SQL Server resources | Instance-level; one active SQL instance at a time |
| SQL Server AG | Replicates selected databases between independent SQL Server instances | Each replica uses independent storage | Database-level; multiple replicas can exist |

WSFC is commonly the clustering foundation for both FCI and AG. An AG does not require an FCI or shared data disk, although it does require WSFC for traditional Windows-based SQL Server AG deployments.

### 6. Architecture comparison

| Characteristic | Architecture A: Cross-zone AG | Architecture B: Single-zone FCI |
|---------------|------------------------------|---------------------------------|
| SQL design | Independent SQL instances with database replicas | One SQL instance that moves between nodes |
| Storage | Independent disks per node | Shared disk required by the FCI |
| Database copy | Separate synchronized database copy | Same database files on shared storage |
| Zone protection | Yes, when nodes are in separate zones | No, if both nodes and shared disk are in one zone |
| Shared disk dependency | None | Required |
| Read scale-out | Possible with readable secondary configuration | Not provided by the passive FCI node |
| Operational complexity | Database seeding, AG endpoints, listeners, and replica monitoring | Shared storage, cluster resources, and instance failover |
| Main failure domain | Database replication and replica health | Shared storage and the single zone remain critical dependencies |

### 7. Capability comparison

| Capability | Architecture A: Cross-zone AG | Architecture B: Single-zone FCI |
|------------|------------------------------|-------------------------------|
| VM redundancy | Yes | Yes, within the same zone |
| Database redundancy | Yes, through database replicas | No independent database copy; the files are shared |
| Storage redundancy | Independent storage per replica, but each disk SKU has its own durability characteristics | Shared disk is a common dependency; disk redundancy depends on its SKU and configuration |
| Zone failure protection | Yes | No, if all resources are in one zone |
| Automatic failover | Possible, but not shown by this POC and not enabled by manual failover configuration | Possible when WSFC, SQL FCI, and storage are healthy |
| Lowest RPO | Near-zero with healthy synchronous commit | Typically zero for a shared disk because both nodes use the same files |
| Lowest RTO | Usually higher than FCI because a database replica must be made primary and client connections must redirect | Often lower for an instance failover, subject to recovery and storage health |

The RPO and RTO outcomes are workload- and configuration-dependent. No architecture should be assigned a guaranteed RPO or RTO without measured failover tests and documented service-level targets.

### 8. Why an architect might prefer single-zone FCI

A Database Architect may prefer FCI when the priority is instance-level compatibility and simple database behavior. FCI presents one SQL Server instance and one database set, so applications generally do not need AG-aware database routing, database seeding, or separate replica-read decisions. It also avoids maintaining two independently stored database copies.

FCI can provide very fast failover for an instance failure, and it supports workloads or SQL Server features that may be difficult to operate with AG. However, the single-zone model trades away zone-failure protection and retains the shared disk as a common dependency.

### 9. Was the implemented architecture wrong?

No. It was a different architecture with different trade-offs. The cross-zone AG design is appropriate when zone failure protection, independent storage, and database-level redundancy are important. The single-zone FCI design may be preferred when instance compatibility, shared-file semantics, or lower operational change are more important.

The original shared disk could not be attached to VMDB02 because the disk was zonal and located in Zone 1. Azure Shared Disks do not turn a zonal disk into a cross-zone storage resource. A ZRS disk option, where supported for the selected disk type, region, and deployment scenario, would be a separate storage design and should not be assumed to make every shared-disk architecture valid across zones.

## 21.3 Management Summary

The POC implemented two SQL Server virtual machines in separate Azure Availability Zones and configured SQL Server Always On Availability Groups with synchronous commit. This created an independent, synchronized database copy on each VM and removed the dependency on a shared disk.

The result was redundancy at two layers: Azure infrastructure placement through Availability Zones and database protection through Always On AG. A single-zone shared managed disk could not be attached to both VMs because it was a Zone 1 resource, while VMDB02 was in Zone 2.

The Database Architect's proposed FCI model is also valid, but it optimizes for a different objective. FCI can provide a familiar single SQL instance and potentially faster instance failover, but a single-zone deployment does not protect against loss of that zone and the shared disk remains a common dependency.

| Decision factor | Cross-zone AG | Single-zone FCI |
|----------------|---------------|-----------------|
| Zone failure protection | Stronger | Not provided |
| Database copy redundancy | Yes | No independent copy |
| Shared storage dependency | No | Yes |
| Application and SQL instance compatibility | Requires AG-aware design and testing | Often simpler |
| Operational model | Replicas, endpoints, seeding, and AG monitoring | Clustered instance and shared storage |
| Best fit | Resilience across zones and database-level protection | Instance compatibility and fast local failover |

The recommended next validation is to configure and test automatic AG failover, measure RPO and RTO under representative load, validate listener and client reconnection behavior, and document backup and disaster-recovery protection separately from local high availability.

