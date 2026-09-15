-- =============================================================================
-- SCRIPT 03 of 04: Reward engineering, feature engineering (pure SQL), and the
--                   in-database contextual-bandit policy lifecycle.
--
-- Per business-case section 7.2, all training/inference happens INSIDE
-- PostgreSQL via supported ML extensions. Algorithms are restricted to
-- gradient-boosted trees (reward modelling / action ranking), regularised
-- linear/logistic models (LinUCB-style / logistic-bandit approximation), and
-- basic clustering (context discretization).
--
-- If PostgresML is not available in your environment, the equivalent MADlib
-- call pattern is shown as a fallback (commented).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Reward engineering — configurable, versioned weights (separate from raw
--    telemetry per business-case governance intent) and a recompute function.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS rewards.reward_weights (
    weight_version      TEXT PRIMARY KEY,
    energy_weight        NUMERIC(6,3) NOT NULL DEFAULT 3.2,
    comfort_weight          NUMERIC(6,3) NOT NULL DEFAULT 0.45,
    hard_violation_penalty     NUMERIC(6,3) NOT NULL DEFAULT 3.5,
    stability_weight              NUMERIC(6,3) NOT NULL DEFAULT 1.0,
    equipment_stress_weight          NUMERIC(6,3) NOT NULL DEFAULT 1.0,
    is_active                          BOOLEAN NOT NULL DEFAULT FALSE,
    approved_by                          TEXT,
    approved_at                            TIMESTAMPTZ DEFAULT now(),
    notes                                    TEXT
);
COMMENT ON TABLE rewards.reward_weights IS 'Versioned, governance-approved weighting of the composite multi-objective reward. Changing weights (e.g., valuing comfort more heavily in a premium asset) requires a new version row and Model/Policy Risk & Safety Forum sign-off, never an ad hoc edit.';

INSERT INTO rewards.reward_weights (weight_version, energy_weight, comfort_weight, hard_violation_penalty, stability_weight, equipment_stress_weight, is_active, approved_by, notes)
VALUES ('v1-baseline', 3.2, 0.45, 3.5, 1.0, 1.0, TRUE, 'Model/Policy Risk & Safety Forum', 'Initial baseline weighting matching the pilot reward formulation.')
ON CONFLICT (weight_version) DO NOTHING;

CREATE TABLE IF NOT EXISTS rewards.hvac_reward_log (
    record_id               BIGINT NOT NULL,
    decision_timestamp       TIMESTAMP NOT NULL,
    weight_version             TEXT NOT NULL REFERENCES rewards.reward_weights(weight_version),
    energy_term                  NUMERIC(10,4),
    comfort_term                   NUMERIC(10,4),
    stability_term                   NUMERIC(10,4),
    equipment_stress_term              NUMERIC(10,4),
    composite_reward                     NUMERIC(10,4) NOT NULL,
    computed_at                            TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (record_id, decision_timestamp, weight_version)
);
COMMENT ON TABLE rewards.hvac_reward_log IS 'Reproducible reward computation, versioned by weight set, kept separate from raw telemetry. Recomputable at any time from curated.fact_hvac_decision without touching source data.';

CREATE OR REPLACE FUNCTION rewards.compute_rewards(p_weight_version TEXT DEFAULT 'v1-baseline')
RETURNS VOID AS $$
DECLARE
    w RECORD;
