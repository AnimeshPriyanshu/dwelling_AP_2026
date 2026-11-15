# Database Normalization Report — Practo Doctor Appointments

**Repository:** `dwelling_AP_2026` (AP) · **Team:** T0095 Dwelling · **Section:** C · **Mentor:** Satyaki
**Members:** Animesh Priyanshu, Atul Panda, Ishan Chetwani, Rishabh Singh
**Source schema:** DE repository `DE_Project_2026` — `sql/01_schema.sql`, `docs/02_schema_design.md`
**Source data:** `seed_data.zip` (11 CSV files, 150,000 appointments, PostgreSQL 15+ target)
**Deliverable:** `dbms/01_normalization.md` (Checkpoint CP1)

---

## 1. Purpose and Scope

This report analyses the Practo doctor-appointments database for normalization. It is based on the actual PostgreSQL schema in `sql/01_schema.sql` and the 11 CSV seed files. Every table, key, functional dependency and anomaly discussed below is derived from those sources; row counts and null/empty observations come from a direct scan of the CSV files.

The schema contains **11 tables** under the `practo` schema: `cities`, `specializations`, `doctors`, `doctor_specializations`, `clinics`, `doctor_schedules`, `patients`, `appointments`, `prescriptions`, `prescription_items`, `doctor_reviews`.

---

## 2. Normal-Form Definitions

Let a **relation** be a set of tuples (rows) over a fixed set of **attributes** (columns). Let **X → Y** denote a **functional dependency (FD)**: whenever two tuples agree on all attributes in X, they also agree on all attributes in Y. X is a **determinant**.

### 2.1 Unnormalized Form (UNF)

A relation is in UNF when it is merely a table (possibly with repeating groups, multi-valued attributes or nested structures). UNF is not a "normal form" in the classical sense; it is the starting point. Repeating groups (e.g., a patient row carrying a list of appointments) and multi-valued attributes violate the atomicity expected of a relational table.

### 2.2 First Normal Form (1NF)

A relation is in **1NF** iff:

1. Every attribute contains only **atomic (indivisible)** values — no sets, lists, arrays or repeating groups in a single cell.
2. Each tuple in a relation is uniquely identifiable by some key (a primary key is a design choice, not a requirement of 1NF itself).
3. Column order and row order are immaterial.
4. No duplicate tuples (a property of a relation by convention; duplicate elimination is not strictly a 1NF rule).

Strict 1NF forbids multi-valued attributes such as `languages = {English, Hindi}` stored in one column.

### 2.3 Second Normal Form (2NF)

A relation is in **2NF** iff it is in 1NF and **every non-prime attribute is fully functionally dependent on every candidate key** — i.e., there is no **partial dependency** where a non-prime attribute depends on only a *proper subset* of a composite candidate key. 2NF is only a concern for relations with composite keys.

### 2.4 Third Normal Form (3NF)

A relation is in **3NF** iff it is in 2NF and **no non-prime attribute is transitively dependent on a candidate key** — i.e., for every non-trivial FD X → A, either X is a superkey or A is a prime attribute (part of some candidate key). Equivalently, 3NF forbids a non-prime attribute depending on another non-prime attribute.

### 2.5 Boyce-Codd Normal Form (BCNF)

A relation is in **BCNF** iff for every non-trivial FD X → Y, X is a **superkey**. BCNF is stricter than 3NF: it also removes dependencies where a non-superkey determinant determines a prime attribute. BCNF is optional at this checkpoint; it is analysed in §10.

---

## 3. Keys: Candidate, Primary, Foreign

- **Candidate key (CK):** a minimal set of attributes that uniquely identifies a tuple. Minimal means no proper subset is also unique.
- **Primary key (PK):** the candidate key chosen by the designer; enforced by PostgreSQL as `PRIMARY KEY` (also creates a B-tree index).
- **Foreign key (FK):** an attribute (or set) in one relation that references the PK of another; enforces referential integrity. `ON DELETE` actions (CASCADE/RESTRICT/SET NULL) are chosen per relationship (see §5).
- **Composite key:** a key made of two or more attributes (e.g., `(doctor_id, weekday, start_time)`).
- **Partial dependency:** a non-prime attribute depending on a proper subset of a composite key.
- **Transitive dependency:** a non-prime attribute depending on another non-prime attribute (A → B → C, where B is not a key).

