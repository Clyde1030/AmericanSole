# AWS Architecture

> You are a senior cloud architect helping American Sole build their AWS infrastructure.

---

## 1. First Principles: What You're Really Building

| Layer | Components |
|-------|-----------|
| **Application** | UI for production input, APIs for container tracking, internal tools |
| **Data** | Transactional DB (Postgres), file/object storage (S3), data pipelines (Airflow, Glue) |
| **Compute** | ECS for services & APIs, Airflow for orchestration |
| **Governance** | IAM, logging, monitoring, cost control |

---

## 2. High-Level Architecture (Mental Model)

```text
[ Users / Internal Staff ]
            |
        (UI / API)
            |
        ECS (Fargate)
            |
   +--------+--------+
   |                  |
 RDS (Postgres)     S3 (raw + processed data)
   |                  |
        Airflow (ECS)
            |
      Glue / ETL Jobs
            |
     Analytics / Reporting
```

---

## 3. VPC Design (Foundation)

**Structure:**
- 1 VPC per environment (`dev`, `staging`, `prod` — eventually separate accounts)

**Subnets:**

| Subnet Type | Purpose |
|-------------|---------|
| **Public** | Load balancer (ALB) |
| **Private** | ECS services, Airflow, RDS |
| **Isolated** (optional but ideal) | RDS only (no outbound internet) |

**VPC Endpoints:**
- S3
- Glue
- ALB: Route to ECS API
---

## 4. RDS (Postgres) — Core System of Record

### Design

- **Engine:** PostgreSQL
- **Multi-AZ:** Yes (for production)
- **Storage:** GP3

### Usage

Transactional data including:
- Purchase orders
- Work orders
- Production logs
- Inventory

### Must-Have

- Automated backups
- Read replica (later, for analytics separation)
- Parameter tuning (connections for Airflow + APIs)

### Concurrency Model

**PostgreSQL MVCC (Multi-Version Concurrency Control):**
- Default behavior
- Allows multiple concurrent writes
- No blocking unless updating same row

**Proper Transaction Design (Key):**

Avoid long-held locks:

```sql
-- BAD: long UI delay inside transaction
BEGIN;
SELECT * FROM production WHERE id = 1 FOR UPDATE;
-- long UI delay
UPDATE ...
COMMIT;
```

Instead, use:
- Short transactions
- Insert-heavy patterns (append, not update)

### Row-Level Locking Strategy

Only conflicts if two users edit the same record at the same time.

**Solution:**
- Add `updated_at` column
- Use optimistic locking (version column)

### Connection Pooling (Very Important)

- **Use:** pgBouncer or RDS Proxy
- **Why:** Prevent connection exhaustion from ECS services and Airflow

---

## 5. ECS (Fargate) — Compute Backbone

### Services

| Service | Responsibilities |
|---------|-----------------|
| **Backend API** | Container API calls and ingestion, DB transactions, business logic |
| **Frontend UI** | React app (served via ECS or S3 + CloudFront) |
| **Airflow** (if self-managed) | Scheduler + workers: ETL jobs, data sync tasks, automation |

### Why ECS Fargate

- No EC2 management
- Scales automatically
- Clean separation of services

---

## 6. Airflow — Orchestration Brain

**Deployment:** Airflow on ECS (containerized)

**Responsibilities:**
- Schedule jobs:
  - Daily production ingestion
  - Data cleanup
  - API pulls (container tracking)
- Trigger ETL pipelines
- Manage dependencies

---

## 7. S3 — Data Lake + Storage Backbone

### Buckets

| Bucket | Purpose |
|--------|---------|
| `raw-data` | API responses (containers), CSV uploads |
| `processed-data` | Cleaned and normalized datasets |
| `logs` | Application and service logs |
| `backups` | Database and archive backups |

### S3 Structure

```text
s3://american-sole-data/
  raw/
    container_api/
    production_input/
    external_sources/
  staging/
    cleaned/
    normalized/
  curated/
    analytics_ready/
  logs/
  backups/
```

---

## 8. Glue — Future-Proofing Analytics

> Not required Day 1, but very useful later.

**Use Cases:**
- Transform raw S3 data into structured datasets
- Build data catalog
- Query with Athena

```text
Airflow --> dumps raw --> S3
       --> triggers Glue job
       --> writes curated data
       --> query via Athena
```

### Data Flow (Concrete)

**1. Production Input (UI)**
```text
User --> ECS API --> RDS
                 --> (optional) S3 raw snapshot
```

**2. Container API Pipeline**
```text
Airflow --> call external API
        --> store raw JSON in S3
        --> normalize --> RDS or S3 (staging)
```

