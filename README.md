**Intelligent Contextual Multi-Armed Bandit Optimisation for Adaptive Multi-Zone HVAC Control, Dynamic Set-Point Selection, and Portfolio-Wide Building Energy & Comfort Management**

**Apex Horizon Properties Corporation
Digital Transformation Office | Facilities Operations & Engineering | Central Energy Management**


**OVERVIEW**

This repository contains the complete technical foundation and production-ready implementation for Apex Horizon Properties Corporation’s enterprise program: Intelligent Contextual Multi-Armed Bandit Optimisation for Adaptive Multi-Zone HVAC Control.The platform delivers governed, sequential decision-making under uncertainty for HVAC systems across a large commercial real-estate portfolio. 

It operates exclusively within PostgreSQL (data, feature engineering, policy training, inference, monitoring, and audit) and surfaces all insights and recommendations through Power BI.The solution systematically reduces energy waste, improves thermal comfort consistency, lowers peak-demand charges, and decreases equipment stress while maintaining absolute safety bounds, full auditability, and human-in-the-loop control.



**BUSINESS CONTEXT**

Apex Horizon Properties Corporation owns, operates, and provides full facilities management for a diversified portfolio of 167 commercial buildings representing more than 34 million square feet of conditioned floor area across six distinct climate zones.

HVAC systems (air-handling units, variable-air-volume boxes, chillers, boilers, heat pumps, fans, pumps, and associated zone-level actuators) constitute the single largest controllable energy end-use. They typically account for 38–52 % of total building electricity consumption and a substantial share of thermal energy.Over the past twelve years the organisation has completed successive efficiency investments, including LED lighting, basic building-management-system upgrades, selective variable-frequency drives, and enhanced sub-metering. 

Despite these improvements, the dominant control paradigm has remained static or seasonally adjusted set-point schedules, simple rule-based overrides, and reactive feedback loops.These approaches lack any systematic capacity to explore, learn, and exploit the high-dimensional, non-stationary operating context of outdoor weather, real-time and forecast occupancy, time-of-use and demand tariffs, internal heat gains, solar radiation, equipment performance drift, and inter-zone thermal coupling.


**THE PROBLEM SOLVED**

<img width="1536" height="1024" alt="APEX_HORIZON_DASHBOARD USE CASE A" src="https://github.com/user-attachments/assets/e42e384f-cdb4-4898-a519-083b84d7d068" />
<img width="1262" height="832" alt="APEX_HORIZON_USE_CASE_B" src="https://github.com/user-attachments/assets/e1390478-86b1-44d1-86ce-036a3c28e017" />
<img width="1214" height="758" alt="APEX_HORIZON_USE_CASE_C" src="https://github.com/user-attachments/assets/509343e9-1a2b-4b73-a829-f41fb7934d6f" />
<img width="1262" height="832" alt="APEX_HORIZON_USE_CASE_D" src="https://github.com/user-attachments/assets/663ca870-7c57-4792-8df8-6547ea26140a" />


The absence of a governed, context-aware, continuously learning decision layer produced five tightly interdependent operational and financial pain points:

Avoidable energy consumption — Material HVAC energy was consumed during periods of low occupancy or favourable outdoor conditions that could safely have supported relaxed set-points.


Thermal-comfort variability — Recurring deviations during shoulder seasons, occupancy changes, and extreme weather events generated elevated work-order volumes, tenant dissatisfaction, and occasional commercial credits.


Elevated peak-demand charges — Inability to proactively pre-cool, pre-heat, or modulate loads ahead of high-tariff windows and utility demand-response events left significant cost and flexibility value uncaptured.


Accelerated equipment wear — Non-optimised start–stop and modulation cycles increased mechanical and electrical stress, raising maintenance expenditure and the probability of unplanned downtime.


Analytical friction and ESG exposure — Facility engineers and energy managers spent disproportionate time on retrospective analysis and manual tuning, while fragmented data hindered credible ESG reporting and green-lease compliance.

Conservative internal quantification, cross-checked against industry benchmarks, indicated avoidable HVAC energy intensity on the order of 11–19 % on representative building cohorts, translating into annual cost exposure in the low-to-mid millions of dollars together with corresponding Scope 2 emissions.


**SOLUTION VISION**