---

## 4. Table-by-Table Analysis

Row counts are from the seed CSVs. "Empty" counts are columns with no value in that row.

### 4.1 `cities`

**Relation:** `cities(city_id, city_name, state)` — 10 rows.

- **Candidate keys:** `city_id` (PK); `(city_name, state)` (UNIQUE in schema). `city_name` alone is unique in the seed data (10/10) but is not declared UNIQUE, so it is an observed pattern rather than an enforced candidate key.
- **PK:** `city_id`.
- **FKs:** none (root reference table).
- **FDs:**
  - `city_id → city_name, state`
  - `(city_name, state) → city_id`
- **Partial / transitive:** none (single-attribute PK; no non-key determinant chain).
- **Normal form:** BCNF. Every determinant (`city_id`, and the composite `(city_name, state)`) is a superkey.

### 4.2 `specializations`

**Relation:** `specializations(spec_id, spec_name)` — 15 rows.

- **Candidate keys:** `spec_id` (PK); `spec_name` (UNIQUE).
- **PK:** `spec_id`.
- **FKs:** none.
- **FDs:** `spec_id → spec_name`, `spec_name → spec_id`.
- **Normal form:** BCNF — both determinants are candidate keys.

### 4.3 `doctors`

**Relation:** `doctors(doctor_id, full_name, registration_no, gender, experience_years, consultation_fee, video_fee, languages, is_verified, joined_on)` — 3,000 rows.

- **Candidate keys:** `doctor_id` (PK); `registration_no` (UNIQUE, NOT NULL).
- **PK:** `doctor_id`.
- **FKs:** none.
- **FDs:**
  - `doctor_id → full_name, registration_no, gender, experience_years, consultation_fee, video_fee, languages, is_verified, joined_on`
  - `registration_no → doctor_id, full_name, …` (candidate key)
- **Partial / transitive:** none among scalar attributes. `registration_no` is a natural candidate key; `languages` is a multi-valued attribute (see §8).
- **Nullability observed:** `video_fee` is NULL for 894 doctors (~29.8%) who do not offer video consultations.
- **Normal form:** BCNF on scalar attributes (with the array qualification of §8).

### 4.4 `doctor_specializations` (M:N junction)

**Relation:** `doctor_specializations(doctor_id, spec_id, is_primary)` — 3,700 rows.

- **Candidate keys:** `(doctor_id, spec_id)` (PK).
- **PK:** `(doctor_id, spec_id)` (composite).
- **FKs:** `doctor_id → doctors` (ON DELETE CASCADE); `spec_id → specializations` (ON DELETE RESTRICT).
- **FDs:**
  - `(doctor_id, spec_id) → is_primary`
- **Partial dependency?** No. `is_primary` depends on the *whole* composite key. A doctor has many specializations, so `doctor_id ↛ spec_id` and `doctor_id ↛ is_primary` (a doctor can have multiple rows with different `is_primary` values, one of which is true). `spec_id ↛ doctor_id`. Hence no partial dependency and the relation is in 2NF. The "at most one primary per doctor" rule is an additional constraint, not a functional dependency; it is enforced by the **partial unique index** `UNIQUE (doctor_id) WHERE is_primary`, not by a PK.
- **Transitive:** none.
- **Data observation:** every one of the 3,000 doctors has exactly one primary specialization; 700 doctors have a secondary one (2,300 doctors have one specialization, 700 have two; none has more than two). No doctor has two primaries (verified: 0 violations). Thus `doctor_id` alone does not determine `is_primary`.
- **Normal form:** BCNF.

### 4.5 `clinics`