**3. Analytics Pipeline**
```text
S3 raw --> Glue --> curated S3 --> Athena / dashboards
```

---

## 9. IAM — Security Model (Critical)

> Design this early to avoid chaos.

### Roles per Service

| Role | Permissions |
|------|-------------|
| **ECS Task Role (API)** | RDS access, minimal S3 write |
| **ECS Task Role (Airflow)** | S3 full access (data buckets), trigger Glue |
| **Glue Role** | S3 read/write, catalog access |

**Principles:**
- Least privilege always
- No hardcoded credentials anywhere

---

## 10. CloudWatch — Observability

| Category | What to Monitor |
|----------|----------------|
| **Logs** | ECS container logs, Airflow logs, application logs |
| **Metrics** | CPU / memory, DB connections, API latency |
| **Alerts** | Failed Airflow DAGs, RDS CPU spikes, ECS service crashes |

---

## 11. Cost & Billing Strategy

**Tools:**
- AWS Cost Explorer
- Budgets + alerts

**Tag everything:**

| Tag | Values |
|-----|--------|
| `Project` | AmericanSole |
| `Env` | dev / prod |
| `Service` | airflow / api / db |
| `Owner` | your_name |

---

## 12. AWS Organizations (Bonus but Smart)

**Structure:**
- Root
  - Dev Account
  - Prod Account

**Why:**
- Isolation (huge for safety)
- Billing separation
- Permission boundaries

---

## 13. Security Strategy (Non-Negotiable)

**Network:**
- No public DB
- Private ECS
- Security groups tightly scoped

**Data:**
- Encrypt RDS and S3
- Secrets in AWS Secrets Manager
    - DB credentials
    - API keys
---

## Purpose

The main purpose of this cloud system is to centralize internal workflows:
- API calls for container information
- User interface for entering daily production volume
- Relational database transactions, backups, and record entry
- Automating and scheduling internal data entry tasks
- Control and security of the infrastructure

---

## Implementation Phases

### Phase 1 — Core Platform (MVP)

> **Goal:** "System works end-to-end for internal operations"

#### Infrastructure

- VPC (public + private subnets)
- Security Groups
- Internet Gateway

#### Core Services

| Service | Configuration |
|---------|--------------|
| **ECS (Fargate)** | API service (backend) |
| **Amazon RDS (Postgres)** | Single instance, automated backups ON |
| **S3 (Basic)** | One bucket: raw data, uploads |

#### Features Delivered

- UI --> API --> DB flow works
- Users can enter production volume and store records

#### Minimal IAM

- ECS task role with basic access to RDS and S3

#### Monitoring

- Amazon CloudWatch logs only

#### Do NOT Add Yet

- Airflow
- Glue
- Multi-account
- Complex pipelines

---

### Phase 2 — Automation & Data Pipeline

> **Goal:** "System becomes automated + scalable"

#### Additions

| # | Component | Details |
|---|-----------|---------|
| 1 | **Airflow on ECS** | Scheduler, workers, web UI |
| 2 | **S3 Structured Data Lake** | Move from flat `/bucket` to `/raw`, `/staging`, `/curated` |
| 3 | **AWS Glue** | ETL jobs: raw --> cleaned --> analytics-ready |
| 4 | **Data Pipelines** | Airflow DAGs: container API ingestion, daily production aggregation, data cleanup |
| 5 | **RDS Improvements** | Read replica (optional), Amazon RDS Proxy |
| 6 | **IAM Maturity** | Separate roles for ECS API, Airflow, Glue |
| 7 | **Monitoring Upgrade** | CloudWatch alerts: Airflow failures, ECS crashes, DB CPU spikes |

#### Features Delivered

- Automated data ingestion
- Scheduled workflows
- Clean data available in S3

---

### Phase 3 — Production-Grade & Analytics

> **Goal:** "Robust, secure, and insight-driven system"

#### Infrastructure Maturity

| # | Component | Details |
|---|-----------|---------|
| 1 | **AWS Organizations** (optional but recommended) | Separate dev and prod accounts |
| 2 | **Security Hardening** | Secrets Manager, encryption everywhere, tight IAM policies |
| 3 | **Analytics Layer** | Glue Catalog, Athena queries |
| 4 | **Observability Upgrade** | Dashboards, SLA monitoring, cost tracking via AWS Cost Explorer |
| 5 | **Performance Optimization** | RDS tuning, partitioned S3 data (Parquet) |
| 6 | **Cost Optimization** | Spot tasks (ECS), lifecycle rules (S3) |

#### Features Delivered

- Business analytics ready
- Scalable pipelines
- Production-grade reliability

---

## Output

- A flowchart of the architecture
- Terraform script to build the architecture (after plan is finalized)
