-- =================================================================================
-- Project: Digital Phenotyping for Staphylococcus aureus Bacteremia (SAB)
-- Dataset: MIMIC-IV v3.1
-- Author: [Your Name/GitHub Handle]
-- Description: 
--   This script extracts a patient cohort from MIMIC-IV that meets the criteria 
--   for SAB (both Hospital and Community Acquired) with sustained hypotension.
--   Logic is based on AIHW definitions and clinical manifestions.
-- =================================================================================

# case 1: Hospital-acquired SAB
# the first positive blood culture is collected more than 48 hours after hospital admission
# no data to test 'or less than 48 hours after discharge'
# sab_time is the time of the blood culture and only the first blood culture time is considered based on the definition
WITH sab_case_1 AS(
    SELECT
        m.subject_id,
        m.hadm_id,
        FIRST_VALUE(charttime) OVER(PARTITION BY m.subject_id, m.hadm_id ORDER BY charttime) AS sab_time,
        a.admittime
    FROM `physionet-data.mimiciv_3_1_hosp.microbiologyevents` m
    JOIN `physionet-data.mimiciv_3_1_hosp.admissions` a
        on m.hadm_id = a.hadm_id
    where LOWER(m.spec_type_desc) LIKE '%blood%'
        AND LOWER(m.org_name) LIKE '%staph%'
        AND LOWER(m.org_name) LIKE '%aureus%'
        AND DATETIME_DIFF(m.charttime, a.admittime, MINUTE) > 48 * 60
),



# case 2: the first positive blood culture is collected 48 hours or less after admission
# if one or more of the following key clinical criteria was met for the patient episode of SAB then it is hospital-acquired
# if not then it is community-acquired
sab_case_2 AS (
    SELECT
        m.subject_id,
        m.hadm_id,
        FIRST_VALUE(charttime) OVER(PARTITION BY m.subject_id, m.hadm_id ORDER BY charttime) AS sab_time,
        a.admittime
    FROM `physionet-data.mimiciv_3_1_hosp.microbiologyevents` m
    JOIN `physionet-data.mimiciv_3_1_hosp.admissions` a
        on m.hadm_id = a.hadm_id
    where LOWER(m.spec_type_desc) LIKE '%blood%'
        AND LOWER(m.org_name) LIKE '%staph%'
        AND LOWER(m.org_name) LIKE '%aureus%'
        AND DATETIME_DIFF(m.charttime, a.admittime, MINUTE) <= 48 * 60),


# sub-case 1: an indwelling medical device
# get all possible id for devices
indwelling_medical_device AS (
    SELECT DISTINCT p.itemid
    FROM `physionet-data.mimiciv_3_1_icu.procedureevents` p
    JOIN `physionet-data.mimiciv_3_1_icu.d_items` d ON p.itemid = d.itemid
    WHERE (LOWER(ordercategoryname) LIKE '%intravascular%'
        OR LOWER(ordercategoryname) LIKE '%dialysis%'
        OR LOWER(ordercategoryname) LIKE '%vascular%'
        OR LOWER(ordercategoryname) LIKE '%cerebrospinal%'
        OR LOWER(ordercategoryname) LIKE '%shunt%'
        OR LOWER(ordercategoryname) LIKE '%urinary%'
        OR LOWER(ordercategoryname) LIKE '%catheter%'
        OR LOWER(ordercategoryname) LIKE '%line%')
),

# find the usage of devices during admission
use_device AS(
    SELECT
        p.subject_id,
        p.hadm_id,
        p.itemid,
        p.starttime,
        p.endtime
    FROM `physionet-data.mimiciv_3_1_icu.procedureevents` p
    WHERE p.itemid IN(
        SELECT itemid FROM indwelling_medical_device
    )
),

# sub-case 1 final
# match the cases where devices were using when they had positive blood culture
sab_use_device AS(
    SELECT
        s.subject_id,
        s.hadm_id,
        s.sab_time,
        d.itemid,
        d.starttime AS device_start,
        d.endtime AS device_end
    FROM sab_case_2 s
    JOIN use_device d
    ON s.subject_id = d.subject_id
        AND s.hadm_id = d.hadm_id
        AND s.sab_time >= d.starttime
        AND s.sab_time <= d.endtime
),


