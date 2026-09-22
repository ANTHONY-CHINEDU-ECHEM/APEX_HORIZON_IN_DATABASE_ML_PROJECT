# Apex Horizon HVAC Contextual Bandit: An In Database Adaptive Control Platform

**A PostgreSQL native contextual multi armed bandit system that learns per zone HVAC set point, fan speed, and pre conditioning policies from live building telemetry, reducing energy cost and peak demand exposure while enforcing hard comfort and equipment safety bounds at every recommendation.**

[![Status](https://img.shields.io/badge/status-enterprise%20reference%20architecture-blue)]()
[![Stack](https://img.shields.io/badge/stack-PostgreSQL%2015%2B%20%7C%20PostgresML%20%7C%20Power%20BI-336791)]()
[![License](https://img.shields.io/badge/license-MIT-green)]()

> **Built by [Anthony Chinedu Echem](#author)**, Machine Learning Engineer and Data Scientist
> End to end platform engineering: the enterprise business case, the dimensional data model, SQL native feature and reward engineering, in database bandit policy training, a safety gated recommendation service, and an executive Power BI decision layer.

<p align="center">
  <img width="1536" height="1024" alt="use_case_a_executive_dashboard" src="https://github.com/user-attachments/assets/f3b0626e-b790-4c3c-82ba-40565438e62d" />
</p>

<p align="center"><em>Use Case A, Zone and Zone Group Set Point Selection: portfolio level energy cost exposure, mean composite reward by policy, hard comfort violations by climate zone, and comfort versus cost tradeoffs, produced live from PostgreSQL.</em></p>

> **Note on images.** The dashboard screenshots in this README are referenced from `docs/dashboards/`. Place the corresponding PNG or JPEG files in that folder, or update the paths, when you push this repository, and they will render inline on GitHub.

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Quantified Impact: What the Dashboards Show](#quantified-impact-what-the-dashboards-show)
3. [The Business Problem](#the-business-problem)
4. [Priority Use Cases](#priority-use-cases)
5. [System Architecture: PostgreSQL End to End](#system-architecture-postgresql-end-to-end)
6. [Repository Structure](#repository-structure)
7. [Data Model Highlights](#data-model-highlights)
8. [Policy Lifecycle: PostgresML, In Database Only](#policy-lifecycle-postgresml-in-database-only)
9. [Monitoring, Off Policy Evaluation, and Retraining](#monitoring-off-policy-evaluation-and-retraining)
10. [Setup and Execution](#setup-and-execution)
11. [Governance and Safety Guardrails](#governance-and-safety-guardrails)
12. [Dashboard Gallery: All Four Use Cases](#dashboard-gallery-all-four-use-cases)
13. [Program Roadmap](#program-roadmap-per-business-case-section-10)
14. [Limitations and Scope](#limitations-and-scope)
15. [Skills Demonstrated](#skills-demonstrated)
16. [License and Author](#license-and-author)

---

## Executive Summary

HVAC systems represent the single largest controllable energy end use in commercial real estate, typically accounting for 38 to 52 percent of total building electricity consumption. Across a portfolio of 167 buildings, more than 34 million square feet, and six climate zones, Apex Horizon Properties Corporation was running that load almost entirely on static or seasonally adjusted schedules and reactive rule overrides, a control paradigm with no mechanism to explore, learn, or exploit the high dimensional, non stationary context, including weather, occupancy, tariffs, solar gain, equipment drift, and inter zone coupling, that actually drives energy cost, comfort, and equipment wear.

This repository is the reference implementation of Use Case A, together with the schema and patterns intended for Use Cases B through D, drawn from that enterprise business case. It is a contextual multi armed bandit that observes the live context of every zone at every decision point and selects the set point, fan, or damper action expected to maximize a composite, multi objective reward covering energy cost, comfort adherence, thermal stability, and equipment stress, computed entirely inside PostgreSQL, with Power BI serving as the sole consumption layer and hard, immutable safety interlocks that no policy can override.

**What distinguishes this from a typical machine learning side project** is that every layer, including ingestion, data quality gating, feature engineering, reward computation, policy training through PostgresML, safety gated scoring, off policy evaluation, drift detection, and retraining triggers, is implemented as governed, versioned, auditable SQL and PL/pgSQL. No external machine learning platform, notebook, or scoring engine is in the loop, by explicit architectural mandate.

---

## Quantified Impact: What the Dashboards Show

> **Methodology note.** These figures are read directly from the reference dashboards, computed on the accompanying synthetic 8,400 record decision log dataset (`Apex_Horizon_HVAC_Bandit_Dataset.xlsx`) built to prototype the pipeline and the Power BI layer ahead of live telemetry onboarding. They demonstrate the shape and mechanics of the business case's benefit levers, and should be read as a proof of mechanism rather than as audited, realized portfolio savings. The business case itself, detailed in Section 9, projects a 9 to 16 percent HVAC energy intensity reduction on pilot cohorts within 18 to 24 months, cross checked against internal baselines and industry reported results for comparable portfolios.

| Metric (dashboard observed) | Result | Business lever it demonstrates |
|---|---|---|
| Total energy cost exposure | 1,499.89 US dollars, a reduction of 12.4 percent versus the prior 30 days | Bandit driven set point relaxation measurably reduces energy spend without abandoning schedule based safety |
| Mean composite reward | Negative 2.34, an improvement of 18.6 percent versus the prior 30 days | The multi objective reward signal (energy, comfort, stability, and equipment stress) is trending toward its optimum as the policy learns |
| Policy performance (share of optimal actions taken) | 89.2 percent, an increase of 9.7 percentage points versus the prior 30 days | Nearly nine in ten recommendations match the highest expected reward action within safety bounds, evidence that the reward model is converging |
| Mid and critical peak cost exposure | 1,240.47 US dollars, a reduction of 15.8 percent | Disproportionate savings land in the highest cost tariff windows, exactly where flexibility value is largest |
| Year to date energy cost avoidance, Use Case C, pre conditioning | 7.5 million US dollars, an increase of 12.8 percent versus the prior period | Tariff and demand response aware pre conditioning is the single largest quantified value lever in the dashboard set |
| Demand response median savings | An 18 percent reduction in energy cost during active demand response events | Directly supports the business case's missed demand response value finding, described in Section 4.3 |
| Multi zone coordination lift, Use Case B | Composite reward higher by 21.7 percent; inter zone coupling lower by 15.2 percent, where lower is better | Coordinated fan and pump speed control reduces simultaneous peak loads and smooths part load operation |
| Equipment stress reduction, Use Case D | Climate policy effectiveness penalty of 0.32, a reduction of 9.8 percent | Purely energy optimal actions are automatically tempered by equipment longevity signals, putting the deferred maintenance lever into practice |
| Hard comfort violations by climate zone | Lowest in the Marine zone, at 2; highest in the Mixed Humid zone, at 28 | Surfaces exactly where the safety classifier and reward weighting need the most attention before wider rollout |

### Framed as a stewardship and operations business case

- **Every dollar of savings is shown against its own denominator**, whether tariff period, climate zone, or demand response event status, so a facilities or energy management reviewer can attribute lift to a specific, actionable lever rather than to a single opaque headline number.
- **Safety is treated as a first class key performance indicator, not an afterthought.** Hard comfort violations are tracked per climate zone alongside every cost metric, and the safety classifier's own precision and recall are logged through `monitoring.evaluate_safety_classifier`, with an automatic Critical alert if recall drops below 0.70, the threshold below which the Model and Policy Risk and Safety Forum must intervene before further live recommendations are issued.
- **The reward versus cost scatter plot in Use Case C, and the stress versus runtime scatter plot in Use Case D,** make the underlying multi objective trade off visible to non technical stakeholders. This is not a single metric optimizer; it is a governed balancing act across four competing objectives.
- **The platform carries a low marginal cost to operate.** Because training, scoring, monitoring, and retraining triggers all live in PostgreSQL functions and scheduled `pg_cron` jobs, there is no separate machine learning serving infrastructure to provision, secure, or pay for.

---

## The Business Problem

Apex Horizon Properties Corporation, a commercial real estate owner and operator with 167 buildings, more than 34 million square feet, and operations across six climate zones (Hot Humid, Hot Dry, Mixed Humid, Mixed Dry, Cold, and Marine), identified six compounding, quantified pain points under static and reactive HVAC control:

| Number | Pain point | Quantified exposure, per the business case |
|---|---|---|
| 1 | Avoidable HVAC energy waste under static or seasonal schedules | An 11 to 19 percent avoidable energy intensity on representative cohorts |
| 2 | Thermal comfort variability and elevated work order volume | Recurring shoulder season and post occupancy change deviations |
| 3 | Missed peak demand and demand response value | Only partial mitigation achieved; incentive and ancillary revenue largely uncaptured |
| 4 | Accelerated equipment cycling and wear | Higher maintenance spend and earlier capital replacement |
| 5 | Analytical friction between manual trend log review and continuous policy improvement | A disproportionate share of energy manager time spent on retrospective analysis rather than forward looking optimization |
| 6 | A gap between ESG and green lease reporting narratives and measured performance | Reputational and regulatory exposure |

**The strategic decision requested of the Board** was approval of the Contextual Bandit Optimisation Initiative as an enterprise program, with Phase 0 funding, an Executive Sponsor, a cross functional Steering Committee, and a standing Model and Policy Risk and Safety Forum, under an absolute technology constraint: all storage, feature engineering, policy training and inference, monitoring, and audit logging occur exclusively inside PostgreSQL, and Power BI is the sole visualization layer.

---

## Priority Use Cases

| Use case | What the policy selects | Primary context features | Value mechanism |
|---|---|---|---|
| A: Zone and zone group set point selection | A discretized set point relaxation, ranging from a 1.0 degree Fahrenheit tightening to a 3.0 degree Fahrenheit relaxation across 9 possible actions | Outdoor dry bulb and wet bulb temperature, humidity, solar radiation, occupancy estimate, tariff period, and zone thermal trajectory | Reduce unnecessary conditioning during low load or favorable weather periods while protecting comfort bands |
| B: Multi zone coordinated mode and fan or pump speed | Operating mode plus a discretized fan or pump speed target across coupled air handling units | Inter zone and inter system thermal and airflow coupling indices | Reduce simultaneous peak loads, improve part load efficiency, and smooth equipment operation |
| C: Tariff and demand response aware pre conditioning | Pre cool, pre heat, or load modulation timing | Weather forecast, historical load shape, tariff calendar, and demand response event flags | Lower peak demand charges and capture demand response and flexibility revenue |
| D: Equipment health aware action selection | The same action space as Use Cases A and B, re ranked by an equipment stress penalty | Cycling frequency, cumulative runtime, valve travel, and performance drift indicators | Defer maintenance, reduce unplanned downtime, and extend asset life |
| E: Portfolio level cross building learning (a Phase 2 extension) | A shared policy structure across similar buildings | Building and zone similarity features | Compounds portfolio wide efficiency and accelerates new asset onboarding |

Each use case is deliberately scoped small at first, limited to selected buildings and zones, and expands only after statistical performance, safety bound integrity, and user acceptance are demonstrated on production data, consistent with the business case's stage gate discipline described in Section 10.

---

## System Architecture: PostgreSQL End to End

```
   raw            curated          features /       policies /        recommendations
  landing zone -> governed dim. -> rewards       -> registry (pgml) -> + monitoring
  (1:1 extract)    model + facts    (versioned SQL)   policy cards       -> Power BI
       ^                                                                        |
       +----------------  mgmt schema: audit log, safety bounds, roles  <-------+
```

| Schema | Purpose |
|---|---|
| `raw` | The landing zone for untransformed building management system, meter, and weather extracts. Never queried directly by Power BI. |
| `curated` | The governed dimensional foundation, including `dim_building`, `dim_zone`, `dim_action_space`, and the partitioned `fact_hvac_decision` context, action, and reward log; the sole source for all downstream features and training. |
| `features` | Versioned, policy ready feature tables and materialized views, built exclusively in SQL using window functions, common table expressions, and temporal encodings. |
| `rewards` | Computed, versioned multi objective reward components (energy, comfort, stability, and equipment stress), fully reproducible from `curated` at any time. |
| `policies` | The policy registry, holding policy card metadata such as training summary, hyperparameters, intended use, known limitations, and risk classification, along with action space definitions and human review or override capture. |
| `recommendations` | Safety gated scoring output, one row per context and best safety permitted action pairing, and the sole Power BI source for live recommendations. |
| `monitoring` | Data quality results, context and reward drift logs, policy performance logs, and a unified alert feed. |
| `mgmt` | Roles, the immutable audit log, the safety bound registry (hard interlocks no policy can exceed), and partition management. |

**Governing design principles, drawn from the business case:**
- **Platform, not point solution.** Every use case leaves behind reusable, versioned data products.
- **Occupant comfort and equipment safety come first.** Any live control policy undergoes elevated validation, explainability review, and formal change control.
- **Human oversight is a deliberate design choice, not a fallback.** Policies recommend; authorized personnel or supervised closed loop interfaces retain final authority.
- **Graceful degradation.** The system degrades safely to schedule based or last known good control on any detected anomaly.
- **An absolute technology constraint.** No external machine learning platforms, no notebooks in production scoring, and no policy engines outside PostgreSQL.

---

## Repository Structure

```
apex_horizon_hvac_bandit/
├── sql/
│   ├── 01_schema_and_tables.sql          # Schemas, dimensional model, partitioning, safety bounds, data quality framework
│   ├── 02_load_and_transform.sql         # COPY ingest, data quality gate, quarantine, curated promotion (idempotent)
│   ├── 03_features_and_ml.sql            # Reward computation, feature engineering, PostgresML policy training
│   └── 04_monitoring_and_retraining.sql  # Inverse propensity scoring off policy evaluation, drift detection, alerts, pg_cron schedules, Power BI views
├── data/
│   └── Apex_Horizon_HVAC_Bandit_Dataset.xlsx   # Synthetic 8,400 record decision log plus data dictionary
├── docs/
│   ├── 4_BUSINESS_CASE.docx              # The full enterprise business case: strategy, return on investment, risk register, governance
│   └── dashboards/                       # Power BI executive dashboard exports for Use Cases A through D
└── README.md
```

## Data Model Highlights

| Object | Detail |
|---|---|
| Decision log grain | One row equals one context, action, and reward instance for a zone at a single point in time |
| Synthetic dataset volume | 8,400 decision records across the full 55 column schema, with an included data dictionary |
| `dim_action_space` | 9 discretized actions, spanning a set point relaxation from a 1.0 degree Fahrenheit tightening up to a 3.0 degree Fahrenheit relaxation, the maximum energy saving setting |
| `mgmt.safety_bounds` | Immutable hard interlocks; the global default is a 66 to 80 degree Fahrenheit set point range, a maximum relaxation of 3.0 degrees Fahrenheit, and a maximum rate of change of 3.0 degrees Fahrenheit per hour |
| `curated.fact_hvac_decision` | A monthly partitioned fact table, indexed on zone and time, building and time, policy, and hard violation flag, for fast Power BI drill down |
| The data quality gate | Duplicate `record_id` values and out of safety bound actions are quarantined in `raw.hvac_decision_quarantine` before reaching the curated layer, providing defense in depth alongside the scoring policy's own bound clipping |

---

## Policy Lifecycle: PostgresML, In Database Only

| Stage | Implementation |
|---|---|
| Reward computation | `rewards.compute_rewards()`, using versioned weight sets from `rewards.reward_weights`; the composite reward is a weighted sum of energy, comfort, stability, and equipment stress terms, fully reproducible from curated data |
| Feature engineering | `features.build_hvac_context_features_v1()`, a versioned, SQL only feature table that is never hand edited |
| The reward regression model, the bandit's value function | Trained with `pgml.train`, using an XGBoost algorithm with 300 estimators, a maximum depth of 6, and a learning rate of 0.05; it ranks candidate actions for each context |
| The safety classifier | An XGBoost classifier that predicts hard comfort violation probability and acts as a hard gate ahead of any recommendation, regardless of predicted reward |
| A LinUCB style linear model | A ridge regression model kept alongside the tree based model as a transparent, interpretable coefficient cross check and confidence bound approximation |
| The policy registry | `policies.policy_registry`, with one row per trained version, recording training summary, hyperparameters, intended use, known limitations, and risk classification (High for the reward model and the safety classifier, Medium for the linear model) |
| Human review capture | `policies.human_review_overrides`, where every high impact recommendation's acceptance or override is logged and feeds subsequent retraining cycles |

---

## Monitoring, Off Policy Evaluation, and Retraining

Because live experimentation on building comfort is expensive and risky, the system evaluates candidate policies offline, against logged data, before any wider rollout:

- **Inverse propensity scoring.** `monitoring.evaluate_policy_ips()` estimates the value the current recommended policy would have achieved had it been running live, using only logged behavior policy data with propensity weighting. Evaluations with fewer than 200 overlapping samples are automatically flagged as high variance.
- **Safety classifier health check.** `monitoring.evaluate_safety_classifier()` tracks precision and recall in production; a recall below 0.70 raises a Critical alert and escalates to the Model and Policy Risk and Safety Forum.
- **Context drift detection.** `monitoring.check_context_drift()` compares 30 day feature means against a reference baseline, covering outdoor temperature, occupancy, cycling risk, and energy price; a shift of more than 20 percent raises a Warning alert.
- **Reward distribution drift.** `monitoring.check_reward_distribution()` tracks average composite reward and hard violation rate by zone type over rolling 30 day windows.
- **A unified alert feed.** `monitoring.alerts` classifies alerts as Info, Warning, or Critical, with acknowledgment tracking, and feeds the executive, facilities engineering, and Risk and Safety Forum Power BI views alike.
- **The retraining trigger.** `mgmt.retraining_required()` surfaces any unacknowledged Warning or Critical alert from the last 7 days, functioning as the SQL native equivalent of a threshold based machine learning operations retraining policy, scheduled through `pg_cron` for nightly reward and feature refresh, weekly off policy evaluation, and monthly partition management.

---

## Setup and Execution

**Prerequisites.** PostgreSQL 15 or later, the `pgml` extension (with MADlib documented as a fallback), `pgcrypto`, `pg_stat_statements`, and optionally `pg_cron` for scheduled jobs.

```bash
# 1. Build the schema: raw, curated, features, rewards, policies, recommendations, monitoring, and mgmt
psql -d apex_horizon -f sql/01_schema_and_tables.sql

# 2. Export the decision log sheet to CSV, then load, quality gate, and promote to curated
#    (the HVAC_Bandit_Decision_Log sheet becomes hvac_bandit_decisions_dataset.csv)
psql -d apex_horizon -f sql/02_load_and_transform.sql

# 3. Compute rewards, build features, and train the reward regression model,
#    the safety classifier, and the LinUCB style linear model through PostgresML
psql -d apex_horizon -f sql/03_features_and_ml.sql

# 4. Stand up monitoring, off policy evaluation, drift detection, and the Power BI views
psql -d apex_horizon -f sql/04_monitoring_and_retraining.sql
```

Then connect Power BI exclusively to the `recommendations.vw_latest_zone_recommendation`, `monitoring.vw_open_alerts`, and `monitoring.vw_recommendation_acceptance` views, along with the underlying governed tables, to reproduce the dashboards shown in this document.

---

## Governance and Safety Guardrails

- **Hard safety interlocks are structural, not advisory.** `mgmt.safety_bounds` defines immutable set point, relaxation, and rate of change limits; any action outside those limits is quarantined before it ever reaches the curated layer or a recommendation table, enforced twice and independently, in both the load pipeline and the scoring layer.
- **Every prediction is auditable.** `mgmt.audit_log` is an append only trail, with UPDATE and DELETE permissions revoked from all roles in production, and every policy version carries a complete policy card record.
- **Risk classified policies receive elevated scrutiny.** High risk policies, namely the reward model and the safety classifier, require sign off from the Model and Policy Risk and Safety Forum before activation.
- **Human oversight is treated as a first class data object, not a user interface afterthought.** Overrides are captured in `policies.human_review_overrides` and explicitly feed future training cycles.
- **Stage gated funding discipline applies throughout.** Per the business case, each subsequent program phase, from Foundation through Industrialization to Scale, is authorized only after formal review of technical health, measured value, an updated risk assessment, and unbroken adherence to the PostgreSQL and Power BI only constraint.

---

## Dashboard Gallery: All Four Use Cases

<img width="1536" height="1024" alt="use_case_a_executive_dashboard" src="https://github.com/user-attachments/assets/66c547e9-baff-4d2c-ad40-04998ae7e9fd" />

<img width="1262" height="832" alt="use_case_b_multizone_coordination" src="https://github.com/user-attachments/assets/dfca94c1-75ae-4902-b442-f58534b758bf" />

<img width="1214" height="758" alt="use_case_c_tariff_dr_preconditioning" src="https://github.com/user-attachments/assets/237b45e5-9400-42b9-a325-e1f0dbe854a6" />

<img width="1262" height="832" alt="use_case_d_equipment_health" src="https://github.com/user-attachments/assets/221906f1-e11d-433e-a866-146bcf839bab" />

All four are exported from the same Power BI decision support layer described above, reading exclusively from governed PostgreSQL tables and views. No dashboard queries any source outside the `curated`, `features`, `rewards`, `recommendations`, and `monitoring` schemas.

---

## Program Roadmap (per Business Case, Section 10)

| Phase | Focus | Target duration | Exit criteria |
|---|---|---|---|
| 0, Mobilization | Requirements gathering, telemetry profiling, detailed design, and a safety impact assessment | 3 to 4 months | Steering Committee approval of the detailed design and confirmed Phase 1 resourcing |
| 1, Foundation and first measured value | Building the data environment and core pipelines, establishing the data quality framework, and piloting at least two use cases with full before and after measurement | 7 to 9 months | Data quality thresholds met, pilot statistical and business thresholds met, and safety bound integrity confirmed |
| 2, Industrialization and controlled expansion | Full production deployment, all persona dashboards live, and embedding into operational workflows | 10 to 14 months | Sustained production performance, demonstrated adoption, and material benefit realization |
| 3, Scale and institutionalize | Portfolio wide broadening, cross building learning, and a handover to a standing product operating model | Ongoing | Continuous stage gate review of technical health, value, and risk |

---

## Limitations and Scope

This repository is presented as a reference architecture and a business case supported prototype, not yet a production deployed control system operating on live buildings. The following points should be read alongside the results above:

- The quantified impact figures in this document are computed on a synthetic decision log dataset, built specifically to validate the pipeline and dashboard mechanics ahead of live telemetry onboarding, and should not be interpreted as audited, realized portfolio savings.
- Live deployment requires the Phase 0 and Phase 1 program steps described in the roadmap, including formal safety impact assessment, pilot measurement against production telemetry, and Steering Committee and Risk and Safety Forum sign off.
- The system is intentionally constrained to a single database technology stack. That constraint supports auditability and operational simplicity, but it also means the design choices in this repository should be evaluated against that specific constraint rather than treated as a universal best practice for every organization.

## Skills Demonstrated

In database machine learning using PostgresML, including XGBoost regression and classification and ridge regression; contextual multi armed bandit design, covering action space definition, reward shaping, and safety gating; off policy and counterfactual evaluation using inverse propensity scoring; dimensional data modeling and monthly partitioning; SQL native feature engineering and data quality frameworks; drift detection and automated alerting; enterprise business case authorship, covering return on investment, risk register, governance, and stage gates; Power BI executive dashboarding; and machine learning operations and policy operations without leaving the database.

---

## License and Author

This project is distributed under the MIT License. See the `LICENSE` file for full terms.

**Anthony Chinedu Echem**
Machine Learning Engineer and Data Scientist
Portfolio contact available on request

---

<p align="center"><em>Recommendations inform and prioritize; authorized personnel and immutable safety bounds retain final authority. This is a governed contextual bandit platform, built to be trusted with real buildings, not just a notebook metric.</em></p>
