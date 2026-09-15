-- =============================================================================
-- SCRIPT 02 of 04: Load the source extract and promote raw -> curated
--
-- Prerequisite: 01_schema_and_tables.sql has been executed.
-- Prerequisite: Apex_Horizon_HVAC_Bandit_Dataset.xlsx has been exported to CSV
--               (HVAC_Bandit_Decision_Log sheet -> hvac_bandit_decisions_dataset.csv)
--               and is reachable from the machine running psql.
-- =============================================================================

TRUNCATE TABLE raw.hvac_decision_stg;

\copy raw.hvac_decision_stg (record_id, decision_timestamp, building_id, climate_zone, zone_id, zone_group_id, floor_number, zone_type, conditioned_area_sqft, outdoor_dry_bulb_temp_f, outdoor_wet_bulb_temp_f, outdoor_humidity_pct, solar_radiation_index, day_type, hour_of_day, time_of_day_bucket, occupancy_estimate_pct, occupancy_source, co2_ppm, zone_temp_prior_f, zone_setpoint_prior_f, zone_temp_rate_of_change_f_per_hr, tariff_period, energy_price_usd_per_kwh, demand_response_event_flag, recent_energy_intensity_kwh_per_sqft, ahu_id, equipment_cycling_count_1hr, equipment_cumulative_runtime_hours, valve_position_prior_pct, damper_position_prior_pct, fan_speed_prior_pct, inter_zone_coupling_index, context_cluster_id, policy_id, policy_version, action_id, action_setpoint_relaxation_deg, action_fan_speed_target_pct, action_damper_target_pct, action_mode, exploration_flag, propensity_score, energy_use_kwh, energy_cost_impact_usd, comfort_deviation_f, comfort_violation_flag, hard_comfort_violation_flag, stability_penalty, equipment_stress_penalty, composite_reward, post_action_zone_temp_f, human_override_flag, data_quality_flag, record_created_timestamp) FROM 'hvac_bandit_decisions_dataset.csv' WITH (FORMAT csv, HEADER true, NULL '');

-- -----------------------------------------------------------------------------
-- 2. Run the data-quality gate. Critical failures route to quarantine.
-- -----------------------------------------------------------------------------

SELECT mgmt.run_data_quality_checks('raw.hvac_decision_stg') AS all_critical_rules_passed;

-- Review results:
--   SELECT r.rule_name, res.rows_checked, res.rows_failed, res.pass_rate_pct, res.severity
--   FROM monitoring.data_quality_results res
--   JOIN monitoring.data_quality_rules r USING (rule_id)
--   WHERE res.run_at = (SELECT MAX(run_at) FROM monitoring.data_quality_results)
--   ORDER BY res.passed, r.severity DESC;

INSERT INTO raw.hvac_decision_quarantine
SELECT s.*, 'duplicate_record_id', now()
FROM raw.hvac_decision_stg s
WHERE s.record_id IN (
    SELECT record_id FROM raw.hvac_decision_stg GROUP BY record_id HAVING COUNT(*) > 1
);

DELETE FROM raw.hvac_decision_stg
WHERE record_id IN (SELECT record_id FROM raw.hvac_decision_quarantine);