# sub-case 2: SAB occurs within 30 days of a surgical procedure, where the SAB is related to the surgical site.
# Assumption 1: SAB is related to the surgical site
# Assumption 2: surgery_time as 1 day after admission because there is no exact time
# select all long title that includes surgery or sth similar, get the code and the patient who did those surgeries, estimate the surgery time,
surgery AS (
    SELECT
        pr.subject_id,
        pr.hadm_id,
        pr.icd_code,
        a.admittime,
        DATETIME_ADD(a.admittime, INTERVAL 1 DAY) AS surgery_time,
        d_pr.long_title AS procedure_name
    FROM `physionet-data.mimiciv_3_1_hosp.procedures_icd` pr
    JOIN `physionet-data.mimiciv_3_1_hosp.d_icd_procedures` d_pr
        ON pr.icd_code = d_pr.icd_code
    JOIN `physionet-data.mimiciv_3_1_hosp.admissions` a
        ON pr.hadm_id = a.hadm_id
    WHERE LOWER(d_pr.long_title) LIKE '%surgery%'
        OR LOWER(d_pr.long_title) LIKE '%procedure%'
        OR LOWER(d_pr.long_title) LIKE '%operation%'
),

# sub-case 2 final
# compare if sab happened within 30 days after the surgery
thirty_day AS(
    SELECT DISTINCT
        s.subject_id,
        s.hadm_id,
        s.sab_time,
        a.admittime,
        DATETIME_ADD(a.admittime, INTERVAL 1 DAY) AS estimated_surgery_time,
        sp.procedure_name
    FROM sab_case_2 s
    JOIN `physionet-data.mimiciv_3_1_hosp.admissions` a
        ON s.hadm_id = a.hadm_id
    JOIN surgery sp
        ON s.subject_id = sp.subject_id AND s.hadm_id = sp.hadm_id
        WHERE s.sab_time BETWEEN DATETIME_ADD(a.admittime, INTERVAL 1 DAY)
                            AND DATETIME_ADD(a.admittime, INTERVAL 30 DAY)
),

# sub-case 3: An invasive instrumentation or incision related to the SAB was performed within 48 hours.
# here is using the same device list as sub-case 1
invasive_48 AS (
    SELECT DISTINCT
        p.subject_id,
        p.hadm_id,
        p.starttime,
        p.itemid,
        s.sab_time
    FROM `physionet-data.mimiciv_3_1_icu.procedureevents` p
    JOIN sab_case_2 s
        ON p.subject_id = s.subject_id AND p.hadm_id = s.hadm_id
    WHERE p.itemid IN (SELECT itemid FROM indwelling_medical_device)
        AND ABS(DATETIME_DIFF(p.starttime, s.sab_time, HOUR)) <= 48
),
# sub-case 4: SAB is associated with neutropenia contributed to by cytotoxic therapy.
# Neutropenia is defined as at least two separate calendar days with values of absolute neutrophil count <500 cells/ mm3 (0.5 × 109/L) on
# or within a 7 day time period which includes the date the positive blood specimen was collected (day 1), the 3 calendar days before and 3 calendar days after.
sab_event AS(
    SELECT
        m.subject_id,
        m.hadm_id,
        m.charttime AS sab_time
    FROM `physionet-data.mimiciv_3_1_hosp.microbiologyevents` m
    WHERE LOWER(m.spec_type_desc) LIKE '%blood%'
        AND LOWER(m.org_name) LIKE '%staph%'
        AND LOWER(m.org_name) LIKE '%aureus%'
),

# find the id of absolute neutrophil count
anc_items AS (
    SELECT itemid FROM `physionet-data.mimiciv_3_1_hosp.d_labitems`
    WHERE LOWER(label) LIKE '%absolute neutrophil count%'
),
# find those absolute neutrophil count <500 cells/ mm3 (0.5 × 109/L)
anc_amount AS(
    SELECT
        l.subject_id,
        l.hadm_id,
        l.itemid,
        l.charttime,
        l.valueuom,
        l.comments,
        l.valuenum AS anc_value
    FROM `physionet-data.mimiciv_3_1_hosp.labevents` l
    JOIN anc_items a ON l.itemid = a.itemid
    WHERE l.valuenum < 0.5 AND l.valuenum IS NOT NULL
),

anc_preprocess AS (
    SELECT
        subject_id,
        DATE(charttime) AS test_date,
        charttime,
        anc_value
    FROM anc_amount
),

# join anc tests and sab_time, limits is 3 days before or after
anc_period AS(
    SELECT
        s.subject_id,
        s.hadm_id,
        s.sab_time,
        DATE(a.charttime) AS anc_date
    FROM sab_case_2 s
    JOIN anc_preprocess a
    ON s.subject_id = a.subject_id
    AND DATE(a.charttime) BETWEEN DATE_SUB(DATE(s.sab_time), INTERVAL 3 DAY) AND DATE_ADD(DATE(s.sab_time), INTERVAL 3 DAY)
),

