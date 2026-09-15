-- =============================================================================
-- APEX HORIZON PROPERTIES CORPORATION
-- Intelligent Contextual Multi-Armed Bandit Optimisation for Adaptive
-- Multi-Zone HVAC Control
--
-- Use Case A: Contextual Bandit Zone / Zone-Group Set-Point Selection under
--             Dynamic Occupancy, Weather, and Tariff Context
--
-- SCRIPT 01 of 04: Schema architecture, dimensional model, partitioning,
--                  constraints, and the data-quality framework.
--
-- Target platform: PostgreSQL 15+
-- Design follows business-case section 7.1 / 7.4: separate schemas for raw,
-- curated, features, rewards, policies, recommendations, monitoring; native
-- constraints/triggers for master data management; SQL-only data quality.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 0. Extensions & schemas
-- -----------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

CREATE SCHEMA IF NOT EXISTS raw;            -- landing zone for BMS/meter/weather extracts
CREATE SCHEMA IF NOT EXISTS curated;        -- governed dimensional foundation + decision log
CREATE SCHEMA IF NOT EXISTS features;       -- versioned context/feature tables for policy training
CREATE SCHEMA IF NOT EXISTS rewards;        -- computed reward tables (separate from raw telemetry)
CREATE SCHEMA IF NOT EXISTS policies;       -- policy registry, policy cards, action-space metadata
CREATE SCHEMA IF NOT EXISTS recommendations;-- policy outputs / scored recommendations
CREATE SCHEMA IF NOT EXISTS monitoring;     -- data quality, drift, policy-performance logs
CREATE SCHEMA IF NOT EXISTS mgmt;           -- roles, audit, lineage, safety bounds

COMMENT ON SCHEMA raw IS 'Landing zone. Untransformed extracts from BMS historians, meter data systems, and weather services. No analytical use.';
COMMENT ON SCHEMA curated IS 'Governed analytical foundation: conformed building/zone/equipment master data and the curated context-action-reward decision log. Single source of truth for downstream features, policies, and Power BI.';
COMMENT ON SCHEMA features IS 'Versioned, policy-ready feature tables/materialized views built exclusively with SQL.';
COMMENT ON SCHEMA rewards IS 'Computed multi-objective reward components and composite reward, kept separate from raw telemetry for governance and reproducibility.';
COMMENT ON SCHEMA policies IS 'Policy registry, policy-card metadata, action-space definitions, and safety-bound configuration (PostgreSQL-ML-extension-backed).';
COMMENT ON SCHEMA recommendations IS 'Policy recommendation/scoring outputs with policy version, confidence, and explanation fields, written back by scoring jobs.';
COMMENT ON SCHEMA monitoring IS 'Data-quality results, context/reward drift statistics, and policy-performance tracking, entirely SQL-computed.';
COMMENT ON SCHEMA mgmt IS 'Roles, audit logging, safety-bound registry, and lineage metadata.';

