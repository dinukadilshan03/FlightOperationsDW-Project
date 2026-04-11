# ✈️ Flight Operations Data Warehouse Project

A SQL Server Integration Services (SSIS) solution that builds a fully-populated data warehouse for flight operations analytics. The pipeline ingests raw flat-file and relational source data, loads it into a staging area, and then transforms and loads it into a star-schema data warehouse.

---

## 📋 Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Data Sources](#data-sources)
- [SSIS Packages](#ssis-packages)
- [Data Warehouse Schema](#data-warehouse-schema)
- [Accumulating Snapshot Fact](#accumulating-snapshot-fact)
- [Prerequisites](#prerequisites)
- [Setup & Configuration](#setup--configuration)
- [Running the ETL Pipeline](#running-the-etl-pipeline)
- [Project Structure](#project-structure)
- [License](#license)

---

## Overview

The **Flight Operations Data Warehouse** aggregates data from multiple operational sources — flight schedules, ticket sales, aircraft details, crew assignments, maintenance records, and more — into a single analytical data store. This enables business intelligence reporting on:

- Flight on-time performance and delay analysis
- Maintenance cost and downtime tracking
- Crew utilisation and assignment history
- Ticket sales and passenger revenue analytics
- Accumulating snapshot tracking for ticket transaction lifecycle

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  Source Systems                      │
│                                                     │
│  Flat Files (CSV/TXT)   FlightTicketing_SourceDB    │
│  ─────────────────────  ────────────────────────    │
│  aircraft.csv           passengers                  │
│  airports.csv           tickets                     │
│  flights.csv            payments                    │
│  crew.csv               flight_crew                 │
│  engineers.txt                                      │
│  maintenance_records.txt                            │
└────────────────────┬────────────────────────────────┘
                     │  Package 1: Flight_Load_Staging
                     ▼
┌─────────────────────────────────────────────────────┐
│              FlightOps_Staging (SQL Server)          │
│  Staging tables mirror source structure             │
│  (truncated and reloaded on each run)               │
└────────────────────┬────────────────────────────────┘
                     │  Package 2: Flight_Load_DW
                     ▼
┌─────────────────────────────────────────────────────┐
│          FlightOperationsDW (SQL Server)             │
│                                                     │
│  Dimensions           Facts                         │
│  ─────────────────    ─────────────────────────     │
│  DimAircraft          FactMaintenance               │
│  DimAirport           FactTicketSales               │
│  DimEngineer            (accumulating snapshot)     │
│  DimCrew                                            │
│  DimDate                                            │
└─────────────────────────────────────────────────────┘
                     │  Package 3: Update_Fact_Completion
                     ▼
           Update accumulating snapshot
           columns in FactTicketSales
```

---

## Data Sources

All flat files are stored under `FlightOperationsDW-Project/dataSources/`.

| File | Format | Records | Key Columns |
|------|--------|---------|-------------|
| `aircraft.csv` | CSV | ~19 | `aircraft_id`, `model`, `manufacturer`, `capacity`, `acquisition_date`, `current_status` |
| `airports.csv` | CSV | ~15 | `airport_id`, `iata_code`, `airport_name`, `city`, `country`, `region` |
| `flights.csv` | CSV | ~731 | `flight_id`, `flight_number`, `aircraft_id`, `departure_airport_id`, `arrival_airport_id`, `scheduled_departure`, `scheduled_arrival`, `actual_departure`, `actual_arrival`, `delay_minutes`, `flight_status` |
| `crew.csv` | CSV | ~80 | `crew_id`, `name`, `role`, `hire_date`, `base_airport_id` |
| `engineers.txt` | Pipe-delimited | — | `engineer_id`, `name`, `certification_level`, `hire_date` |
| `maintenance_records.txt` | Pipe-delimited | ~197 | `maintenance_id`, `aircraft_id`, `engineer_id`, `maintenance_type`, `maintenance_date`, `cost`, `downtime_hours` |
| `flight_crew.csv` | CSV | — | `flight_id`, `crew_id`, `assignment_role` |
| `FactCompletionUpdates.csv` | CSV | — | Transaction ID, completion timestamp |

Relational source data (passengers, tickets, payments) is read directly from **FlightTicketing_SourceDB** on the SQL Server instance.

---

## SSIS Packages

### 1. `Flight_Load_Staging.dtsx` — Extract to Staging

Loads all source data into the staging database. Each entity follows the same pattern:

1. **Truncate** the staging table (Execute SQL Task)
2. **Extract & Load** the source data (Data Flow Task)

| Task Name | Source |
|-----------|--------|
| Extract Aircraft Data to Staging | `aircraft.csv` |
| Extract Airports Data to Staging | `airports.csv` |
| Extract Engineer Data to Staging | `engineers.txt` |
| Extract Flights Data to Staging | `flights.csv` |
| Extract Maintenance Records Data to Staging | `maintenance_records.txt` |
| Extract Passenger Data to Staging | FlightTicketing_SourceDB |
| Extract Payment Data to Staging | FlightTicketing_SourceDB |
| Extract Ticket Data to Staging | FlightTicketing_SourceDB |

---

### 2. `Flight_Load_DW.dtsx` — Transform & Load to Data Warehouse

Reads from the staging database, applies transformations (lookups, derived columns, SCD logic), and loads dimension and fact tables in the data warehouse.

**Pre-load steps:**
- Truncate `FactMaintenance`
- Truncate `FactTicketSales`

| Task Name | Target |
|-----------|--------|
| Transform and Load Aircraft Data | DimAircraft |
| Transform and Load Airport Data | DimAirport |
| Transform and Load Engineer Data | DimEngineer |
| Transform and Load Flight Data | DimFlight / related facts |
| Transform and Load Maintenance Data | FactMaintenance |
| Transform and Load Passenger Data | DimPassenger |
| Transform and Load Ticket Sales Data | FactTicketSales |

A `CurrentDate` package parameter is used during date dimension lookups.

---

### 3. `Update_Fact_Completion.dtsx` — Accumulating Snapshot Update

Reads transaction completion timestamps from `FactCompletionUpdates.csv` and updates the corresponding accumulating snapshot columns in `FactTicketSales`.

---

## Data Warehouse Schema

### Dimension Tables

| Table | Description |
|-------|-------------|
| `DimAircraft` | Aircraft model, manufacturer, capacity, status |
| `DimAirport` | IATA code, airport name, city, country, region |
| `DimEngineer` | Engineer name, certification level |
| `DimCrew` | Crew name, role, base airport |
| `DimDate` | Calendar date attributes |

### Fact Tables

| Table | Grain | Key Measures |
|-------|-------|-------------|
| `FactMaintenance` | One row per maintenance event | `cost`, `downtime_hours` |
| `FactTicketSales` | One row per ticket transaction | Ticket revenue, passenger counts, accumulating timestamps |

---

## Accumulating Snapshot Fact

`FactTicketSales` implements an **accumulating snapshot** pattern to track the lifecycle of a ticket transaction from creation to completion.

The following columns were added via `Accumilating fact.sql`:

```sql
ALTER TABLE FactTicketSales
ADD
    accm_txn_create_time   DATETIME,
    accm_txn_complete_time DATETIME,
    txn_process_time_hours FLOAT;
```

| Column | Description |
|--------|-------------|
| `accm_txn_create_time` | Timestamp when the ticket transaction was created |
| `accm_txn_complete_time` | Timestamp when the transaction was completed |
| `txn_process_time_hours` | Calculated duration between creation and completion |

The `Update_Fact_Completion.dtsx` package is run as a separate step to back-fill `accm_txn_complete_time` once completion data becomes available in `FactCompletionUpdates.csv`.

---

## Prerequisites

| Requirement | Version |
|-------------|---------|
| SQL Server | 2019 / 2022 |
| SQL Server Integration Services (SSIS) | Matching SQL Server version |
| Visual Studio with SSDT | 2019 or later (project version 17.0) |
| SQL Server Management Studio (SSMS) | Any recent version |

Three SQL Server databases must exist before running the packages:

- **FlightTicketing_SourceDB** — operational source database
- **FlightOps_Staging** — staging database (tables are truncated on each run)
- **FlightOperationsDW** — target data warehouse database

---

## Setup & Configuration

### 1. Restore / Create Databases

Create the three required databases on your SQL Server instance.

### 2. Run the accumulating snapshot DDL

Execute `Accumilating fact.sql` against `FlightOperationsDW` to add the accumulating snapshot columns to `FactTicketSales`:

```sql
-- Run against FlightOperationsDW
ALTER TABLE FactTicketSales
ADD
    accm_txn_create_time   DATETIME,
    accm_txn_complete_time DATETIME,
    txn_process_time_hours FLOAT;
```

### 3. Update connection managers

Open the solution in Visual Studio. In each SSIS package, update the connection managers to point to your SQL Server instance:

| Connection Manager | Default Instance |
|-------------------|-----------------|
| FlightOperationsDW | `DESKTOP-E552K0U\MSSQLSERVER22` |
| FlightOps_Staging | `DESKTOP-E552K0U\MSSQLSERVER22` |
| FlightTicketing_SourceDB | `DESKTOP-E552K0U\MSSQLSERVER22` |

### 4. Set the `BasePath` parameter

The `Flight_Load_Staging.dtsx` and `Update_Fact_Completion.dtsx` packages use a **`BasePath`** project parameter to locate flat files. Set this to the absolute path of the `dataSources` folder, e.g.:

```
C:\Projects\FlightOperationsDW-Project\FlightOperationsDW-Project\dataSources\
```

Update the parameter in `Project.params` or override it at runtime.

---

## Running the ETL Pipeline

Execute the packages **in order**:

```
Step 1 → Flight_Load_Staging.dtsx
          Extracts all source data into FlightOps_Staging

Step 2 → Flight_Load_DW.dtsx
          Transforms and loads staging data into FlightOperationsDW

Step 3 → Update_Fact_Completion.dtsx   (run when completion data is available)
          Updates accumulating snapshot columns in FactTicketSales
```

Each package can be executed directly from Visual Studio (F5) or deployed to an SSIS Catalog and scheduled via SQL Server Agent.

---

## Project Structure

```
FlightOperationsDW-Project/
├── FlightOperationsDW-Project.slnx          # Visual Studio solution file
├── LICENSE.txt
├── README.md
└── FlightOperationsDW-Project/
    ├── FlightOperationsDW-Project.dtproj    # SSIS project file
    ├── FlightOperationsDW-Project.database  # Analysis Services database definition
    ├── Project.params                       # Project-level parameters (BasePath, etc.)
    ├── Flight_Load_Staging.dtsx             # Package 1 – Extract to Staging
    ├── Flight_Load_DW.dtsx                  # Package 2 – Transform & Load to DW
    ├── Update_Fact_Completion.dtsx          # Package 3 – Accumulating snapshot update
    ├── Accumilating fact.sql                # DDL to add accumulating snapshot columns
    ├── FactCompletionUpdates.csv            # Completion timestamp feed for snapshot update
    └── dataSources/
        ├── aircraft.csv
        ├── airports.csv
        ├── flights.csv
        ├── crew.csv
        ├── engineers.txt
        ├── flight_crew.csv
        ├── maintenance_records.txt
        ├── FactCompletionUpdates.csv
        └── Update fact table.csv
```

---

## License

This project is licensed under the **MIT License** — see [LICENSE.txt](LICENSE.txt) for details.