# sub-case 4 final
# count the days with low anc with at least 2 days
anc_two_day AS(
    SELECT
        subject_id,
        hadm_id,
        sab_time,
        COUNT(DISTINCT anc_date) AS low_anc_days
    FROM anc_period
    GROUP BY subject_id, hadm_id, sab_time
    HAVING COUNT(DISTINCT anc_date) >= 2
),

# get id(s) and sab_time from all of them
case_1_sum AS(
    SELECT DISTINCT subject_id, hadm_id, sab_time
    FROM sab_case_1
),

case_2_sum AS(
    SELECT DISTINCT subject_id, hadm_id, sab_time
    FROM sab_case_2
),
sub_case_1_sum AS(
    SELECT DISTINCT subject_id, hadm_id, sab_time
    FROM sab_use_device
),
sub_case_2_sum AS(
    SELECT DISTINCT subject_id, hadm_id, sab_time
    FROM thirty_day
),
sub_case_3_sum AS(
    SELECT DISTINCT subject_id, hadm_id, sab_time
    FROM invasive_48
),
sub_case_4_sum AS(
    SELECT DISTINCT subject_id, hadm_id, sab_time
    FROM anc_two_day
),
# patients who belongs to case two and match at lease one of the sub cases
case_2_with_sub AS (
    SELECT DISTINCT c2.subject_id, c2.hadm_id, c2.sab_time
    FROM case_2_sum c2
    JOIN (
        SELECT * FROM sub_case_1_sum
        UNION ALL
        SELECT * FROM sub_case_2_sum
        UNION ALL
        SELECT * FROM sub_case_3_sum
        UNION ALL
        SELECT * FROM sub_case_4_sum
    ) subs ON c2.subject_id = subs.subject_id
        AND c2.hadm_id = subs.hadm_id
        AND c2.sab_time = subs.sab_time
),

# all cases that mathces the definition of sab
sab_def_cases AS (
    SELECT * FROM case_1_sum
    UNION DISTINCT
    SELECT * FROM case_2_with_sub
),

# hypotension(systolic blood pressure less than 100) lasting more than one hour
sbp_items AS(
    SELECT itemid FROM `physionet-data.mimiciv_3_1_icu.d_items`
    WHERE LOWER(label) LIKE '%systolic%' AND LOWER(label) LIKE '%blood pressure%'
),

# find those that match systolic blood pressure less than 100
sbp_less_100 AS(
    SELECT
        ce.subject_id,
        ce.hadm_id,
        ce.charttime AS low_time,
        ce.valuenum AS sbp_value
    FROM `physionet-data.mimiciv_3_1_icu.chartevents` ce
    JOIN sbp_items si ON ce.itemid = si.itemid
    WHERE valuenum IS NOT NULL AND valuenum < 100
),

# normal cases that sbp is >= 100
sbp_normal AS(
    SELECT
        ce.subject_id,
        ce.hadm_id,
        ce.charttime AS normal_time,
        ce.valuenum AS sbp_value
    FROM `physionet-data.mimiciv_3_1_icu.chartevents` ce
    JOIN sbp_items si ON ce.itemid = si.itemid
    WHERE valuenum IS NOT NULL AND valuenum >= 100
),

# get the duration that sbp < 100 lasts, match low time with next normal time and get the diff
low_sbp_time AS(
    SELECT
        l.subject_id,
        l.hadm_id,
        l.low_time,
        MIN(n.normal_time) AS recovery_time,
        DATETIME_DIFF(MIN(n.normal_time), l.low_time, MINUTE) AS duration_min
    FROM sbp_less_100 l
    JOIN sbp_normal n
        ON l.subject_id = n.subject_id
        AND l.hadm_id = n.hadm_id
        AND n.normal_time > l.low_time
    GROUP BY l.subject_id, l.hadm_id, l.low_time
),

# select those one with duration longer than 60 min
low_60 AS(
    SELECT * FROM low_sbp_time
    WHERE duration_min >= 60
),

# Assumption 3: We assume SAB happens during hypotension. We do not consider cases where hypotension starts after SAB, because we can't determine if the patient was still experiencing SAB during the hypotension.Without that information, we can't confirm whether hypotension lasted 60 minutes while SAB was present.
final AS (
    SELECT DISTINCT
        s.subject_id,
        s.hadm_id,
        s.sab_time,
        l.low_time,
        l.recovery_time,
        l.duration_min
    FROM sab_def_cases s
    JOIN low_60 l
        ON s.subject_id = l.subject_id
        AND s.hadm_id = l.hadm_id
    JOIN `physionet-data.mimiciv_3_1_hosp.admissions` a
        ON s.subject_id = a.subject_id
        AND s.hadm_id = a.hadm_id
    WHERE (
        (
            s.sab_time BETWEEN l.low_time AND l.recovery_time
            AND DATETIME_DIFF(l.recovery_time, s.sab_time, MINUTE) >= 60
        )
    )
    AND s.sab_time BETWEEN a.admittime AND a.dischtime
),