-- -----------------------------------------------------------------------------
-- 1. Master-data / reference tables (curated)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS curated.dim_building (
    building_id                 TEXT PRIMARY KEY,
    climate_zone                TEXT NOT NULL CHECK (climate_zone IN ('Hot-Humid','Hot-Dry','Mixed-Humid','Mixed-Dry','Cold','Marine')),
    building_conditioned_sqft   NUMERIC(12,1) CHECK (building_conditioned_sqft > 0),
    building_vintage_year       INTEGER CHECK (building_vintage_year BETWEEN 1900 AND 2100),
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE curated.dim_building IS 'Conformed building master data. One row per building (167 in the current portfolio).';

CREATE TABLE IF NOT EXISTS curated.dim_zone (
    zone_id                  TEXT PRIMARY KEY,
    building_id               TEXT NOT NULL REFERENCES curated.dim_building(building_id),
    zone_group_id              TEXT NOT NULL,
    floor_number                INTEGER,
    zone_type                    TEXT NOT NULL,
    conditioned_area_sqft         NUMERIC(10,1) CHECK (conditioned_area_sqft > 0),
    ahu_id                          TEXT,
    created_at                        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                        TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE curated.dim_zone IS 'Conformed HVAC zone master data. One row per zone, grouped into thermally coupled zone_group_id cohorts for Use Case B coordination.';
CREATE INDEX IF NOT EXISTS ix_dim_zone_building ON curated.dim_zone(building_id);
CREATE INDEX IF NOT EXISTS ix_dim_zone_group ON curated.dim_zone(zone_group_id);
CREATE INDEX IF NOT EXISTS ix_dim_zone_ahu ON curated.dim_zone(ahu_id);

CREATE TABLE IF NOT EXISTS curated.dim_action_space (
    action_id                    INTEGER PRIMARY KEY,
    action_setpoint_relaxation_deg NUMERIC(4,1) NOT NULL UNIQUE,
    action_description             TEXT,
    is_within_safety_bounds          BOOLEAN NOT NULL DEFAULT TRUE
);
COMMENT ON TABLE curated.dim_action_space IS 'Discretized action space for Use Case A: relaxation in degrees F relative to the tight-comfort baseline setpoint. Negative = tighter than baseline, positive = relaxed (energy-saving direction).';

INSERT INTO curated.dim_action_space (action_id, action_setpoint_relaxation_deg, action_description) VALUES
 (1, -1.0, 'Tighten setpoint 1.0F below baseline'),
 (2, -0.5, 'Tighten setpoint 0.5F below baseline'),
 (3,  0.0, 'Hold baseline setpoint'),
 (4,  0.5, 'Relax setpoint 0.5F'),
 (5,  1.0, 'Relax setpoint 1.0F'),
 (6,  1.5, 'Relax setpoint 1.5F'),
 (7,  2.0, 'Relax setpoint 2.0F'),
 (8,  2.5, 'Relax setpoint 2.5F'),
 (9,  3.0, 'Relax setpoint 3.0F (maximum permitted relaxation)')
ON CONFLICT (action_id) DO NOTHING;

CREATE OR REPLACE FUNCTION mgmt.set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_dim_building_updated ON curated.dim_building;
CREATE TRIGGER trg_dim_building_updated BEFORE UPDATE ON curated.dim_building
    FOR EACH ROW EXECUTE FUNCTION mgmt.set_updated_at();

DROP TRIGGER IF EXISTS trg_dim_zone_updated ON curated.dim_zone;
CREATE TRIGGER trg_dim_zone_updated BEFORE UPDATE ON curated.dim_zone
    FOR EACH ROW EXECUTE FUNCTION mgmt.set_updated_at();

-- -----------------------------------------------------------------------------
-- 2. Safety-bound registry (hard interlocks — non-negotiable per business case)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS mgmt.safety_bounds (
    bound_id                SERIAL PRIMARY KEY,
    scope_type               TEXT NOT NULL CHECK (scope_type IN ('Global','ClimateZone','ZoneType','Zone')),
    scope_value                TEXT,          -- NULL for Global, else climate_zone / zone_type / zone_id
    min_setpoint_f               NUMERIC(4,1) NOT NULL,
    max_setpoint_f                 NUMERIC(4,1) NOT NULL,
    max_relaxation_deg               NUMERIC(4,1) NOT NULL,
    max_rate_of_change_f_per_hr        NUMERIC(4,1) NOT NULL,
    is_active                            BOOLEAN NOT NULL DEFAULT TRUE,
    effective_from                        TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (max_setpoint_f > min_setpoint_f)
);
COMMENT ON TABLE mgmt.safety_bounds IS 'Immutable-by-policy hard safety interlocks (comfort/equipment bounds). Any recommendation outside these bounds must never be written to recommendations tables as actionable.';

INSERT INTO mgmt.safety_bounds (scope_type, scope_value, min_setpoint_f, max_setpoint_f, max_relaxation_deg, max_rate_of_change_f_per_hr)
VALUES ('Global', NULL, 66.0, 80.0, 3.0, 3.0)
ON CONFLICT DO NOTHING;

-- -----------------------------------------------------------------------------
-- 3. Raw landing table (mirrors the flat source extract / Excel-derived CSV 1:1)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS raw.hvac_decision_stg (
    record_id                                  INTEGER,
    decision_timestamp                         TIMESTAMP,
    building_id                                TEXT,
    climate_zone                               TEXT,
    zone_id                                     TEXT,
    zone_group_id                              TEXT,
    floor_number                               INTEGER,
    zone_type                                  TEXT,
    conditioned_area_sqft                      NUMERIC,
    outdoor_dry_bulb_temp_f                    NUMERIC,
    outdoor_wet_bulb_temp_f                    NUMERIC,
    outdoor_humidity_pct                       NUMERIC,
    solar_radiation_index                      NUMERIC,
    day_type                                   TEXT,
    hour_of_day                                INTEGER,
    time_of_day_bucket                         TEXT,
    occupancy_estimate_pct                     NUMERIC,
    occupancy_source                           TEXT,
    co2_ppm                                    NUMERIC,
    zone_temp_prior_f                          NUMERIC,
    zone_setpoint_prior_f                      NUMERIC,
    zone_temp_rate_of_change_f_per_hr          NUMERIC,
    tariff_period                              TEXT,
    energy_price_usd_per_kwh                   NUMERIC,
    demand_response_event_flag                 INTEGER,
    recent_energy_intensity_kwh_per_sqft       NUMERIC,
    ahu_id                                     TEXT,
    equipment_cycling_count_1hr                INTEGER,
    equipment_cumulative_runtime_hours         NUMERIC,
    valve_position_prior_pct                   NUMERIC,
    damper_position_prior_pct                  NUMERIC,
    fan_speed_prior_pct                        NUMERIC,
    inter_zone_coupling_index                  NUMERIC,
    context_cluster_id                         INTEGER,
    policy_id                                  TEXT,
    policy_version                             TEXT,
    action_id                                  INTEGER,
    action_setpoint_relaxation_deg             NUMERIC,
    action_fan_speed_target_pct                NUMERIC,
    action_damper_target_pct                   NUMERIC,
    action_mode                                TEXT,
    exploration_flag                           INTEGER,
    propensity_score                           NUMERIC,
    energy_use_kwh                             NUMERIC,
    energy_cost_impact_usd                     NUMERIC,
    comfort_deviation_f                        NUMERIC,
    comfort_violation_flag                     INTEGER,
    hard_comfort_violation_flag                INTEGER,
    stability_penalty                          NUMERIC,
    equipment_stress_penalty                   NUMERIC,
    composite_reward                           NUMERIC,
    post_action_zone_temp_f                    NUMERIC,
    human_override_flag                        INTEGER,
    data_quality_flag                          TEXT,
    record_created_timestamp                   TIMESTAMP,
    load_batch_id                              UUID DEFAULT gen_random_uuid(),
    loaded_at                                  TIMESTAMPTZ DEFAULT now()
);
COMMENT ON TABLE raw.hvac_decision_stg IS 'Untransformed 1:1 landing table for the HVAC contextual-bandit decision-log extract (Excel/CSV). Loaded via COPY. Never queried directly by Power BI.';

-- -----------------------------------------------------------------------------
-- 4. Curated decision-log fact table — partitioned by decision_timestamp (monthly)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS curated.fact_hvac_decision (
    record_id                          BIGINT NOT NULL,
    decision_timestamp                 TIMESTAMP NOT NULL,
    building_id                        TEXT NOT NULL REFERENCES curated.dim_building(building_id),
    zone_id                            TEXT NOT NULL REFERENCES curated.dim_zone(zone_id),
    -- context
    outdoor_dry_bulb_temp_f            NUMERIC(6,2),
    outdoor_wet_bulb_temp_f            NUMERIC(6,2),
    outdoor_humidity_pct               NUMERIC(5,1),
    solar_radiation_index              NUMERIC(6,2),
    day_type                           TEXT CHECK (day_type IN ('Weekday','Weekend','Holiday')),
    hour_of_day                        SMALLINT CHECK (hour_of_day BETWEEN 0 AND 23),
    time_of_day_bucket                 TEXT,
    occupancy_estimate_pct             NUMERIC(5,2) CHECK (occupancy_estimate_pct BETWEEN 0 AND 100),
    occupancy_source                   TEXT,
    co2_ppm                            NUMERIC(7,1),
    zone_temp_prior_f                  NUMERIC(6,2),
    zone_setpoint_prior_f              NUMERIC(6,2),
    zone_temp_rate_of_change_f_per_hr  NUMERIC(6,3),
    tariff_period                      TEXT CHECK (tariff_period IN ('Off-Peak','Mid-Peak','On-Peak','Critical-Peak')),
    energy_price_usd_per_kwh           NUMERIC(8,4) CHECK (energy_price_usd_per_kwh >= 0),
    demand_response_event_flag         SMALLINT CHECK (demand_response_event_flag IN (0,1)),
    recent_energy_intensity_kwh_per_sqft NUMERIC(8,4),
    equipment_cycling_count_1hr        SMALLINT CHECK (equipment_cycling_count_1hr >= 0),
    equipment_cumulative_runtime_hours NUMERIC(10,1),
    valve_position_prior_pct           NUMERIC(5,1) CHECK (valve_position_prior_pct BETWEEN 0 AND 100),
    damper_position_prior_pct          NUMERIC(5,1) CHECK (damper_position_prior_pct BETWEEN 0 AND 100),
    fan_speed_prior_pct                NUMERIC(5,1) CHECK (fan_speed_prior_pct BETWEEN 0 AND 100),
    inter_zone_coupling_index          NUMERIC(5,3),
    context_cluster_id                 INTEGER,
    -- action (logged / behavior policy)
    policy_id                          TEXT NOT NULL,
    policy_version                     TEXT NOT NULL,
    action_id                          INTEGER NOT NULL REFERENCES curated.dim_action_space(action_id),
    action_setpoint_relaxation_deg     NUMERIC(4,1) NOT NULL,
    action_fan_speed_target_pct        NUMERIC(5,1),
    action_damper_target_pct           NUMERIC(5,1),
    action_mode                        TEXT,
    exploration_flag                   SMALLINT CHECK (exploration_flag IN (0,1)),
    propensity_score                   NUMERIC(7,5) CHECK (propensity_score > 0 AND propensity_score <= 1),
    -- reward
    energy_use_kwh                     NUMERIC(10,4),
    energy_cost_impact_usd             NUMERIC(10,4),
    comfort_deviation_f                NUMERIC(6,3),
    comfort_violation_flag             SMALLINT CHECK (comfort_violation_flag IN (0,1)),
    hard_comfort_violation_flag        SMALLINT CHECK (hard_comfort_violation_flag IN (0,1)),
    stability_penalty                  NUMERIC(8,4),
    equipment_stress_penalty           NUMERIC(8,4),
    composite_reward                   NUMERIC(10,4) NOT NULL,
    post_action_zone_temp_f            NUMERIC(6,2),
    human_override_flag                SMALLINT CHECK (human_override_flag IN (0,1)),
    data_quality_flag                  TEXT NOT NULL DEFAULT 'Complete',
    record_created_timestamp           TIMESTAMP NOT NULL,
    ingested_at                        TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (record_id, decision_timestamp)
) PARTITION BY RANGE (decision_timestamp);
COMMENT ON TABLE curated.fact_hvac_decision IS 'Curated, governed context-action-reward decision log underpinning Use Case A. Partitioned monthly on decision_timestamp. Sole source for the features/rewards schemas and offline policy training.';

DO $$
DECLARE
    p_start DATE := DATE '2024-01-01';
    p_end   DATE := DATE '2026-06-01';
    d       DATE;
    part_name TEXT;
BEGIN
    d := p_start;
    WHILE d < p_end LOOP
        part_name := 'fact_hvac_decision_' || to_char(d, 'YYYY_MM');
        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS curated.%I PARTITION OF curated.fact_hvac_decision
             FOR VALUES FROM (%L) TO (%L);',
            part_name, d, (d + INTERVAL '1 month')::DATE
        );
        d := (d + INTERVAL '1 month')::DATE;
    END LOOP;
END $$;

CREATE TABLE IF NOT EXISTS curated.fact_hvac_decision_default
    PARTITION OF curated.fact_hvac_decision DEFAULT;

CREATE OR REPLACE FUNCTION mgmt.ensure_partition(p_month DATE)
RETURNS VOID AS $$
DECLARE
    part_name TEXT := 'fact_hvac_decision_' || to_char(p_month, 'YYYY_MM');
BEGIN
    EXECUTE format(
        'CREATE TABLE IF NOT EXISTS curated.%I PARTITION OF curated.fact_hvac_decision
         FOR VALUES FROM (%L) TO (%L);',
        part_name, date_trunc('month', p_month)::DATE,
        (date_trunc('month', p_month) + INTERVAL '1 month')::DATE
    );
END;
$$ LANGUAGE plpgsql;

CREATE INDEX IF NOT EXISTS ix_fact_hvac_zone       ON curated.fact_hvac_decision(zone_id, decision_timestamp);
CREATE INDEX IF NOT EXISTS ix_fact_hvac_building    ON curated.fact_hvac_decision(building_id, decision_timestamp);
CREATE INDEX IF NOT EXISTS ix_fact_hvac_policy       ON curated.fact_hvac_decision(policy_id, policy_version);
CREATE INDEX IF NOT EXISTS ix_fact_hvac_hardviol      ON curated.fact_hvac_decision(hard_comfort_violation_flag) WHERE hard_comfort_violation_flag = 1;
CREATE INDEX IF NOT EXISTS ix_fact_hvac_decision_time  ON curated.fact_hvac_decision(decision_timestamp);

-- -----------------------------------------------------------------------------
-- 5. Data-quality framework (SQL-only, per business case section 7.1)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS monitoring.data_quality_rules (
    rule_id         SERIAL PRIMARY KEY,
    rule_name       TEXT NOT NULL UNIQUE,
    rule_category   TEXT NOT NULL CHECK (rule_category IN ('Completeness','Validity','Consistency','Uniqueness','Referential Integrity','Temporal Alignment')),
    target_table    TEXT NOT NULL,
    rule_sql        TEXT NOT NULL,   -- predicate matching FAILING rows
    severity        TEXT NOT NULL DEFAULT 'Warning' CHECK (severity IN ('Warning','Critical')),
    is_active       BOOLEAN NOT NULL DEFAULT TRUE
);

INSERT INTO monitoring.data_quality_rules (rule_name, rule_category, target_table, rule_sql, severity) VALUES
 ('setpoint_relaxation_out_of_bounds', 'Validity', 'raw.hvac_decision_stg', 'action_setpoint_relaxation_deg < -1.0 OR action_setpoint_relaxation_deg > 3.0', 'Critical'),
 ('negative_energy_use', 'Validity', 'raw.hvac_decision_stg', 'energy_use_kwh < 0', 'Critical'),
 ('missing_zone_id', 'Completeness', 'raw.hvac_decision_stg', 'zone_id IS NULL', 'Critical'),
 ('missing_building_id', 'Completeness', 'raw.hvac_decision_stg', 'building_id IS NULL', 'Critical'),
 ('propensity_out_of_range', 'Validity', 'raw.hvac_decision_stg', 'propensity_score IS NOT NULL AND (propensity_score <= 0 OR propensity_score > 1)', 'Critical'),
 ('duplicate_record_id', 'Uniqueness', 'raw.hvac_decision_stg', 'record_id IN (SELECT record_id FROM raw.hvac_decision_stg GROUP BY record_id HAVING COUNT(*) > 1)', 'Critical'),
 ('hard_violation_without_deviation', 'Consistency', 'raw.hvac_decision_stg', 'hard_comfort_violation_flag = 1 AND comfort_deviation_f < 4.0', 'Warning'),
 ('future_decision_timestamp', 'Temporal Alignment', 'raw.hvac_decision_stg', 'decision_timestamp > now()', 'Critical')
ON CONFLICT (rule_name) DO NOTHING;

COMMENT ON TABLE monitoring.data_quality_rules IS 'Declarative data-quality rule catalog. rule_sql is a WHERE-clause predicate identifying FAILING rows; evaluated by mgmt.run_data_quality_checks().';

CREATE TABLE IF NOT EXISTS monitoring.data_quality_results (
    result_id       BIGSERIAL PRIMARY KEY,
    rule_id         INTEGER REFERENCES monitoring.data_quality_rules(rule_id),
    run_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    rows_checked    BIGINT,
    rows_failed     BIGINT,
    pass_rate_pct   NUMERIC(5,2),
    severity        TEXT,
    passed          BOOLEAN
);
COMMENT ON TABLE monitoring.data_quality_results IS 'Execution history of the data-quality rule catalog. Consumed by the Power BI data-governance dashboard and the load gate in script 02.';

CREATE TABLE IF NOT EXISTS raw.hvac_decision_quarantine (
    LIKE raw.hvac_decision_stg INCLUDING ALL,
    quarantine_reason   TEXT,
    quarantined_at      TIMESTAMPTZ DEFAULT now()
);
COMMENT ON TABLE raw.hvac_decision_quarantine IS 'Rows failing Critical-severity data-quality rules are routed here instead of the curated layer, with the failing rule recorded.';

CREATE OR REPLACE FUNCTION mgmt.run_data_quality_checks(p_table TEXT DEFAULT 'raw.hvac_decision_stg')
RETURNS BOOLEAN AS $$
DECLARE
    r RECORD;
    v_total BIGINT;
    v_failed BIGINT;
    v_critical_failed BOOLEAN := FALSE;
BEGIN
    EXECUTE format('SELECT COUNT(*) FROM %s', p_table) INTO v_total;

    FOR r IN SELECT * FROM monitoring.data_quality_rules WHERE is_active AND target_table = p_table LOOP
        EXECUTE format('SELECT COUNT(*) FROM %s WHERE %s', p_table, r.rule_sql) INTO v_failed;

        INSERT INTO monitoring.data_quality_results
            (rule_id, rows_checked, rows_failed, pass_rate_pct, severity, passed)
        VALUES (
            r.rule_id, v_total, v_failed,
            ROUND(100.0 * (v_total - v_failed) / GREATEST(v_total,1), 2),
            r.severity, (v_failed = 0)
        );

        IF v_failed > 0 AND r.severity = 'Critical' THEN
            v_critical_failed := TRUE;
        END IF;
    END LOOP;

    RETURN NOT v_critical_failed;
END;
$$ LANGUAGE plpgsql;

-- -----------------------------------------------------------------------------
-- 6. Role-based access control (per business-case section 7.1, 7.4, 12)
-- -----------------------------------------------------------------------------

DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'role_data_engineer') THEN
        CREATE ROLE role_data_engineer NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'role_policy_engineer') THEN
        CREATE ROLE role_policy_engineer NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'role_bi_reader') THEN
        CREATE ROLE role_bi_reader NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'role_safety_auditor') THEN
        CREATE ROLE role_safety_auditor NOLOGIN;
    END IF;