BEGIN
    SELECT * INTO w FROM rewards.reward_weights WHERE weight_version = p_weight_version;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reward weight_version: %', p_weight_version;
    END IF;

    INSERT INTO rewards.hvac_reward_log
        (record_id, decision_timestamp, weight_version, energy_term, comfort_term, stability_term, equipment_stress_term, composite_reward)
    SELECT
        f.record_id, f.decision_timestamp, p_weight_version,
        ROUND(-1 * f.energy_cost_impact_usd * w.energy_weight, 4) AS energy_term,
        ROUND(-1 * (f.comfort_deviation_f * w.comfort_weight + f.hard_comfort_violation_flag * w.hard_violation_penalty), 4) AS comfort_term,
        ROUND(-1 * f.stability_penalty * w.stability_weight, 4) AS stability_term,
        ROUND(-1 * f.equipment_stress_penalty * w.equipment_stress_weight, 4) AS equipment_stress_term,
        ROUND(
            (-1 * f.energy_cost_impact_usd * w.energy_weight)
          + (-1 * (f.comfort_deviation_f * w.comfort_weight + f.hard_comfort_violation_flag * w.hard_violation_penalty))
          + (-1 * f.stability_penalty * w.stability_weight)
          + (-1 * f.equipment_stress_penalty * w.equipment_stress_weight)
        , 4) AS composite_reward
    FROM curated.fact_hvac_decision f
    ON CONFLICT (record_id, decision_timestamp, weight_version) DO UPDATE SET
        energy_term = EXCLUDED.energy_term,
        comfort_term = EXCLUDED.comfort_term,
        stability_term = EXCLUDED.stability_term,
        equipment_stress_term = EXCLUDED.equipment_stress_term,
        composite_reward = EXCLUDED.composite_reward,
        computed_at = now();
END;
$$ LANGUAGE plpgsql;

SELECT rewards.compute_rewards('v1-baseline');