-- Safety-bound gate: any action outside mgmt.safety_bounds must never reach
-- curated (defense in depth alongside the source policy's own bound-clipping).
INSERT INTO raw.hvac_decision_quarantine
SELECT s.*, 'exceeds_safety_bound_relaxation', now()
FROM raw.hvac_decision_stg s
WHERE s.action_setpoint_relaxation_deg > (SELECT max_relaxation_deg FROM mgmt.safety_bounds WHERE scope_type = 'Global' AND is_active LIMIT 1)
   OR s.action_setpoint_relaxation_deg < -1.0
   AND s.record_id NOT IN (SELECT record_id FROM raw.hvac_decision_quarantine);

DELETE FROM raw.hvac_decision_stg
WHERE record_id IN (
    SELECT record_id FROM raw.hvac_decision_quarantine WHERE quarantine_reason = 'exceeds_safety_bound_relaxation'
);

-- -----------------------------------------------------------------------------
-- 3. Upsert master data (dimensions) BEFORE the fact table.
-- -----------------------------------------------------------------------------

INSERT INTO curated.dim_building (building_id, climate_zone, building_conditioned_sqft, building_vintage_year)
SELECT DISTINCT ON (building_id) building_id, climate_zone, NULL, NULL
FROM raw.hvac_decision_stg
ORDER BY building_id, record_id DESC
ON CONFLICT (building_id) DO UPDATE
    SET climate_zone = EXCLUDED.climate_zone;

INSERT INTO curated.dim_zone (zone_id, building_id, zone_group_id, floor_number, zone_type, conditioned_area_sqft, ahu_id)
SELECT DISTINCT ON (zone_id)
    zone_id, building_id, zone_group_id, floor_number, zone_type, conditioned_area_sqft, ahu_id
FROM raw.hvac_decision_stg
ORDER BY zone_id, record_id DESC
ON CONFLICT (zone_id) DO UPDATE
    SET building_id = EXCLUDED.building_id,
        zone_group_id = EXCLUDED.zone_group_id,
        floor_number = EXCLUDED.floor_number,
        zone_type = EXCLUDED.zone_type,
        conditioned_area_sqft = EXCLUDED.conditioned_area_sqft,
        ahu_id = EXCLUDED.ahu_id;

-- -----------------------------------------------------------------------------
-- 4. Promote to the curated decision-log fact table (idempotent via ON CONFLICT)
-- -----------------------------------------------------------------------------

INSERT INTO curated.fact_hvac_decision (
    record_id, decision_timestamp, building_id, zone_id,
    outdoor_dry_bulb_temp_f, outdoor_wet_bulb_temp_f, outdoor_humidity_pct, solar_radiation_index,
    day_type, hour_of_day, time_of_day_bucket, occupancy_estimate_pct, occupancy_source, co2_ppm,
    zone_temp_prior_f, zone_setpoint_prior_f, zone_temp_rate_of_change_f_per_hr,
    tariff_period, energy_price_usd_per_kwh, demand_response_event_flag, recent_energy_intensity_kwh_per_sqft,
    equipment_cycling_count_1hr, equipment_cumulative_runtime_hours,
    valve_position_prior_pct, damper_position_prior_pct, fan_speed_prior_pct,
    inter_zone_coupling_index, context_cluster_id,
    policy_id, policy_version, action_id, action_setpoint_relaxation_deg,
    action_fan_speed_target_pct, action_damper_target_pct, action_mode,
    exploration_flag, propensity_score,
    energy_use_kwh, energy_cost_impact_usd, comfort_deviation_f, comfort_violation_flag,
    hard_comfort_violation_flag, stability_penalty, equipment_stress_penalty, composite_reward,
    post_action_zone_temp_f, human_override_flag, data_quality_flag, record_created_timestamp
)
SELECT
    record_id, decision_timestamp, building_id, zone_id,
    outdoor_dry_bulb_temp_f, outdoor_wet_bulb_temp_f, outdoor_humidity_pct, solar_radiation_index,
    day_type, hour_of_day, time_of_day_bucket, occupancy_estimate_pct, occupancy_source, co2_ppm,
    zone_temp_prior_f, zone_setpoint_prior_f, zone_temp_rate_of_change_f_per_hr,
    tariff_period, energy_price_usd_per_kwh, demand_response_event_flag, recent_energy_intensity_kwh_per_sqft,
    equipment_cycling_count_1hr, equipment_cumulative_runtime_hours,
    valve_position_prior_pct, damper_position_prior_pct, fan_speed_prior_pct,
    inter_zone_coupling_index, context_cluster_id,
    policy_id, policy_version, action_id, action_setpoint_relaxation_deg,
    action_fan_speed_target_pct, action_damper_target_pct, action_mode,
    exploration_flag, propensity_score,
    energy_use_kwh, energy_cost_impact_usd, comfort_deviation_f, comfort_violation_flag,
    hard_comfort_violation_flag, stability_penalty, equipment_stress_penalty, composite_reward,
    post_action_zone_temp_f, human_override_flag, COALESCE(data_quality_flag, 'Complete'), record_created_timestamp
FROM raw.hvac_decision_stg
ON CONFLICT (record_id, decision_timestamp) DO UPDATE SET
    composite_reward = EXCLUDED.composite_reward,
    comfort_deviation_f = EXCLUDED.comfort_deviation_f,
    energy_cost_impact_usd = EXCLUDED.energy_cost_impact_usd,
    human_override_flag = EXCLUDED.human_override_flag,
    ingested_at = now();

-- -----------------------------------------------------------------------------
-- 5. Sanity checks
-- -----------------------------------------------------------------------------
SELECT 'dim_building' AS tbl, COUNT(*) FROM curated.dim_building
UNION ALL SELECT 'dim_zone', COUNT(*) FROM curated.dim_zone
UNION ALL SELECT 'fact_hvac_decision', COUNT(*) FROM curated.fact_hvac_decision
UNION ALL SELECT 'quarantine', COUNT(*) FROM raw.hvac_decision_quarantine;
