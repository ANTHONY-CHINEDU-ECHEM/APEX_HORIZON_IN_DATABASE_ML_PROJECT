# ⚡ Apex Horizon HVAC Contextual Bandit — In-Database Adaptive Control Platform

**A PostgreSQL-native contextual multi-armed bandit system that learns per-zone HVAC set-point, fan-speed, and pre-conditioning policies from live building telemetry — cutting energy cost and peak-demand exposure while enforcing hard comfort and equipment-safety bounds at every recommendation.**

[![Status](https://img.shields.io/badge/status-enterprise%20reference%20architecture-blue)]()
[![Stack](https://img.shields.io/badge/stack-PostgreSQL%2015%2B%20%7C%20PostgresML%20%7C%20Power%20BI-336791)]()
[![License](https://img.shields.io/badge/license-MIT-green)]()
[![Governance](https://img.shields.io/badge/governance-human--in--the--loop%20%2B%20hard%20safety%20bounds-critical)]()
[![Scope](https://img.shields.io/badge/portfolio-167%20buildings%20%7C%2034M%2B%20sqft%20%7C%206%20climate%20zones-orange)]()

> **Built by [Anthony Chinedu Echem](#-author)** — Machine Learning Engineer & Data Scientist
> *End-to-end platform engineering: enterprise business case, dimensional data model, SQL-native feature/reward engineering, in-database bandit policy training, safety-gated recommendation service, and an executive Power BI decision layer.*

<p align="center">
  <img width="1536" height="1024" alt="use_case_a_executive_dashboard" src="https://github.com/user-attachments/assets/f3b0626e-b790-4c3c-82ba-40565438e62d" />

</p>

<p align="center"><em>Use Case A — Zone/Zone-Group Set-Point Selection: portfolio-level energy cost exposure, mean composite reward by policy, hard comfort violations by climate zone, and comfort-vs-cost tradeoffs, live from PostgreSQL.</em></p>

> **Note on images:** the four dashboard screenshots in this README are referenced from `docs/dashboards/` — drop the corresponding PNG/JPEG files into that folder (or update the paths) when you push this repo, and they'll render inline on GitHub.

---

## 📌 Executive Summary

HVAC systems are the single largest controllable energy end-use in commercial real estate — typically **38–52% of total building electricity consumption**. Across a 167-building, 34M+ sq ft, six-climate-zone portfolio, Apex Horizon Properties Corporation was running that load almost entirely on **static or seasonally-adjusted schedules and reactive rule overrides** — a control paradigm with no mechanism to explore, learn, or exploit the high-dimensional, non-stationary context (weather, occupancy, tariffs, solar gain, equipment drift, inter-zone coupling) that actually drives energy cost, comfort, and equipment wear.

This repository is the **reference implementation of Use Case A** (and the schema/patterns for Use Cases B–D) from that enterprise business case: a **contextual multi-armed bandit** that observes the live context of every zone at every decision point and selects the setpoint/fan/damper action expected to maximize a composite, multi-objective reward — energy cost, comfort adherence, thermal stability, and equipment stress — **entirely inside PostgreSQL**, with **Power BI as the sole consumption layer** and hard, immutable safety interlocks that no policy can override.

**What makes this different from a typical ML side-project:** every layer — ingestion, data-quality gating, feature engineering, reward computation, policy training (via PostgresML), safety-gated scoring, off-policy evaluation, drift detection, and retraining triggers — is implemented as governed, versioned, auditable SQL and PL/pgSQL. No external ML platform, notebook, or scoring engine is in the loop, by explicit architectural mandate.

---

## 🎯 Quantified Impact — What the Dashboards Show

> **Methodology note:** these figures are read directly from the reference dashboards, computed on the accompanying **synthetic** 8,400-record decision-log dataset (`Apex_Horizon_HVAC_Bandit_Dataset.xlsx`) built to prototype the pipeline and Power BI layer ahead of live telemetry onboarding. They demonstrate the *shape and mechanics* of the business case's benefit levers — not yet realized, audited portfolio savings. The business case itself (Section 9) projects **9–16% HVAC energy-intensity reduction** on pilot cohorts within 18–24 months, cross-checked against internal baselines and industry-reported results for comparable portfolios.

| Metric (dashboard-observed) | Result | Business lever it demonstrates |
|---|---|---|
| **Total Energy Cost Exposure** | **$1,499.89** (−12.4% vs. prior 30 days) | Bandit-driven set-point relaxation measurably reduces energy spend without abandoning schedule-based safety |
| **Mean Composite Reward** | **−2.34** (+18.6% vs. prior 30 days) | The multi-objective reward signal (energy + comfort + stability + equipment stress) is trending toward optimum as the policy learns |
| **Policy Performance (Optimal Actions)** | **89.2%** (+9.7% vs. prior 30 days) | Nearly 9 in 10 recommendations match the highest-expected-reward action within safety bounds — evidence the reward model is converging |
| **Mid/Critical-Peak Cost Exposure** | **$1,240.47** (−15.8%) | Disproportionate savings land in the highest-cost tariff windows — exactly where flexibility value is largest |
| **YTD Energy Cost Avoidance (Use Case C, pre-conditioning)** | **$7.5M** (+12.8% vs. prior period) | Tariff- and demand-response-aware pre-conditioning is the single largest quantified value lever in the dashboard set |
| **Demand-Response Median Savings** | **18%** energy cost reduction during active DR events | Directly supports the business case's "missed demand-response value" pain point (Section 4.3) |
| **Multi-Zone Coordination Lift (Use Case B)** | Composite reward **+21.7%**, inter-zone coupling **−15.2% (lower is better)** | Coordinated fan/pump-speed control reduces simultaneous peak loads and smooths part-load operation |
| **Equipment Stress Reduction (Use Case D)** | Climate-policy effectiveness penalty **0.32** (−9.8%) | Purely energy-optimal actions are automatically tempered by equipment-longevity signals — the defer-maintenance lever in practice |
| **Hard Comfort Violations by Climate Zone** | Lowest in **Marine (2)**; highest in **Mixed-Humid (28)** | Surfaces exactly where the safety classifier and reward weighting need the most attention before wider rollout |

### Framed as a stewardship / operations business case

- **Every dollar of savings is shown against its own denominator** — tariff period, climate zone, DR-event status — so a facilities or energy-management reviewer can attribute lift to a specific, actionable lever rather than a single opaque headline number.
- **Safety is a first-class KPI, not an afterthought:** hard comfort violations are tracked per climate zone alongside every cost metric, and the safety classifier's own precision/recall are logged (`monitoring.evaluate_safety_classifier`) with an automatic **Critical** alert if recall drops below 0.70 — the threshold below which the Model/Policy Risk & Safety Forum must intervene before further live recommendations.
- **The reward-vs-cost scatter (Use Case C) and stress-vs-runtime scatter (Use Case D)** make the fundamental multi-objective trade-off visible to non-technical stakeholders: this is not a single-metric optimizer, it is a governed balancing act between four competing objectives.
- **Low marginal cost to operate:** because training, scoring, monitoring, and retraining triggers all live in PostgreSQL functions and `pg_cron` jobs, there is no separate ML-serving infrastructure to provision, secure, or pay for.

---

## 🏢 The Business Problem

Apex Horizon Properties Corporation — a 167-building, 34M+ sq ft commercial real-estate owner-operator across six climate zones (Hot-Humid, Hot-Dry, Mixed-Humid, Mixed-Dry, Cold, Marine) — identified six compounding, quantified pain points under static/reactive HVAC control:

| # | Pain point | Quantified exposure (per business case) |
|---|---|---|
| 1 | **Avoidable HVAC energy waste** under static/seasonal schedules | 11–19% avoidable energy intensity on representative cohorts |
| 2 | **Thermal-comfort variability** and elevated work-order volume | Recurring shoulder-season and post-occupancy-change deviations |
| 3 | **Missed peak-demand & demand-response value** | Partial mitigation only; incentive/ancillary revenue largely uncaptured |
| 4 | **Accelerated equipment cycling & wear** | Higher maintenance spend, earlier capital replacement |
| 5 | **Analytical friction** — manual trend-log review vs. continuous policy improvement | Disproportionate energy-manager time on retrospective analysis |
| 6 | **ESG/green-lease reporting gap** between narrative claims and measured performance | Reputational and regulatory exposure |

**The strategic decision requested:** Board-level approval of the Contextual Bandit Optimisation Initiative as an enterprise program, with Phase 0 funding, an Executive Sponsor, a cross-functional Steering Committee, and a standing **Model/Policy Risk & Safety Forum** — under an absolute technology constraint: **all storage, feature engineering, policy training/inference, monitoring, and audit logging occur exclusively inside PostgreSQL; Power BI is the sole visualization layer.**

---

## 🎛️ Priority Use Cases

| Use case | What the policy selects | Primary context features | Value mechanism |
|---|---|---|---|
| **A — Zone / Zone-Group Set-Point Selection** | Discretized setpoint relaxation (−1.0°F to +3.0°F, 9 actions) | Outdoor dry/wet-bulb temp, humidity, solar radiation, occupancy estimate, tariff period, zone thermal trajectory | Reduce unnecessary conditioning during low-load/favorable-weather periods while protecting comfort bands |
| **B — Multi-Zone Coordinated Mode & Fan/Pump-Speed** | Operating mode + discretized fan/pump-speed target across coupled AHUs | Inter-zone/inter-system thermal & airflow coupling indices | Reduce simultaneous peak loads, improve part-load efficiency, smooth equipment operation |
| **C — Tariff- & DR-Aware Pre-Conditioning** | Pre-cool / pre-heat / load-modulation timing | Weather forecast, historical load shape, tariff calendar, DR event flags | Lower peak-demand charges, capture demand-response/flexibility revenue |
| **D — Equipment-Health-Aware Action Selection** | Same action space as A/B, re-ranked by equipment-stress penalty | Cycling frequency, cumulative runtime, valve travel, performance-drift indicators | Defer maintenance, reduce unplanned downtime, extend asset life |
| **E — Portfolio-Level Cross-Building Learning** *(Phase 2 extension)* | Shared policy structure across similar buildings | Building/zone similarity features | Compounds portfolio-wide efficiency; accelerates new-asset onboarding |

Each use case is deliberately scoped small first (selected buildings/zones), and expands only after statistical performance, safety-bound integrity, and user acceptance are demonstrated on production data — per the business case's stage-gate discipline (Section 10).

---

## 🏗️ System Architecture — PostgreSQL End to End

```
┌─────────────┐   ┌──────────────┐   ┌───────────────┐   ┌────────────────┐   ┌───────────────┐
│   raw        │→ │   curated     │→ │   features /    │→ │   policies /     │→ │  recommendations│
│  landing zone │  │  governed dim. │  │   rewards        │  │  registry (pgml)  │  │  + monitoring    │
│  (1:1 extract)│  │  model + facts  │  │  (versioned SQL) │  │  policy cards      │  │  → Power BI       │
└─────────────┘   └──────────────┘   └───────────────┘   └────────────────┘   └───────────────┘
       ▲                                                                                    │
       └──────────────────────────  mgmt schema: audit log, safety bounds, roles  ◄─────────┘
```

| Schema | Purpose |
|---|---|
| `raw` | Landing zone — untransformed BMS/meter/weather extracts. Never queried by Power BI. |
| `curated` | Governed dimensional foundation: `dim_building`, `dim_zone`, `dim_action_space`, and the partitioned `fact_hvac_decision` context-action-reward log — sole source for all downstream features and training. |
| `features` | Versioned, policy-ready feature tables/materialized views, built exclusively in SQL (window functions, CTEs, temporal encodings). |
| `rewards` | Computed, versioned multi-objective reward components (energy, comfort, stability, equipment-stress) — reproducible from `curated` at any time. |
| `policies` | Policy registry (policy-card metadata: training summary, hyperparameters, intended use, known limitations, risk classification), action-space definitions, human-review/override capture. |
| `recommendations` | Safety-gated scoring output — one row per (context, best safety-permitted action) — the sole Power BI source for live recommendations. |
| `monitoring` | Data-quality results, context/reward drift logs, policy-performance logs, unified alert feed. |
| `mgmt` | Roles, immutable audit log, safety-bound registry (hard interlocks no policy can exceed), partition management. |

**Governing design principles (from the business case):**
- **Platform, not point solution** — every use case leaves behind reusable, versioned data products.
- **Occupant comfort & equipment safety primacy** — any live-control policy undergoes elevated validation, explainability, and formal change control.
- **Human-in-the-loop by deliberate design** — policies recommend; authorized personnel or supervised closed-loop interfaces hold final authority.
- **Graceful degradation** — the system degrades safely to schedule-based / last-known-good control on any detected anomaly.
- **Absolute technology constraint** — no external ML platforms, no notebooks in production scoring, no non-PostgreSQL policy engines.

---

## 🗂️ Repository Structure

```
apex-horizon-hvac-bandit/
├── sql/
│   ├── 01_schema_and_tables.sql        # Schemas, dimensional model, partitioning, safety bounds, DQ framework
│   ├── 02_load_and_transform.sql       # COPY ingest → DQ gate → quarantine → curated promotion (idempotent)
│   ├── 03_features_and_ml.sql          # Reward computation, feature engineering, PostgresML policy training
│   └── 04_monitoring_and_retraining.sql# IPS off-policy eval, drift detection, alerts, pg_cron schedules, Power BI views
├── data/
│   └── Apex_Horizon_HVAC_Bandit_Dataset.xlsx   # Synthetic 8,400-record decision log + data dictionary
├── docs/
│   ├── 4_BUSINESS_CASE.docx            # Full enterprise business case (strategy, ROI, risk register, governance)
│   └── dashboards/                     # Power BI executive dashboard exports (Use Cases A–D)
└── README.md
```

---

## 🧬 Data Model Highlights

| Object | Detail |
|---|---|
| **Decision-log grain** | One row = one context-action-reward instance for a zone at a point in time |
| **Synthetic dataset volume** | 8,400 decision records across the full 55-column schema (data dictionary included) |
| **`dim_action_space`** | 9 discretized actions: setpoint relaxation from **−1.0°F** (tighten) to **+3.0°F** (max energy-saving relaxation) |
| **`mgmt.safety_bounds`** | Immutable hard interlocks — global default: **66–80°F** setpoint range, **≤3.0°F** max relaxation, **≤3.0°F/hr** max rate of change |
| **`curated.fact_hvac_decision`** | Monthly-partitioned fact table; indexed on zone/time, building/time, policy, and hard-violation flag for fast Power BI drill-down |
| **Data-quality gate** | Duplicate `record_id` and out-of-safety-bound actions are quarantined (`raw.hvac_decision_quarantine`) *before* reaching curated — defense in depth alongside the source policy's own bound-clipping |

---

## 🧠 Policy Lifecycle (PostgresML, In-Database Only)

| Stage | Implementation |
|---|---|
| **Reward computation** | `rewards.compute_rewards()` — versioned weight sets (`rewards.reward_weights`); composite reward = weighted sum of energy, comfort, stability, and equipment-stress terms, fully reproducible from curated data |
| **Feature engineering** | `features.build_hvac_context_features_v1()` — versioned, SQL-only feature table, never hand-edited |
| **Reward-regression model** (the bandit's value function) | `pgml.train(..., algorithm => 'xgboost', hyperparams => {n_estimators: 300, max_depth: 6, learning_rate: 0.05})` — ranks candidate actions per context |
| **Safety classifier** | XGBoost classifier predicting hard comfort-violation probability; acts as a **hard gate** ahead of any recommendation regardless of predicted reward |
| **LinUCB-style linear model** | Ridge regression kept alongside the tree model as a transparent, interpretable-coefficient cross-check and confidence-bound approximation |
| **Policy registry** | `policies.policy_registry` — one row per trained version: training summary, hyperparameters, intended use, known limitations, and **risk classification** (High for the reward model and safety classifier, Medium for the linear model) |
| **Human review capture** | `policies.human_review_overrides` — every high-impact recommendation's acceptance/override is logged and feeds subsequent retraining cycles |

---

## 📡 Monitoring, Off-Policy Evaluation & Retraining

Because live A/B testing on building comfort is expensive and risky, the system evaluates candidate policies **offline, against logged data**, before any wider rollout:

- **Inverse Propensity Scoring (IPS)** — `monitoring.evaluate_policy_ips()` estimates the value the current recommended policy *would have achieved* had it been running live, using only logged behavior-policy data (propensity-weighted). Automatically flags low-overlap evaluations (<200 samples) as high-variance.
- **Safety classifier health check** — `monitoring.evaluate_safety_classifier()` tracks precision/recall in production; **recall < 0.70 raises a Critical alert** and escalates to the Model/Policy Risk & Safety Forum.
- **Context drift detection** — `monitoring.check_context_drift()` compares 30-day feature means against a reference baseline (outdoor temp, occupancy, cycling risk, energy price); >20% shift raises a Warning alert.
- **Reward-distribution drift** — `monitoring.check_reward_distribution()` tracks average composite reward and hard-violation rate by zone type over rolling 30-day windows.
- **Unified alert feed** — `monitoring.alerts` (Info / Warning / Critical, with acknowledgment tracking) feeds the executive, facilities-engineering, and Risk & Safety Forum Power BI views alike.
- **Retraining trigger** — `mgmt.retraining_required()` surfaces any unacknowledged Warning/Critical alert from the last 7 days — the SQL-native equivalent of a threshold-based MLOps retraining policy, scheduled via `pg_cron` (nightly reward/feature refresh, weekly off-policy evaluation, monthly partition management).

---

## ⚙️ Setup & Execution

**Prerequisites:** PostgreSQL 15+, the `pgml` extension (or MADlib as a documented fallback), `pgcrypto`, `pg_stat_statements`, and optionally `pg_cron` for scheduled jobs.

```bash
# 1. Build the schema: raw / curated / features / rewards / policies / recommendations / monitoring / mgmt
psql -d apex_horizon -f sql/01_schema_and_tables.sql

# 2. Export the decision-log sheet to CSV, then load, quality-gate, and promote to curated
#    (HVAC_Bandit_Decision_Log sheet -> hvac_bandit_decisions_dataset.csv)
psql -d apex_horizon -f sql/02_load_and_transform.sql

# 3. Compute rewards, build features, train the reward-regression model,
#    safety classifier, and LinUCB-style linear model via PostgresML
psql -d apex_horizon -f sql/03_features_and_ml.sql

# 4. Stand up monitoring, off-policy evaluation, drift detection, and Power BI views
psql -d apex_horizon -f sql/04_monitoring_and_retraining.sql
```

Then connect **Power BI** exclusively to the `recommendations.vw_latest_zone_recommendation`, `monitoring.vw_open_alerts`, and `monitoring.vw_recommendation_acceptance` views (and the underlying governed tables) to reproduce the dashboards above.

---

## ⚖️ Governance & Safety Guardrails

- **Hard safety interlocks are structural, not advisory.** `mgmt.safety_bounds` defines immutable setpoint, relaxation, and rate-of-change limits; any action outside them is quarantined before it ever reaches the curated layer or a recommendation table — enforced twice, independently, in both the load pipeline and the scoring layer.
- **Every prediction is auditable.** `mgmt.audit_log` is an append-only trail (UPDATE/DELETE revoked from all roles in production); every policy version carries a full policy-card record.
- **Risk-classified policies get elevated scrutiny.** High-risk policies (the reward model and the safety classifier) require Model/Policy Risk & Safety Forum sign-off before activation.
- **Human-in-the-loop is a first-class data object**, not a UI afterthought — overrides are captured in `policies.human_review_overrides` and explicitly feed future training cycles.
- **Stage-gated funding discipline.** Per the business case, each subsequent program phase (Foundation → Industrialization → Scale) is authorized only after formal review of technical health, measured value, updated risk assessment, and unbroken adherence to the PostgreSQL/Power BI-only constraint.

---

## 🖥️ Dashboard Gallery — All Four Use Cases
<img width="1536" height="1024" alt="use_case_a_executive_dashboard" src="https://github.com/user-attachments/assets/66c547e9-baff-4d2c-ad40-04998ae7e9fd" />

<img width="1262" height="832" alt="use_case_b_multizone_coordination" src="https://github.com/user-attachments/assets/dfca94c1-75ae-4902-b442-f58534b758bf" />

<img width="1214" height="758" alt="use_case_c_tariff_dr_preconditioning" src="https://github.com/user-attachments/assets/237b45e5-9400-42b9-a325-e1f0dbe854a6" />

<img width="1262" height="832" alt="use_case_d_equipment_health" src="https://github.com/user-attachments/assets/221906f1-e11d-433e-a866-146bcf839bab" />


All four are exported from the same Power BI decision-support layer described above, reading exclusively from governed PostgreSQL tables and views — no dashboard queries any source outside the `curated`/`features`/`rewards`/`recommendations`/`monitoring` schemas.

---

## 🗺️ Program Roadmap (per Business Case, Section 10)

| Phase | Focus | Target duration | Exit criteria |
|---|---|---|---|
| **0 — Mobilization** | Requirements, telemetry profiling, detailed design, safety impact assessment | 3–4 months | Steering Committee approval of detailed design; confirmed Phase 1 resourcing |
| **1 — Foundation & First Measured Value** | Build data environment, core pipelines, DQ framework, pilot ≥2 use cases with full before/after measurement | 7–9 months | Data-quality thresholds met; pilot statistical/business thresholds met; safety-bound integrity confirmed |
| **2 — Industrialization & Controlled Expansion** | Full production deployment, all persona dashboards, embed into operational workflows | 10–14 months | Sustained production performance; demonstrated adoption; material benefit realization |
| **3 — Scale & Institutionalize** | Portfolio-wide broadening, cross-building learning, product-operating-model handover | Ongoing | Continuous stage-gate review of technical health, value, and risk |

---

## 🧩 Skills Demonstrated

`In-database ML (PostgresML: XGBoost regression/classification, ridge regression)` · `Contextual multi-armed bandit design (action space, reward shaping, safety gating)` · `Off-policy / counterfactual evaluation (Inverse Propensity Scoring)` · `Dimensional data modeling & monthly partitioning` · `SQL-native feature engineering & data-quality frameworks` · `Drift detection & automated alerting` · `Enterprise business-case authorship (ROI, risk register, governance, stage-gates)` · `Power BI executive dashboarding` · `MLOps/PolicyOps without leaving the database`

---

## 📄 License

Distributed under the **MIT License**. See the `LICENSE` file for full terms.

## 👤 Author

**Anthony Chinedu Echem**
Machine Learning Engineer & Data Scientist
📫 Portfolio contact available on request

---

<p align="center"><em>Recommendations inform and prioritize; authorized personnel and immutable safety bounds retain final authority — a governed contextual-bandit platform built to be trusted with real buildings, not just a notebook metric.</em></p>
