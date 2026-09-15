-- =============================================================================
-- SCRIPT 04 of 04: Continuous monitoring, drift detection, off-policy
--                   evaluation, and retraining automation — entirely SQL /
--                   pg_cron, per business-case 7.2 and 11 (risk register).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Monitoring tables
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS monitoring.policy_performance_log (
    log_id            BIGSERIAL PRIMARY KEY,
    policy_name         TEXT NOT NULL,
    policy_version        TEXT NOT NULL,
    evaluation_method       TEXT NOT NULL CHECK (evaluation_method IN ('Inverse Propensity Scoring','Direct Method','Doubly Robust','Online A/B')),
    evaluation_window_start DATE,
    evaluation_window_end   DATE,
    metric_name             TEXT NOT NULL,   -- e.g. 'Estimated Policy Value','RMSE','Hard-Violation Rate','Recommendation Acceptance Rate'
    metric_value              NUMERIC(12,4),
    sample_size                 INTEGER,
    logged_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE monitoring.policy_performance_log IS 'Rolling policy performance metrics, computed in SQL, for the Power BI model-ops / policy-ops dashboard.';

CREATE TABLE IF NOT EXISTS monitoring.context_drift_log (
    log_id            BIGSERIAL PRIMARY KEY,
    feature_name       TEXT NOT NULL,
    reference_mean      NUMERIC,
    current_mean          NUMERIC,
    pct_change              NUMERIC(8,4),
    drift_flag                BOOLEAN,
    evaluated_at                TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE monitoring.context_drift_log IS 'Threshold-based drift detection on key context-feature distributions (mean-shift test), e.g. outdoor temperature norms shifting with climate-year variability, occupancy pattern changes.';

CREATE TABLE IF NOT EXISTS monitoring.reward_distribution_log (
    log_id            BIGSERIAL PRIMARY KEY,
    zone_type           TEXT,
    period_start          DATE,
    period_end              DATE,
    avg_composite_reward      NUMERIC(10,4),
    stddev_composite_reward     NUMERIC(10,4),
    hard_violation_rate           NUMERIC(6,4),
    logged_at                       TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE monitoring.reward_distribution_log IS 'Reward-distribution shift tracking by zone_type, feeding both drift detection and the executive ESG/energy dashboard.';

CREATE TABLE IF NOT EXISTS monitoring.alerts (
    alert_id          BIGSERIAL PRIMARY KEY,
    alert_type          TEXT NOT NULL CHECK (alert_type IN ('Data Quality','Context Drift','Reward Drift','Policy Performance','Safety Bound','Recommendation Volume')),
    severity              TEXT NOT NULL CHECK (severity IN ('Info','Warning','Critical')),
    message                 TEXT NOT NULL,
    related_entity            TEXT,
    raised_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
    acknowledged                 BOOLEAN NOT NULL DEFAULT FALSE,
    acknowledged_by                TEXT,
    acknowledged_at                  TIMESTAMPTZ
);
COMMENT ON TABLE monitoring.alerts IS 'Unified alert feed surfaced in the Power BI executive, facilities-engineering, and Model/Policy Risk & Safety Forum dashboards.';

-- -----------------------------------------------------------------------------
-- 2. Off-policy evaluation via Inverse Propensity Scoring (IPS)
--
--    Estimates the value the CURRENT recommended policy would have achieved
--    had it been running live, using only logged (behavior-policy) data —
--    the standard, SQL-expressible technique for bandit offline evaluation
--    referenced in business-case section 7.2 ("counterfactual or offline
--    policy-evaluation approximations").
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION monitoring.evaluate_policy_ips(p_policy_name TEXT, p_policy_version TEXT)
RETURNS VOID AS $$
DECLARE
    v_ips_value NUMERIC;
    v_n INTEGER;
    v_start DATE;
    v_end DATE;
BEGIN
    SELECT MIN(f.decision_timestamp)::DATE, MAX(f.decision_timestamp)::DATE
    INTO v_start, v_end
    FROM features.hvac_test f;

    -- IPS estimator: sum( 1[recommended_action = logged_action] * reward / propensity ) / N
    SELECT
        ROUND(SUM(
            CASE WHEN r.recommended_action_id = f.action_id
                 THEN f.composite_reward / NULLIF(f.propensity_score, 0)
                 ELSE 0 END
        ) / COUNT(*), 4),
        COUNT(*)
    INTO v_ips_value, v_n
    FROM features.hvac_test f
    JOIN recommendations.hvac_action_recommendation r
      ON r.record_id = f.record_id AND r.decision_timestamp = f.decision_timestamp
     AND r.policy_name = p_policy_name AND r.policy_version = p_policy_version;

    INSERT INTO monitoring.policy_performance_log
        (policy_name, policy_version, evaluation_method, evaluation_window_start, evaluation_window_end, metric_name, metric_value, sample_size)
    VALUES
        (p_policy_name, p_policy_version, 'Inverse Propensity Scoring', v_start, v_end, 'Estimated Policy Value (IPS)', v_ips_value, v_n);

    -- Compare against the logged (behavior) policy's realized average reward
    -- over the same window as a simple lift indicator.
    INSERT INTO monitoring.policy_performance_log
        (policy_name, policy_version, evaluation_method, evaluation_window_start, evaluation_window_end, metric_name, metric_value, sample_size)
    SELECT p_policy_name, p_policy_version, 'Direct Method', v_start, v_end, 'Logged Behavior Policy Avg Reward',
           ROUND(AVG(composite_reward), 4), COUNT(*)
    FROM features.hvac_test;

    IF v_ips_value IS NOT NULL AND v_n < 200 THEN
        INSERT INTO monitoring.alerts (alert_type, severity, message, related_entity)
        VALUES ('Policy Performance', 'Warning',
                format('IPS evaluation for %s %s used only %s overlapping samples — estimate has high variance; treat as indicative only.', p_policy_name, p_policy_version, v_n),
                p_policy_name);
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION monitoring.evaluate_safety_classifier(p_policy_name TEXT DEFAULT 'apex_hvac_hard_violation_classifier')
RETURNS VOID AS $$
DECLARE
    v_precision NUMERIC;
    v_recall NUMERIC;
    v_n INTEGER;
BEGIN
    SELECT
        ROUND(SUM(CASE WHEN r.predicted_hard_violation_prob > 0.5 AND f.hard_comfort_violation_flag = 1 THEN 1 ELSE 0 END)::NUMERIC
              / NULLIF(SUM(CASE WHEN r.predicted_hard_violation_prob > 0.5 THEN 1 ELSE 0 END), 0), 4),
        ROUND(SUM(CASE WHEN r.predicted_hard_violation_prob > 0.5 AND f.hard_comfort_violation_flag = 1 THEN 1 ELSE 0 END)::NUMERIC
              / NULLIF(SUM(CASE WHEN f.hard_comfort_violation_flag = 1 THEN 1 ELSE 0 END), 0), 4),
        COUNT(*)
    INTO v_precision, v_recall, v_n
    FROM recommendations.hvac_action_recommendation r
    JOIN features.hvac_context_features_v1 f
      ON f.record_id = r.record_id AND f.decision_timestamp = r.decision_timestamp;

    INSERT INTO monitoring.policy_performance_log
        (policy_name, policy_version, evaluation_method, metric_name, metric_value, sample_size)
    VALUES
        (p_policy_name, 'v1', 'Direct Method', 'Safety Classifier Precision', v_precision, v_n),
        (p_policy_name, 'v1', 'Direct Method', 'Safety Classifier Recall', v_recall, v_n);

    IF v_recall IS NOT NULL AND v_recall < 0.7 THEN
        INSERT INTO monitoring.alerts (alert_type, severity, message, related_entity)
        VALUES ('Safety Bound', 'Critical',
                format('Hard-violation safety classifier recall dropped to %s (threshold: 0.70) — escalate to Model/Policy Risk & Safety Forum before further live recommendations.', v_recall),
                p_policy_name);
    END IF;
END;
$$ LANGUAGE plpgsql;

-- -----------------------------------------------------------------------------
-- 3. Context drift check — 30-day feature means vs. a reference baseline
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION monitoring.check_context_drift()
RETURNS VOID AS $$
DECLARE
    v_ref_mean NUMERIC;
    v_cur_mean NUMERIC;
    v_pct NUMERIC;
    v_feature TEXT;
    v_features TEXT[] := ARRAY['outdoor_dry_bulb_temp_f','occupancy_estimate_pct',
                                'equipment_cycling_risk_score','energy_price_usd_per_kwh'];
BEGIN
    FOREACH v_feature IN ARRAY v_features LOOP
        EXECUTE format(
            'SELECT AVG(%1$I) FROM features.hvac_context_features_v1
             WHERE decision_timestamp < (SELECT MAX(decision_timestamp) - INTERVAL %2$L FROM features.hvac_context_features_v1)',
             v_feature, '30 days'
        ) INTO v_ref_mean;

        EXECUTE format(
            'SELECT AVG(%1$I) FROM features.hvac_context_features_v1
             WHERE decision_timestamp >= (SELECT MAX(decision_timestamp) - INTERVAL %2$L FROM features.hvac_context_features_v1)',
             v_feature, '30 days'
        ) INTO v_cur_mean;

        v_pct := ROUND(100.0 * (v_cur_mean - v_ref_mean) / NULLIF(ABS(v_ref_mean), 0), 4);

        INSERT INTO monitoring.context_drift_log (feature_name, reference_mean, current_mean, pct_change, drift_flag)
        VALUES (v_feature, v_ref_mean, v_cur_mean, v_pct, ABS(v_pct) > 20);

        IF ABS(v_pct) > 20 THEN
            INSERT INTO monitoring.alerts (alert_type, severity, message, related_entity)
            VALUES ('Context Drift', 'Warning',
                    format('Context feature "%s" shifted %s%% vs. baseline — review seasonal/weather-year effects and consider retraining.', v_feature, v_pct),
                    v_feature);
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION monitoring.check_reward_distribution()
RETURNS VOID AS $$
BEGIN
    INSERT INTO monitoring.reward_distribution_log (zone_type, period_start, period_end, avg_composite_reward, stddev_composite_reward, hard_violation_rate)
    SELECT
        z.zone_type,
        (SELECT MAX(decision_timestamp) - INTERVAL '30 days' FROM features.hvac_context_features_v1)::DATE,
        (SELECT MAX(decision_timestamp) FROM features.hvac_context_features_v1)::DATE,
        ROUND(AVG(f.composite_reward), 4),
        ROUND(STDDEV(f.composite_reward), 4),
        ROUND(AVG(f.hard_comfort_violation_flag::NUMERIC), 4)
    FROM features.hvac_context_features_v1 f
    JOIN curated.dim_zone z ON z.zone_id = f.zone_id
    WHERE f.decision_timestamp >= (SELECT MAX(decision_timestamp) - INTERVAL '30 days' FROM features.hvac_context_features_v1)
    GROUP BY z.zone_type;
END;
$$ LANGUAGE plpgsql;

-- -----------------------------------------------------------------------------
-- 4. Scheduled jobs via pg_cron (requires: CREATE EXTENSION IF NOT EXISTS pg_cron;)
-- -----------------------------------------------------------------------------

-- CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Nightly: recompute rewards, refresh features, re-score, log drift
-- SELECT cron.schedule('apex_nightly_reward_refresh', '0 2 * * *',
--     $$SELECT rewards.compute_rewards('v1-baseline');$$);
-- SELECT cron.schedule('apex_nightly_feature_refresh', '15 2 * * *',
--     $$SELECT features.build_hvac_context_features_v1();$$);
-- SELECT cron.schedule('apex_nightly_drift_check', '30 2 * * *',
--     $$SELECT monitoring.check_context_drift(); SELECT monitoring.check_reward_distribution();$$);

-- Weekly: off-policy evaluation and safety-classifier health check
-- SELECT cron.schedule('apex_weekly_policy_eval', '0 3 * * 1',
--     $$SELECT monitoring.evaluate_policy_ips('apex_hvac_reward_regression','v1');
--       SELECT monitoring.evaluate_safety_classifier('apex_hvac_hard_violation_classifier');$$);

-- Monthly: ensure next month's fact-table partition exists ahead of load
-- SELECT cron.schedule('apex_monthly_partition', '0 0 1 * *',
--     $$SELECT mgmt.ensure_partition((CURRENT_DATE + INTERVAL '1 month')::DATE);$$);

-- Retraining trigger: simple threshold-based condition per business-case 7.2
-- ("retraining or incremental updates are triggered by scheduled jobs or
-- threshold conditions ... under formal change-control metadata").
CREATE OR REPLACE FUNCTION mgmt.retraining_required()
RETURNS TABLE(policy_name TEXT, reason TEXT) AS $$
    SELECT DISTINCT a.related_entity, a.message
    FROM monitoring.alerts a
    WHERE a.alert_type IN ('Policy Performance', 'Context Drift', 'Reward Drift', 'Safety Bound')
      AND a.severity IN ('Warning', 'Critical')
      AND a.raised_at > now() - INTERVAL '7 days'
      AND NOT a.acknowledged;
$$ LANGUAGE sql;

-- -----------------------------------------------------------------------------
-- 5. Convenience views for the Power BI decision-support layer
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW recommendations.vw_latest_zone_recommendation AS
SELECT DISTINCT ON (r.zone_id)
    r.zone_id, z.building_id, b.climate_zone, z.zone_type,
    r.recommended_action_id, r.recommended_relaxation_deg, r.predicted_reward,
    r.predicted_hard_violation_prob, r.within_safety_bounds,
    r.decision_timestamp, r.scored_at
FROM recommendations.hvac_action_recommendation r
JOIN curated.dim_zone z ON z.zone_id = r.zone_id
JOIN curated.dim_building b ON b.building_id = z.building_id
ORDER BY r.zone_id, r.scored_at DESC;
COMMENT ON VIEW recommendations.vw_latest_zone_recommendation IS 'One row per zone: most recent safety-gated recommendation, joined to master data. Primary Power BI source for the facilities-engineering workbench.';

CREATE OR REPLACE VIEW monitoring.vw_open_alerts AS
SELECT * FROM monitoring.alerts WHERE NOT acknowledged ORDER BY severity DESC, raised_at DESC;

CREATE OR REPLACE VIEW monitoring.vw_recommendation_acceptance AS
SELECT
    date_trunc('week', r.scored_at)::DATE AS week_start,
    COUNT(*) AS total_recommendations,
    COUNT(*) FILTER (WHERE o.reviewer_decision = 'Confirmed') AS confirmed_count,
    COUNT(*) FILTER (WHERE o.reviewer_decision = 'Overridden') AS overridden_count,
    ROUND(
        COUNT(*) FILTER (WHERE o.reviewer_decision = 'Confirmed')::NUMERIC / NULLIF(COUNT(o.override_id), 0), 4
    ) AS acceptance_rate
FROM recommendations.hvac_action_recommendation r
LEFT JOIN policies.human_review_overrides o ON o.record_id = r.record_id
GROUP BY 1
ORDER BY 1;
COMMENT ON VIEW monitoring.vw_recommendation_acceptance IS 'Weekly recommendation acceptance/override rates — a core Adoption & Embedding scorecard metric (business-case section 14).';