**Relation:** `clinics(clinic_id, clinic_name, city_id, locality, latitude, longitude, phone)` — 1,500 rows.

- **Candidate keys:** `clinic_id` (PK). (`phone` is unique in the observed data but is not declared UNIQUE in the schema; treated as an observed pattern, not a constraint — see §9.)
- **PK:** `clinic_id`.
- **FKs:** `city_id → cities` (ON DELETE RESTRICT).
- **FDs:** `clinic_id → clinic_name, city_id, locality, latitude, longitude, phone`.
- **Partial / transitive:** none. `city_id` is a FK, not functionally determined by any other non-key column.
- **Normal form:** BCNF.

### 4.6 `doctor_schedules`

**Relation:** `doctor_schedules(doctor_id, weekday, start_time, end_time, clinic_id, slot_minutes)` — 30,499 rows.

- **Candidate keys:** `(doctor_id, weekday, start_time)` (PK). Verified unique across all 30,499 rows.
- **PK:** `(doctor_id, weekday, start_time)` (composite).
- **FKs:** `doctor_id → doctors` (CASCADE); `clinic_id → clinics` (RESTRICT, nullable for video slots).
- **FDs:**
  - `(doctor_id, weekday, start_time) → end_time, clinic_id, slot_minutes`
- **Partial dependency?** No. `end_time`, `clinic_id` and `slot_minutes` depend on the *combination* of doctor + weekday + start time. Verified against the seed data: of 17,400 `(doctor_id, weekday)` pairs, 10,202 span more than one clinic and 2,984 have more than one `slot_minutes` value; 1,065 of 3,000 doctors have more than one distinct `slot_minutes`. Therefore neither `doctor_id` alone nor `(doctor_id, weekday)` determines `clinic_id` or `slot_minutes`, and no non-prime attribute depends on a proper subset of the composite key. Hence 2NF holds.
- **Transitive:** none.
- **Nullability observed:** `clinic_id` is NULL for 5,899 rows (video consultation slots). This is why `clinic_id` cannot be part of the PK.
- **Normal form:** BCNF.

### 4.7 `patients`

**Relation:** `patients(patient_id, full_name, phone, email, dob, gender, blood_group, allergies, city_id, created_at)` — 40,000 rows.

- **Candidate keys:** `patient_id` (PK); `phone` (UNIQUE, NOT NULL).
- **PK:** `patient_id`.
- **FKs:** `city_id → cities` (RESTRICT).
- **FDs:**
  - `patient_id → full_name, phone, email, dob, gender, blood_group, allergies, city_id, created_at`
  - `phone → patient_id, full_name, …` (candidate key)
- **Partial / transitive:** none among scalar attributes. `email` is an *optional* unique attribute (NULL for 13,940 patients, ~34.8%); because of nullability it is not an unconditional candidate key, but every non-NULL value is unique (verified: 26,060 non-NULL, all distinct). `allergies` is a multi-valued attribute (see §8).
- **Nullability observed:** `blood_group` NULL for 3,204 patients (~8.0%); `allergies` NULL for 33,986 (~84.9%); `email` NULL for 13,940 (~34.8%).
- **Normal form:** BCNF on scalar attributes (with the array qualification of §8).

### 4.8 `appointments` (central fact table)

**Relation:** `appointments(appointment_id, patient_id, doctor_id, clinic_id, consult_type, booked_at, slot_start, slot_end, reason, status, checked_in_at, consult_started_at, consult_ended_at, fee, payment_status)` — 150,000 rows.

- **Candidate keys:** `appointment_id` (PK). No composite candidate key is declared or enforced: in particular `(patient_id, slot_start)` is not a candidate key, because the schema declares no UNIQUE on it and the seed data contains 549 duplicate `(doctor_id, slot_start)` groups among non-cancelled appointments (554 extra rows), showing that slot occupancy is not unique per doctor. Schema-enforced and observed uniqueness are therefore kept distinct.
- **PK:** `appointment_id`.
- **FKs:** `patient_id → patients` (RESTRICT); `doctor_id → doctors` (RESTRICT); `clinic_id → clinics` (RESTRICT, nullable for video).
- **FDs:**
  - `appointment_id → patient_id, doctor_id, clinic_id, consult_type, booked_at, slot_start, slot_end, reason, status, checked_in_at, consult_started_at, consult_ended_at, fee, payment_status`