END $$;

GRANT USAGE ON SCHEMA raw, curated TO role_data_engineer;
GRANT ALL ON ALL TABLES IN SCHEMA raw TO role_data_engineer;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA curated TO role_data_engineer;

GRANT USAGE ON SCHEMA curated, features, rewards, policies, recommendations, monitoring TO role_policy_engineer;
GRANT SELECT ON ALL TABLES IN SCHEMA curated, features, rewards TO role_policy_engineer;
GRANT ALL ON ALL TABLES IN SCHEMA policies, recommendations TO role_policy_engineer;
GRANT SELECT, INSERT ON ALL TABLES IN SCHEMA monitoring TO role_policy_engineer;

GRANT USAGE ON SCHEMA curated, features, recommendations TO role_bi_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA curated, features, recommendations TO role_bi_reader;

GRANT USAGE ON SCHEMA monitoring, mgmt TO role_safety_auditor;
GRANT SELECT ON ALL TABLES IN SCHEMA monitoring, mgmt TO role_safety_auditor;

-- -----------------------------------------------------------------------------
-- 7. Immutable audit log (append-only) — native PostgreSQL, no external tooling
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS mgmt.audit_log (
    audit_id        BIGSERIAL PRIMARY KEY,
    event_time      TIMESTAMPTZ NOT NULL DEFAULT now(),
    db_user         TEXT NOT NULL DEFAULT current_user,
    schema_name     TEXT NOT NULL,
    table_name      TEXT NOT NULL,
    operation       TEXT NOT NULL CHECK (operation IN ('INSERT','UPDATE','DELETE')),
    row_pk          TEXT,
    row_hash        TEXT
);
COMMENT ON TABLE mgmt.audit_log IS 'Append-only audit trail. Revoke UPDATE/DELETE from all roles in production to guarantee immutability.';
REVOKE UPDATE, DELETE ON mgmt.audit_log FROM PUBLIC;

CREATE OR REPLACE FUNCTION mgmt.audit_fact_hvac_decision()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO mgmt.audit_log (schema_name, table_name, operation, row_pk, row_hash)
    VALUES (
        'curated', 'fact_hvac_decision', TG_OP,
        COALESCE(NEW.record_id, OLD.record_id)::TEXT,
        md5(COALESCE(NEW::TEXT, OLD::TEXT))
    );
    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_audit_fact_hvac_decision ON curated.fact_hvac_decision;
CREATE TRIGGER trg_audit_fact_hvac_decision
    AFTER INSERT OR UPDATE OR DELETE ON curated.fact_hvac_decision
    FOR EACH ROW EXECUTE FUNCTION mgmt.audit_fact_hvac_decision();