# check if any matches icd code
# convert the code that i found from previous question
# Assumption 4: assume 41.0 becomes 410, remove dot
icds_step_4 AS (
    SELECT 'A410' AS icd_code, 10 AS icd_version
    UNION ALL SELECT 'B956', 10
    UNION ALL SELECT 'P362', 10
    UNION ALL SELECT 'R788', 10
),

icd_patients AS (
    SELECT DISTINCT
        d.subject_id,
        d.hadm_id
    FROM `physionet-data.mimiciv_3_1_hosp.diagnoses_icd` d
    JOIN icds_step_4 s4
        ON d.icd_code = s4.icd_code AND d.icd_version = s4.icd_version
),

# deal with data to join to the final result table
# these are columns used for filtering, with one id that has multiple lines, choose the min one to join the final table
surgery_min_time AS (
    SELECT
        subject_id,
        hadm_id,
        sab_time,
        MIN(estimated_surgery_time) AS estimated_surgery_min_time
    FROM thirty_day
    GROUP BY subject_id, hadm_id, sab_time
),

invasive_48_min AS (
    SELECT
        subject_id,
        hadm_id,
        sab_time,
        MIN(starttime) AS invasive_starttime
    FROM invasive_48
    GROUP BY subject_id, hadm_id, sab_time
),

# Community-Acquired SAB, those who match case 2 but didn't match any sub cases
ca_sab AS (
    SELECT DISTINCT s.*
    FROM sab_case_2 s
    LEFT JOIN case_2_with_sub c
        ON s.subject_id = c.subject_id
        AND s.hadm_id = c.hadm_id
        AND s.sab_time = c.sab_time
    WHERE c.subject_id IS NULL

),
sab_classification AS (
    SELECT subject_id, hadm_id, sab_time, 'Hospital-Acquired' AS sab_type FROM case_1_sum
    UNION ALL
    SELECT subject_id, hadm_id, sab_time, 'Hospital-Acquired' AS sab_type FROM case_2_with_sub
    UNION ALL
    SELECT subject_id, hadm_id, sab_time, 'Community-Acquired' AS sab_type FROM ca_sab
),

# join all hospital-acquired cases
final_with_icd AS (
    SELECT DISTINCT
        f.subject_id,
        f.hadm_id,
        f.sab_time,
        f.low_time AS hypotension_starts,
        f.recovery_time AS hypotension_recover,
        f.duration_min AS hypotension_duration_min,
        CASE WHEN ud.subject_id IS NOT NULL THEN 'Yes' ELSE 'No' END AS presence_of_device,
        s.estimated_surgery_min_time,
        i48.invasive_starttime AS invasive_happened_min_time,
        td.low_anc_days,
        IF(ip.subject_id IS NOT NULL, TRUE, FALSE) AS has_relevant_icd,
        sc.sab_type
    FROM final f
    LEFT JOIN sab_use_device ud
        ON f.subject_id = ud.subject_id AND f.hadm_id = ud.hadm_id AND f.sab_time = ud.sab_time
    LEFT JOIN surgery_min_time s
        ON f.subject_id = s.subject_id AND f.hadm_id = s.hadm_id AND f.sab_time = s.sab_time
    LEFT JOIN anc_two_day td
        ON f.subject_id = td.subject_id AND f.hadm_id = td.hadm_id AND f.sab_time = td.sab_time
    LEFT JOIN invasive_48_min i48
        ON f.subject_id = i48.subject_id AND f.hadm_id = i48.hadm_id AND f.sab_time = i48.sab_time
    LEFT JOIN icd_patients ip
        ON f.subject_id = ip.subject_id AND f.hadm_id = ip.hadm_id
    LEFT JOIN sab_classification sc
        ON f.subject_id = sc.subject_id AND f.hadm_id = sc.hadm_id AND f.sab_time = sc.sab_time
)



# join community-acquired cases
SELECT DISTINCT * FROM final_with_icd

UNION ALL

SELECT
    cs.subject_id,
    cs.hadm_id,
    cs.sab_time,
    NULL AS hypotension_starts,
    NULL AS hypotension_recover,
    NULL AS hypotension_duration_min,
    'No' AS presence_of_device,
    NULL AS estimated_surgery_min_time,
    NULL AS invasive_happened_min_time,
    NULL AS low_anc_days,
    FALSE AS has_relevant_icd,
    'Community-Acquired' AS sab_type
FROM ca_sab cs