- **Partial / transitive:** none among the stored columns. `patient_id`, `doctor_id` and `clinic_id` are FKs, not attributes derived from each other within this relation. There is no non-prime attribute depending on another non-prime attribute.
- **Redundant (derived) columns, kept deliberately:**
  - `fee` is derivable from `doctors.consultation_fee` / `doctors.video_fee` by `consult_type`, but is retained to preserve the fee at booking time (fees change) and because queries R16, R21, W01 reference it. Verified: in the seed data `fee` matches the doctor's current fee for that consult type in all 5,000 sampled rows; keeping it is a justified redundancy, not a normalization violation of the stored relation (it is determined by the PK, not by another non-key column of `appointments`).
  - `slot_end` is derivable from `slot_start + slot_minutes` (via `doctor_schedules`), but is retained because queries W04 use it and recomputing it would require a join on every read.
- **CHECK constraints tie columns together:** VIDEO ⇔ `clinic_id IS NULL`; IN_CLINIC ⇔ `clinic_id IS NOT NULL`; `checked_in_at` only for IN_CLINIC; REFUNDED only for CANCELLED. These are value-level (subset) constraints: they restrict combinations of specific values but do not state total functional dependencies such as `consult_type → clinic_id` (the actual clinic is not determined, only its nullability), so they do not create transitive dependencies.
- **Nullability observed:** `clinic_id` NULL for 27,856 (VIDEO); `checked_in_at` NULL for 51,180; `consult_started_at`/`consult_ended_at` NULL for 28,591 (not yet consulted). Status has no `CHECKED_IN` value in the seed (only BOOKED, CANCELLED, COMPLETED, NO_SHOW) — `CHECKED_IN` is produced by W02 at runtime.
- **Data observation:** 6,021 cancelled appointments retain `PAID` status (late cancellations without refund); 8,879 have `REFUNDED`. No `REFUNDED` row is non-cancelled (0 violations).
- **Normal form:** BCNF.

### 4.9 `prescriptions`

**Relation:** `prescriptions(prescription_id, appointment_id, diagnosis, notes, follow_up_date, issued_at)` — 97,234 rows.

- **Candidate keys:** `prescription_id` (PK); `appointment_id` (UNIQUE, NOT NULL) — enforces 1:1 with `appointments`.
- **PK:** `prescription_id`.
- **FKs:** `appointment_id → appointments` (ON DELETE CASCADE).
- **FDs:**
  - `prescription_id → appointment_id, diagnosis, notes, follow_up_date, issued_at`
  - `appointment_id → prescription_id, diagnosis, …` (candidate key)
- **Partial / transitive:** none.
- **Nullability observed:** `notes` NULL for 58,105 (~59.8%); `follow_up_date` NULL for 68,184 (~70.1%).
- **Normal form:** BCNF.

### 4.10 `prescription_items`

**Relation:** `prescription_items(prescription_id, line_no, medicine_name, dosage, duration_days, instructions)` — 243,085 rows.

- **Candidate keys:** `(prescription_id, line_no)` (PK, composite). Verified unique across all rows.
- **PK:** `(prescription_id, line_no)`.
- **FKs:** `prescription_id → prescriptions` (ON DELETE CASCADE).
- **FDs:**
  - `(prescription_id, line_no) → medicine_name, dosage, duration_days, instructions`
- **Partial dependency?** No. `medicine_name`, `dosage`, etc. depend on the specific line of a specific prescription; `prescription_id` alone does not determine them (a prescription has many items), and `line_no` alone certainly does not. 2NF holds.
- **Transitive:** none. `medicine_name` does not determine `dosage` or `duration_days` in this data: all 15 distinct medicines occur with more than one dosage and more than one duration (verified across 243,085 items).
- **Nullability observed:** `instructions` NULL for 97,233 (~40.0%).
- **Normal form:** BCNF.

