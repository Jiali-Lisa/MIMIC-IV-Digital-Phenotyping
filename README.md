# MIMIC-IV Digital Phenotyping: Staphylococcus aureus Bacteremia (SAB)

This repository contains a high-quality SQL implementation for extracting and classifying a clinical cohort of patients with **Staphylococcus aureus Bacteremia (SAB)** using the **MIMIC-IV v3.1** database.

## 📌 Project Overview
Digital phenotyping is a crucial step in clinical machine learning to accurately identify patient cohorts that raw ICD codes might miss. This project implements a phenotype for SAB based on **AIHW (Australian Institute of Health and Welfare)** definitions and identifies severe cases with sustained hypotension.

## 🏥 Clinical Logic
The algorithm classifies SAB into two types based on timing and clinical context:

1. **Hospital-Acquired (HA-SAB):**
   * Positive blood culture collected >48 hours after admission.
   * **OR** Collected ≤48 hours after admission but meeting key clinical criteria:
     * Presence of an indwelling medical device.
     * Occurred within 30 days of surgery.
     * Invasive instrumentation/incision within 48 hours.
     * Associated with neutropenia (Absolute Neutrophil Count < 500 cells/mm³).

2. **Community-Acquired (CA-SAB):**
   * [cite_start]Positive blood culture collected ≤48 hours after admission without meeting HA-SAB sub-criteria.

### Sustained Hypotension Criteria
The cohort is further filtered for patients experiencing **hypotension** (Systolic Blood Pressure < 100 mmHg) lasting at least **one hour** during the SAB episode.

## 🛠️ SQL Implementation Highlights
* **Temporal Analysis:** Uses BigQuery `DATETIME_DIFF` and `DATETIME_ADD` to precisely handle admission windows and surgical recovery periods.
* **Window Functions:** Utilizes `FIRST_VALUE` to identify the sentinel (first) microbiology event for surveillance.
* **Complexity Handling:** Employs multiple **Common Table Expressions (CTEs)** to modularize the logic for devices, neutropenia, and blood pressure monitoring.
* **Terminology Mapping:** The final table includes a comparison against standard **ICD-10** codes (`A41.0`, `B95.6`, etc.) to evaluate the sensitivity of administrative labels.



## 📂 Data Source
The queries are designed to run on the **MIMIC-IV** dataset (hosted on Google BigQuery via PhysioNet). Tables queried include:
* `microbiologyevents` (Infection evidence)
* `chartevents` (Vital signs / Blood pressure)
* `labevents` (Neutrophil counts)
* `procedureevents` & `procedures_icd` (Clinical interventions)

## ⚖️ Assumptions
* **Surgery Timing:** Due to the lack of exact timestamps in `procedures_icd`, surgery time is estimated as 1 day after hospital admission.
* **Hypotension Overlap:** SAB is considered linked to hypotension only if the positive culture occurs during the hypotensive episode lasting >60 minutes.

---
*Note: This project was completed as part of the COMP90089: Machine Learning Applications for Health at the University of Melbourne.*