The Intelligent Contextual Multi-Armed Bandit Optimisation Initiative establishes a single, high-integrity analytical platform that:Consolidates curated building telemetry, occupancy proxies, weather and tariff data, equipment metadata, and historical control actions exclusively inside PostgreSQL.

- Engineers rich contextual features and multi-objective rewards entirely with SQL and supported PostgreSQL machine-learning extensions.

- Trains, versions, validates, and scores contextual multi-armed bandit policies (approximated via gradient-boosted trees and regularised linear models) inside the database.

- Writes all recommendations, uncertainty measures, feature-importance explanations, and monitoring statistics back into governed PostgreSQL tables.

- Surfaces role-specific decision-support environments exclusively through Power BI.

- Enforces hard safety interlocks, human-in-the-loop overrides, complete lineage, and immutable audit logging at every layer.

The platform is deliberately designed as a reusable enterprise capability rather than a collection of isolated point solutions. Early use cases generate versioned data products, feature tables, policy-lifecycle patterns, and safety-bound templates that accelerate subsequent expansion.


**SYSTEM ARCHITECTURE**

All storage, feature engineering, policy training, inference, monitoring, lineage, and audit logging occur exclusively inside PostgreSQL. Power BI is the sole authorised visualisation and interaction layer.

[BMS Historians, Meter Data Systems, Weather Services]
                │
                ▼  (Non-invasive, auditable ETL)
[PostgreSQL Schemas]
  
  ├── raw            Immutable landing zone
  
  ├── curated        Conformed dimensions and partitioned decision-log facts
  
  ├── features       Versioned context-feature tables and train/validation/test splits
  
  ├── rewards        Multi-objective reward definitions and logs
  
  ├── policies       Policy registry, versioned artefacts, and policy cards
  
  ├── recommendations Safety-gated, scored action recommendations
  
  ├── monitoring     Data-quality, drift detection, offline evaluation, and alerts
  
  └── mgmt           Audit trails, safety-bound registry, partition management
                │
                ▼  (Governed semantic models)
[Power BI Role-Specific Decision-Support Workbenches]
  
  ├── Executive ESG & Energy Dashboard
  
  ├── Facilities Engineering Workbench
  
  └── Model/Policy Risk & Safety Forum Views



├── HVAC_01_schema_and_tables.sql      # Schema creation, dimensions, partitioning, audit triggers

├── HVAC_02_load_and_transform.sql     # ETL, data-quality gates, quarantine, fact upserts

├── HVAC_03_features_and_ml.sql        # Feature engineering, reward calculation, policy training

├── HVAC_04_monitoring_and_retraining.sql # Drift detection, offline evaluation, alerts, Power BI views

└── README.md

**Prerequisites**

PostgreSQL 15+ with extensions: pgcrypto, pg_stat_statements, and the chosen machine-learning extension (e.g., pgml)
Power BI Desktop / Service with DirectQuery or Import connectivity to the governed PostgreSQL environment

**Deployment Sequence**

- Execute HVAC_01_schema_and_tables.sql

- Execute HVAC_02_load_and_transform.sql

- Execute HVAC_03_features_and_ml.sql

- Execute HVAC_04_monitoring_and_retraining.sql

- Configure Power BI semantic models against the published views in the recommendations and monitoring schemas

Expected Outcomes (Conservative Base Case)

- HVAC energy-intensity reductions of 9–16 % on pilot cohorts within 18–24 months

- Material reductions in peak-demand charges

- Measurable decline in thermal-comfort work-order volume

- Deferred equipment maintenance and extended asset life

- Strengthened ESG reporting metrics and green-lease compliance

- Institutionalised organisational capability in governed sequential decision-making under uncertainty

All benefits are tracked against pre-initiative baselines with statistical attribution and form explicit stage-gate criteria.

**Governance & Stage-Gate Discipline**

The program operates under formal stage-gate control:Phase 0 – Mobilisation, deep requirements, telemetry profiling, and detailed design

- Phase 1 – Foundation and first measured value (limited-scope, rigorously instrumented pilots)

- Phase 2 – Industrialisation and controlled expansion

- Phase 3 – Portfolio-wide scale, optimisation, and institutionalisation

Progression requires demonstrated technical health, measured business value, residual-risk assessment, safety-bound integrity, and unbroken adherence to the exclusive PostgreSQL + Power BI technology constraint.