### 4.11 `doctor_reviews`

**Relation:** `doctor_reviews(review_id, appointment_id, rating, recommends, wait_time_bucket, review_text, created_at)` — 30,339 rows.

- **Candidate keys:** `review_id` (PK); `appointment_id` (UNIQUE, NOT NULL) — enforces 1:1 with `appointments`.
- **PK:** `review_id`.
- **FKs:** `appointment_id → appointments` (ON DELETE CASCADE).
- **FDs:**
  - `review_id → appointment_id, rating, recommends, wait_time_bucket, review_text, created_at`
  - `appointment_id → review_id, rating, …` (candidate key)
- **Partial / transitive:** none among stored columns. `wait_time_bucket` is a **derived/redundant** attribute that could be computed from `appointments.consult_started_at − appointments.slot_start`, but it is retained because the bucket thresholds are a business decision and the patient self-reports the wait experience. It depends on the PK, not on another non-key column, so it does not create a transitive dependency.
- **Nullability observed:** `review_text` NULL for 12,069 (~39.8%); `wait_time_bucket` is never NULL in the seed.
- **Normal form:** BCNF.

---

## 5. Composite Primary Keys and Partial Dependencies

Three tables use composite primary keys. In each case the 2NF check confirms that no non-prime attribute depends on only part of the key:

| Table | Composite PK | Non-prime attributes | Partial dependency? | Reason |
|---|---|---|---|---|
| `doctor_specializations` | `(doctor_id, spec_id)` | `is_primary` | No | A doctor has many specializations; `doctor_id` alone does not determine `is_primary`. |
| `doctor_schedules` | `(doctor_id, weekday, start_time)` | `end_time, clinic_id, slot_minutes` | No | A doctor works on many weekdays and many start times; neither `doctor_id` nor `weekday` alone determines the rest. |
| `prescription_items` | `(prescription_id, line_no)` | `medicine_name, dosage, duration_days, instructions` | No | `prescription_id` alone does not determine any item attribute (one prescription has many items). |

Had these attributes depended on a proper subset of the composite key (e.g., `clinic_id` depending only on `doctor_id`), the relation would have failed 2NF and would have required decomposition. The data and FDs above show no such case.

---

## 6. Transitive Dependencies

A transitive dependency would be a chain `PK → non-key A → non-key B` where A is not a key. Checking each relation:

- `cities`: `city_id → (city_name, state)`; `(city_name, state)` is itself a candidate key — no transitive chain.
- `doctors`: no non-key attribute determines another (e.g., `experience_years` does not determine `consultation_fee`).
- `clinics`: `clinic_id → city_id → city_name`? No — `city_name` lives in `cities`, not in `clinics`; `city_id` is a FK, not a stored determinant inside `clinics`.
- `patients`: `patient_id → city_id → …` — again `city_id` is a FK to another relation; no transitive dependency inside `patients`.
- `appointments`: `appointment_id → doctor_id → consultation_fee` is **not** a transitive dependency within `appointments` because `consultation_fee` is not an attribute of `appointments` (the stored `fee` is an independent, booking-time value). `status` does not determine `payment_status` beyond the CHECK rule, which is a constraint, not an FD.
- All other tables have a single determinant (the PK or a composite PK) with no intermediate non-key determinant.

**Conclusion:** under the functional dependencies declared in `sql/01_schema.sql`, and considering each relation in isolation, no transitive dependencies exist among non-prime attributes; 3NF is therefore satisfied. Value-level implications of CHECK constraints (e.g., `payment_status = 'REFUNDED' → status = 'CANCELLED'`, `consult_type = 'VIDEO' → clinic_id IS NULL`, `checked_in_at IS NOT NULL → consult_type = 'IN_CLINIC'`) are subset constraints that hold only for specific attribute values and are not total functional dependencies, so they do not create transitive dependencies. Cross-table derivations (e.g., `appointments.fee` vs. `doctors.consultation_fee`) are not transitive dependencies within a single relation by definition.