-- -----------------------------------------------------------------------------
-- 2. Feature engineering — versioned context-feature table for policy training
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS features.hvac_context_features_v1 (
    record_id                          BIGINT,
    decision_timestamp                 TIMESTAMP,
    zone_id                            TEXT,
    building_id                        TEXT,
    climate_zone                       TEXT,
    zone_type                          TEXT,
    -- engineered context features
    weather_mildness_score             NUMERIC(6,4),   -- 1 - |outdoor_temp - 70| / 35, clipped
    occupancy_band                     TEXT,            -- Vacant/Low/Moderate/High
    is_peak_tariff                     SMALLINT,         -- 1 if On-Peak or Critical-Peak
    tariff_cost_tier                   SMALLINT,          -- 1-4 ordinal encoding of tariff_period
    hours_since_shift_start             NUMERIC(5,2),
    rolling_zone_comfort_violation_rate_7d NUMERIC(6,4), -- window function per zone
    rolling_zone_avg_reward_7d          NUMERIC(10,4),   -- window function per zone
    equipment_cycling_risk_score          NUMERIC(6,4),   -- cycling_count normalized + runtime factor
    context_cluster_id                     INTEGER,
    -- passthrough raw context features the model will also use
    outdoor_dry_bulb_temp_f            NUMERIC(6,2),
    outdoor_humidity_pct               NUMERIC(5,1),
    solar_radiation_index              NUMERIC(6,2),
    occupancy_estimate_pct             NUMERIC(5,2),
    zone_temp_rate_of_change_f_per_hr  NUMERIC(6,3),
    energy_price_usd_per_kwh           NUMERIC(8,4),
    demand_response_event_flag         SMALLINT,
    equipment_cycling_count_1hr        SMALLINT,
    inter_zone_coupling_index          NUMERIC(5,3),
    -- action taken (behavior policy) and propensity, needed for off-policy training/eval
    action_id                          INTEGER,
    action_setpoint_relaxation_deg     NUMERIC(4,1),
    exploration_flag                   SMALLINT,
    propensity_score                   NUMERIC(7,5),
    -- labels
    composite_reward                   NUMERIC(10,4),
    comfort_violation_flag             SMALLINT,
    hard_comfort_violation_flag        SMALLINT,
    feature_version                    TEXT NOT NULL DEFAULT 'v1',
    computed_at                        TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE features.hvac_context_features_v1 IS 'Versioned, policy-ready feature table for Use Case A. Rebuilt by features.build_hvac_context_features_v1(). Never edited by hand.';

CREATE OR REPLACE FUNCTION features.build_hvac_context_features_v1()
RETURNS VOID AS $$
BEGIN
    TRUNCATE TABLE features.hvac_context_features_v1;

    INSERT INTO features.hvac_context_features_v1 (
        record_id, decision_timestamp, zone_id, building_id, climate_zone, zone_type,
        weather_mildness_score, occupancy_band, is_peak_tariff, tariff_cost_tier,
        hours_since_shift_start, rolling_zone_comfort_violation_rate_7d, rolling_zone_avg_reward_7d,
        equipment_cycling_risk_score, context_cluster_id,
        outdoor_dry_bulb_temp_f, outdoor_humidity_pct, solar_radiation_index, occupancy_estimate_pct,
        zone_temp_rate_of_change_f_per_hr, energy_price_usd_per_kwh, demand_response_event_flag,
        equipment_cycling_count_1hr, inter_zone_coupling_index,
        action_id, action_setpoint_relaxation_deg, exploration_flag, propensity_score,
        composite_reward, comfort_violation_flag, hard_comfort_violation_flag
    )
    SELECT
        f.record_id, f.decision_timestamp, f.zone_id, f.building_id, b.climate_zone, z.zone_type,
        ROUND(1 - LEAST(ABS(f.outdoor_dry_bulb_temp_f - 70) / 35.0, 1), 4) AS weather_mildness_score,
        CASE
            WHEN f.occupancy_estimate_pct < 5 THEN 'Vacant'
            WHEN f.occupancy_estimate_pct < 30 THEN 'Low'
            WHEN f.occupancy_estimate_pct < 65 THEN 'Moderate'
            ELSE 'High'
        END AS occupancy_band,
        CASE WHEN f.tariff_period IN ('On-Peak','Critical-Peak') THEN 1 ELSE 0 END AS is_peak_tariff,
        CASE f.tariff_period
            WHEN 'Off-Peak' THEN 1 WHEN 'Mid-Peak' THEN 2 WHEN 'On-Peak' THEN 3 WHEN 'Critical-Peak' THEN 4
        END AS tariff_cost_tier,
        ROUND(EXTRACT(EPOCH FROM (f.decision_timestamp - date_trunc('day', f.decision_timestamp) - INTERVAL '6 hours')) / 3600.0, 2) AS hours_since_shift_start,
        ROUND(
            AVG(f.comfort_violation_flag::NUMERIC) OVER (
                PARTITION BY f.zone_id ORDER BY f.decision_timestamp
                RANGE BETWEEN INTERVAL '7 days' PRECEDING AND INTERVAL '1 second' PRECEDING
            ), 4
        ) AS rolling_zone_comfort_violation_rate_7d,
        ROUND(
            AVG(f.composite_reward) OVER (
                PARTITION BY f.zone_id ORDER BY f.decision_timestamp
                RANGE BETWEEN INTERVAL '7 days' PRECEDING AND INTERVAL '1 second' PRECEDING
            ), 4
        ) AS rolling_zone_avg_reward_7d,
        ROUND(LEAST(f.equipment_cycling_count_1hr / 6.0, 1) * 0.7 + LEAST(f.equipment_cumulative_runtime_hours / 60000.0, 1) * 0.3, 4) AS equipment_cycling_risk_score,
        f.context_cluster_id,
        f.outdoor_dry_bulb_temp_f, f.outdoor_humidity_pct, f.solar_radiation_index, f.occupancy_estimate_pct,
        f.zone_temp_rate_of_change_f_per_hr, f.energy_price_usd_per_kwh, f.demand_response_event_flag,
        f.equipment_cycling_count_1hr, f.inter_zone_coupling_index,
        f.action_id, f.action_setpoint_relaxation_deg, f.exploration_flag, f.propensity_score,
        f.composite_reward, f.comfort_violation_flag, f.hard_comfort_violation_flag
    FROM curated.fact_hvac_decision f
    JOIN curated.dim_zone z ON z.zone_id = f.zone_id
    JOIN curated.dim_building b ON b.building_id = f.building_id;
END;
$$ LANGUAGE plpgsql;

SELECT features.build_hvac_context_features_v1();

CREATE INDEX IF NOT EXISTS ix_features_hvac_v1_ts ON features.hvac_context_features_v1(decision_timestamp);
CREATE INDEX IF NOT EXISTS ix_features_hvac_v1_zone ON features.hvac_context_features_v1(zone_id);

-- -----------------------------------------------------------------------------
-- 3. Temporal train/validation/test split (SQL date-filter based, per 7.2)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW features.hvac_train AS
SELECT * FROM features.hvac_context_features_v1
WHERE decision_timestamp < (SELECT MAX(decision_timestamp) - INTERVAL '45 days' FROM features.hvac_context_features_v1);

CREATE OR REPLACE VIEW features.hvac_validation AS
SELECT * FROM features.hvac_context_features_v1
WHERE decision_timestamp BETWEEN
    (SELECT MAX(decision_timestamp) - INTERVAL '45 days' FROM features.hvac_context_features_v1)
    AND (SELECT MAX(decision_timestamp) - INTERVAL '20 days' FROM features.hvac_context_features_v1);

CREATE OR REPLACE VIEW features.hvac_test AS
SELECT * FROM features.hvac_context_features_v1
WHERE decision_timestamp > (SELECT MAX(decision_timestamp) - INTERVAL '20 days' FROM features.hvac_context_features_v1);

-- -----------------------------------------------------------------------------
-- 4. Policy registry & policy-card metadata
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS policies.policy_registry (
    policy_row_id         SERIAL PRIMARY KEY,
    policy_name            TEXT NOT NULL,
    policy_version           TEXT NOT NULL,
    use_case                  TEXT NOT NULL,
    approach                    TEXT NOT NULL CHECK (approach IN ('reward_regression','linucb_linear','logistic_safety_classifier')),
    algorithm                     TEXT NOT NULL,
    feature_table                  TEXT NOT NULL,
    target_column                    TEXT NOT NULL,
    action_space_table                 TEXT NOT NULL DEFAULT 'curated.dim_action_space',
    reward_weight_version                 TEXT REFERENCES rewards.reward_weights(weight_version),
    training_data_summary                   JSONB,
    hyperparameters                           JSONB,
    performance_metrics                         JSONB,
    intended_use                                  TEXT,
    known_limitations                               TEXT,
    safety_bound_reference                            INTEGER REFERENCES mgmt.safety_bounds(bound_id),
    risk_classification                                 TEXT CHECK (risk_classification IN ('Low','Medium','High')),
    trained_at                                            TIMESTAMPTZ NOT NULL DEFAULT now(),
    trained_by                                              TEXT NOT NULL DEFAULT current_user,
    is_active                                                 BOOLEAN NOT NULL DEFAULT FALSE,
    UNIQUE (policy_name, policy_version)
);
COMMENT ON TABLE policies.policy_registry IS 'Policy-card style registry: one row per trained policy version, per business-case section 7.2. High-risk policies (is_active on live control) require Model/Policy Risk & Safety Forum sign-off recorded via known_limitations/safety_bound_reference.';

CREATE TABLE IF NOT EXISTS policies.human_review_overrides (
    override_id       BIGSERIAL PRIMARY KEY,
    record_id          BIGINT,
    policy_row_id        INTEGER REFERENCES policies.policy_registry(policy_row_id),
    recommended_action_id INTEGER REFERENCES curated.dim_action_space(action_id),
    reviewer_decision      TEXT CHECK (reviewer_decision IN ('Confirmed','Overridden','Escalated')),
    reviewer_id               TEXT,
    reviewer_comment            TEXT,
    reviewed_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE policies.human_review_overrides IS 'Human-in-the-loop review/override capture for high-impact recommendations, feeding future retraining cycles (business-case design principle: human-in-the-loop and supervised autonomy by deliberate design).';

-- -----------------------------------------------------------------------------
-- 5. Train the reward model via PostgresML
--    Requires: CREATE EXTENSION IF NOT EXISTS pgml;   (run once, superuser)
-- -----------------------------------------------------------------------------

-- CREATE EXTENSION IF NOT EXISTS pgml;

-- 5a. Reward-regression model: predicts composite_reward given context + action
--     (this IS the bandit's value function — used to rank candidate actions
--      per context at scoring time, approximating a disjoint-model bandit).
SELECT * FROM pgml.train(
    project_name  => 'apex_hvac_reward_regression',
    task          => 'regression',
    relation_name => 'features.hvac_train',
    y_column_name => 'composite_reward',
    algorithm     => 'xgboost',
    hyperparams   => '{"n_estimators": 300, "max_depth": 6, "learning_rate": 0.05}'
);

-- 5b. Safety classifier: predicts probability of a hard comfort-band violation
--     given context + action, used as a hard gate ahead of any recommendation.
SELECT * FROM pgml.train(
    project_name  => 'apex_hvac_hard_violation_classifier',
    task          => 'classification',
    relation_name => 'features.hvac_train',
    y_column_name => 'hard_comfort_violation_flag',
    algorithm     => 'xgboost',
    hyperparams   => '{"n_estimators": 200, "max_depth": 4, "learning_rate": 0.05}'
);

-- 5c. LinUCB-style linear approximation (regularised linear regression on the
--     same feature set) — kept alongside the tree model for a transparent,
--     interpretable-coefficient fallback and for confidence-bound approximation.
SELECT * FROM pgml.train(
    project_name  => 'apex_hvac_reward_linucb_linear',
    task          => 'regression',
    relation_name => 'features.hvac_train',
    y_column_name => 'composite_reward',
    algorithm     => 'ridge'
);

-- ---- MADlib fallback pattern (use if PostgresML extension is unavailable) ----
-- SELECT madlib.xgboost_train(
--     'features.hvac_train', 'policies.reward_xgb_model', 'record_id', 'composite_reward',
--     'ARRAY[outdoor_dry_bulb_temp_f, occupancy_estimate_pct, action_setpoint_relaxation_deg, ...]'
-- );

INSERT INTO policies.policy_registry
    (policy_name, policy_version, use_case, approach, algorithm, feature_table, target_column,
     reward_weight_version, training_data_summary, hyperparameters, intended_use, known_limitations,
     risk_classification, is_active)
VALUES
    ('apex_hvac_reward_regression', 'v1', 'Contextual Bandit Zone Set-Point Selection', 'reward_regression', 'xgboost',
     'features.hvac_context_features_v1', 'composite_reward', 'v1-baseline',
     jsonb_build_object('training_rows', (SELECT COUNT(*) FROM features.hvac_train)),
     '{"n_estimators": 300, "max_depth": 6, "learning_rate": 0.05}',
     'Ranks candidate setpoint-relaxation actions per observed context to select the highest-expected-reward action within safety bounds.',
     'Trained on logged (behavior-policy) data with a 15% exploration rate; off-policy bias is mitigated via propensity weighting in evaluation (script 04) but residual confounding is possible for rarely-explored context-action combinations.',
     'High', TRUE),
    ('apex_hvac_hard_violation_classifier', 'v1', 'Contextual Bandit Zone Set-Point Selection', 'logistic_safety_classifier', 'xgboost',
     'features.hvac_context_features_v1', 'hard_comfort_violation_flag', 'v1-baseline',
     jsonb_build_object('training_rows', (SELECT COUNT(*) FROM features.hvac_train)),
     '{"n_estimators": 200, "max_depth": 4, "learning_rate": 0.05}',
     'Hard safety gate: any action with predicted hard-violation probability above threshold is excluded from recommendation regardless of predicted reward.',
     'Rare-event classifier (~1% positive rate); recommend conservative threshold and mandatory human review of any borderline case.',
     'High', TRUE),
    ('apex_hvac_reward_linucb_linear', 'v1', 'Contextual Bandit Zone Set-Point Selection', 'linucb_linear', 'ridge',
     'features.hvac_context_features_v1', 'composite_reward', 'v1-baseline',
     jsonb_build_object('training_rows', (SELECT COUNT(*) FROM features.hvac_train)),
     '{}',
     'Transparent linear approximation used for confidence-bound style exploration bonuses and as an interpretable cross-check on the tree-based reward model.',
     'Lower predictive accuracy than the gradient-boosted model on non-linear context interactions; used as a complement, not a replacement.',
     'Medium', TRUE)
ON CONFLICT (policy_name, policy_version) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 6. Score (recommend) and write results back into PostgreSQL
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS recommendations.hvac_action_recommendation (
    recommendation_id         BIGSERIAL PRIMARY KEY,
    record_id                  BIGINT NOT NULL,
    zone_id                     TEXT NOT NULL,
    decision_timestamp           TIMESTAMP NOT NULL,
    policy_name                    TEXT NOT NULL,
    policy_version                   TEXT NOT NULL,
    recommended_action_id              INTEGER NOT NULL REFERENCES curated.dim_action_space(action_id),
    recommended_relaxation_deg           NUMERIC(4,1),
    predicted_reward                       NUMERIC(10,4),
    predicted_hard_violation_prob             NUMERIC(7,5),
    within_safety_bounds                        BOOLEAN NOT NULL DEFAULT TRUE,
    confidence_band_width                         NUMERIC(10,4),
    top_contributing_factors                        JSONB,
    scored_at                                         TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_reco_zone ON recommendations.hvac_action_recommendation(zone_id, scored_at);
COMMENT ON TABLE recommendations.hvac_action_recommendation IS 'Batch-scored, safety-gated recommendation output consumed by the Power BI decision-support layer. One row per (context, best safety-permitted action).';

-- Illustrative scoring pattern: for each test-set context row, evaluate every
-- candidate action in curated.dim_action_space through both models, exclude
-- any action whose predicted hard-violation probability exceeds the
-- threshold or whose relaxation exceeds the active safety bound, then keep
-- the remaining action with the highest predicted reward.
-- NOTE: the pgml.predict(...) call shape below is illustrative of the
-- PostgresML API; confirm exact syntax against the installed extension
-- version (some versions expect an explicit FLOAT4[] feature array rather
-- than a row/record). Validate with a LIMIT 10 run before scoring in full.

WITH candidate_grid AS (
    SELECT t.*, a.action_id AS candidate_action_id, a.action_setpoint_relaxation_deg AS candidate_relaxation_deg
    FROM features.hvac_test t
    CROSS JOIN curated.dim_action_space a
    WHERE a.is_within_safety_bounds
),
scored AS (
    SELECT
        candidate_grid.*,
        pgml.predict('apex_hvac_reward_regression', ROW(candidate_grid.*)) AS predicted_reward,
        pgml.predict('apex_hvac_hard_violation_classifier', ROW(candidate_grid.*)) AS predicted_hard_violation_prob
    FROM candidate_grid
),
ranked AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY record_id, decision_timestamp
            ORDER BY (CASE WHEN predicted_hard_violation_prob < 0.15 THEN 1 ELSE 0 END) DESC, predicted_reward DESC
        ) AS rnk
    FROM scored
)
INSERT INTO recommendations.hvac_action_recommendation
    (record_id, zone_id, decision_timestamp, policy_name, policy_version,
     recommended_action_id, recommended_relaxation_deg, predicted_reward,
     predicted_hard_violation_prob, within_safety_bounds)
SELECT
    record_id, zone_id, decision_timestamp, 'apex_hvac_reward_regression', 'v1',
    candidate_action_id, candidate_relaxation_deg, predicted_reward,
    predicted_hard_violation_prob,
    (candidate_relaxation_deg BETWEEN -1.0 AND (SELECT max_relaxation_deg FROM mgmt.safety_bounds WHERE scope_type='Global' AND is_active LIMIT 1))
FROM ranked
WHERE rnk = 1;