---

## 7. Insertion, Update and Deletion Anomalies

The schema is already normalized, so the classic anomalies are avoided. The following documents where they *would* arise and how the design prevents them.

### 7.1 Insertion anomalies (avoided)

- **Cannot book an appointment without a valid patient and doctor** — FKs `appointments.patient_id → patients`, `appointments.doctor_id → doctors` (RESTRICT) prevent orphan appointments. This is desirable: an appointment without a patient is meaningless.
- **Cannot add a doctor specialization without the doctor and specialization** existing — FKs on `doctor_specializations`.
- **Cannot add a schedule without the doctor** — FK `doctor_id → doctors` (CASCADE).
- **A doctor with no specialization cannot exist in the seed** — verified: 0 doctors lack a specialization record. The schema does not force this (no CHECK), but the data satisfies it; see §9.

### 7.2 Update anomalies (avoided / controlled)

- **City rename:** changing a city name updates one row in `cities`; `clinics` and `patients` reference `city_id`, so no cascading string updates are needed.
- **Doctor fee change:** `doctors.consultation_fee` can change without rewriting 150,000 appointment rows because `appointments.fee` preserves the booking-time value. This is an intentional, justified redundancy (§4.8) rather than an update anomaly.
- **Wait-time bucket:** `doctor_reviews.wait_time_bucket` is self-reported; updating appointment timestamps does not silently change a review's bucket. This is by design.
- **Schedule slot length:** `slot_minutes` is stored per schedule block, so a change affects only future slot generation.

### 7.3 Deletion anomalies (avoided / controlled)

- **Deleting a doctor** cascades to `doctor_specializations` and `doctor_schedules` (ON DELETE CASCADE) — a doctor's dependent detail rows disappear with them, which is correct.
- **Deleting a doctor with appointments is blocked** (ON DELETE RESTRICT) — prevents losing appointment history. This is a deliberate business rule, not a normalization issue.
- **Deleting a clinic that has schedules or appointments is blocked** (RESTRICT) — prevents dangling references.
- **Deleting a specialization that is in use is blocked** (RESTRICT) — prevents orphan `doctor_specializations`.
- **Deleting an appointment cascades** to its prescription, prescription items and review (ON DELETE CASCADE) — keeps detail rows consistent.

### 7.4 Anomaly that the schema does *not* prevent (data-quality, not normalization)

- **Double bookings:** two non-cancelled appointments for the same doctor in the same slot. The schema has no UNIQUE constraint on `(doctor_id, slot_start)` among active appointments, so this is possible. R24 explicitly looks for it. This is a business-rule gap, not a normal-form violation.

---

## 8. PostgreSQL Array Columns: Exception to Strict 1NF

Two columns use PostgreSQL `TEXT[]` arrays:

| Table | Column | Empty (NULL) count | Distinct element values |
|---|---|---:|---|
| `doctors` | `languages` | 0 (NOT NULL) | 8: Bengali, English, Gujarati, Hindi, Kannada, Marathi, Tamil, Telugu |
| `patients` | `allergies` | 33,986 of 40,000 (~85%) | 7: Aspirin, Dust, Latex, Peanuts, Penicillin, Pollen, Sulfa |

### 8.1 Why they are exceptions to strict classical 1NF

Strict 1NF requires every attribute to be **atomic** — a single, indivisible value. A `TEXT[]` array stores a *set* of values in one column of one row (e.g., `languages = {English, Hindi}`). Under classical relational theory this is a **repeating group / multi-valued attribute** and therefore the relation is **not in 1NF** for that attribute. The workload queries rely on array operators (`ANY(d.languages)`, `pt.allergies @> ARRAY['Penicillin']`), which require the array type. Normalizing `languages` and `allergies` into separate tables would require rewriting R10 and R18; because the 30 workload queries must not be changed, the arrays are retained.

### 8.2 Position taken in this report

- For **scalar attributes**, every relation is in 1NF (and BCNF) as proven in §4.
- For `languages` and `allergies`, the relations are **deliberately non-1NF** under strict classical theory, accepted as a **PostgreSQL-specific, workload-driven design choice**. The BCNF analysis in §4 and §10 therefore applies to the scalar attributes and states this qualification explicitly. This matches the design doc's stated position.
- This is a documented, intentional trade-off (query compatibility) and is not presented as classical 1NF compliance.

---

## 9. Database Constraints vs. Assumptions and Observed Patterns

It is important to separate what the **database enforces** from what is merely **true of the seed data**.

### 9.1 Enforced by the database (constraints)

| Item | Enforcement |
|---|---|
| Primary keys, foreign keys, UNIQUE, NOT NULL, CHECK (25 constraints) | DDL in `sql/01_schema.sql` |
| At most one primary specialization per doctor | Partial unique index `uq_doctor_one_primary` |
| `email` uniqueness among non-NULL values | Ordinary UNIQUE (PostgreSQL allows multiple NULLs) |
| Referential integrity and ON DELETE actions | FK declarations |

### 9.2 Observed patterns in the CSV seed data (not enforced by the DB)

| Observation | Count | Enforced? |
|---|---:|---|
| At most one primary specialization per doctor | — | Yes — partial unique index `uq_doctor_one_primary` |
| At least one (exactly one) primary specialization per doctor | 3,000 / 3,000 | No — not enforced; seed data satisfies it |
| Every doctor has at least one specialization | 3,000 / 3,000 | No |
| `doctor_schedules.weekday` values are only 1–6 (no Sunday) in the seed | 17,400 (doctor,weekday) pairs | No — not enforced; observed pattern |
| `doctors.gender` values are only M/F (no X) in the seed | 3,000 / 3,000 | No — CHECK allows X; observed pattern |
| `patients.gender` includes X | 8,000 / 40,000 | No — CHECK allows X; observed pattern |
| `cities.city_name` is globally unique in the seed | 10 / 10 | No — not declared UNIQUE; observed pattern |
| `registration_no` matches `^[A-Z]{2,4}MC-\d{6}$` | 3,000 / 3,000 | Yes — CHECK |
| `phone` unique among patients | 40,000 / 40,000 | Yes — UNIQUE |
| `email` unique among non-NULL | 26,060 / 26,060 | Yes — UNIQUE |
| `clinic phone` unique in observed data | 1,500 / 1,500 | **No** — not declared UNIQUE |
| `doctor_reviews.wait_time_bucket` never NULL | 30,339 / 30,339 | No — nullable by design |
| `appointments.status` has no `CHECKED_IN` in seed | — | CHECK allows it; produced by W02 |
| `fee` matches doctor's current fee for consult type | 5,000 / 5,000 sampled | No — stored independently |
| `slot_end` consistent with schedule slot length | observed (not verified across all rows) | No — stored independently |
| Cancelled appointments with `PAID` status | 6,021 | Allowed (late cancellation) |
| No refunded payment for a non-cancelled appointment | 0 violations | Yes — CHECK |
| No VIDEO appointment with a clinic; no IN_CLINIC without one | 0 violations | Yes — CHECK |

### 9.3 Assumptions made

1. Integer surrogate keys (`*_id`) supplied by the seed data are accepted as given; no natural-key substitution is attempted.
2. `languages` and `allergies` are intentionally denormalized to arrays for workload compatibility (§8).
3. `fee`, `slot_end` and `wait_time_bucket` are retained redundancies with documented justification (§4.8, §4.11).
4. The seed data is treated as authoritative for observed patterns; constraints were written to accept all rows (25 CHECK constraints, all pass).
5. `CHECKED_IN` status exists in the domain but is absent from the seed because it is a runtime state created by W02.

---

## 10. BCNF Analysis

For every relation, every non-trivial FD has a superkey as its determinant (for scalar attributes):

| Table | Determinants that are superkeys | BCNF (scalar attrs)? |
|---|---|---|
| `cities` | `city_id`; `(city_name, state)` | Yes |
| `specializations` | `spec_id`; `spec_name` | Yes |
| `doctors` | `doctor_id`; `registration_no` | Yes |
| `doctor_specializations` | `(doctor_id, spec_id)` | Yes |
| `clinics` | `clinic_id` | Yes |
| `doctor_schedules` | `(doctor_id, weekday, start_time)` | Yes |
| `patients` | `patient_id`; `phone` | Yes |
| `appointments` | `appointment_id` | Yes |
| `prescriptions` | `prescription_id`; `appointment_id` | Yes |
| `prescription_items` | `(prescription_id, line_no)` | Yes |
| `doctor_reviews` | `review_id`; `appointment_id` | Yes |

BCNF is therefore satisfied for all scalar attributes. The two array columns (`doctors.languages`, `patients.allergies`) are the only attributes that fall outside classical 1NF/BCNF, and that exception is documented and justified in §8. No relation contains an FD where a non-superkey determinant determines an attribute, so no further decomposition is required or performed.

Observed (not enforced) candidate keys, excluded from the determinant list above because they are not declared constraints: `cities.city_name` (10/10 distinct in the seed) and `clinics.phone` (1,500/1,500 distinct in the seed).

---

## 11. Final Normalization Summary

| # | Table | Rows | Primary Key | Highest Normal Form (scalar attrs) | Key notes |
|---:|---|---:|---|---|---|
| 1 | `cities` | 10 | `city_id` | BCNF | Candidate key `(city_name, state)` |
| 2 | `specializations` | 15 | `spec_id` | BCNF | `spec_name` candidate key |
| 3 | `doctors` | 3,000 | `doctor_id` | BCNF* | `registration_no` candidate key; `video_fee` nullable; `languages` array (§8) |
| 4 | `doctor_specializations` | 3,700 | `(doctor_id, spec_id)` | BCNF | M:N junction; partial unique index for primary spec |
| 5 | `clinics` | 1,500 | `clinic_id` | BCNF | FK to `cities` |
| 6 | `doctor_schedules` | 30,499 | `(doctor_id, weekday, start_time)` | BCNF | `clinic_id` nullable (video) |
| 7 | `patients` | 40,000 | `patient_id` | BCNF* | `phone` candidate key; `email` optional unique; `allergies` array (§8) |
| 8 | `appointments` | 150,000 | `appointment_id` | BCNF | Central fact table; justified redundancies `fee`, `slot_end` |
| 9 | `prescriptions` | 97,234 | `prescription_id` | BCNF | 1:1 with `appointments` via UNIQUE `appointment_id` |
| 10 | `prescription_items` | 243,085 | `(prescription_id, line_no)` | BCNF | Composite key; dosage format CHECK |
| 11 | `doctor_reviews` | 30,339 | `review_id` | BCNF | 1:1 with `appointments`; derived `wait_time_bucket` |

\* BCNF holds for all scalar attributes; the relation contains a PostgreSQL `TEXT[]` array column that is a deliberate exception to strict classical 1NF (§8).

---

## 12. Conclusion

The Practo schema is normalized to **3NF and BCNF for all scalar attributes** across all 11 tables. There are no partial dependencies (2NF holds for the three composite-key tables) and no transitive dependencies (3NF holds). The only deviation from strict classical 1NF is the intentional use of PostgreSQL `TEXT[]` arrays for `doctors.languages` and `patients.allergies`, which is required by the supplied workload queries and is documented as a justified exception. Redundant columns (`appointments.fee`, `appointments.slot_end`, `doctor_reviews.wait_time_bucket`) are retained for performance and historical-accuracy reasons and do not violate normalization because each is determined by the primary key, not by another non-key attribute.

No decomposition beyond the existing 11 tables is warranted.
PY