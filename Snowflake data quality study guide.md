# Data Quality in Snowflake: Study Guide

**Scope:** Snowflake's native Data Quality Monitoring feature: data metric functions (DMFs), expectations, anomaly detection, scheduling, results, notifications, remediation, access control, cost and limits.

**Verified against:** official Snowflake documentation, read on 5 October 2026. Source pages are listed in [section 20](#20-sources). Anything that is *not* taken from those pages is labelled **Author note**.

**Edition:** Data Quality Monitoring requires Enterprise Edition or higher. Trial accounts don't support it.

---

## Contents

01. [Why Snowflake needs a separate data quality mechanism](#1-why-snowflake-needs-a-separate-data-quality-mechanism)
02. [Mental model](#2-mental-model)
03. [Core concepts](#3-core-concepts)
04. [System DMFs](#4-system-dmfs)
05. [Custom DMFs](#5-custom-dmfs)
06. [Associating a DMF with an object](#6-associating-a-dmf-with-an-object)
07. [Scheduling](#7-scheduling)
08. [Expectations](#8-expectations)
09. [Anomaly detection](#9-anomaly-detection)
10. [Checks by group (WITHIN GROUP)](#10-checks-by-group-within-group)
11. [Schema-level monitoring](#11-schema-level-monitoring)
12. [Viewing results](#12-viewing-results)
13. [Notifications](#13-notifications)
14. [Remediation with SYSTEM$DATA_METRIC_SCAN](#14-remediation-with-systemdata_metric_scan)
15. [Monitoring in Snowsight](#15-monitoring-in-snowsight)
16. [Access control](#16-access-control)
17. [Cost](#17-cost)
18. [Limitations, consolidated](#18-limitations-consolidated)
19. [Worked example, comparisons and self-check](#19-worked-example-comparisons-and-self-check)
20. [Sources](#20-sources)

---

## 1. Why Snowflake needs a separate data quality mechanism

> **Author note (background, not from the pages in section 20):** on standard Snowflake tables, only `NOT NULL` constraints are enforced. `PRIMARY KEY`, `UNIQUE` and `FOREIGN KEY` can be declared but are informational, so duplicate keys and orphaned foreign keys load without error. Verify this against the Snowflake constraints documentation before quoting it.

The consequence is that uniqueness, referential integrity, valid values and freshness have to be *measured after the fact*. Data Quality Monitoring is Snowflake's built-in way to do that measuring continuously, inside the platform, without a third-party tool.

---

## 2. Mental model

```
 DMF  ──associate──▶  TABLE / VIEW  ──schedule──▶  RESULT (a number)
 (what to measure)    (where)          (when)            │
                                                        ▼
                                  ┌─────────────────────┴─────────────────────┐
                                  │                                           │
                            EXPECTATION                              ANOMALY DETECTION
                      (your rule: VALUE = 0)                  (learned range from history)
                                  │                                           │
                                  └─────────────────────┬─────────────────────┘
                                                        ▼
                                         VIOLATION / ANOMALY recorded
                                                        │
                                  ┌─────────────────────┼─────────────────────┐
                                  ▼                     ▼                     ▼
                            NOTIFICATION          SNOWSIGHT UI          REMEDIATION
                          (email, webhook)     (monitoring page)   (SYSTEM$DATA_METRIC_SCAN)
```

The single most important idea: **a DMF only returns a number.** It does not say whether the number is good or bad. The verdict comes from an expectation (a rule you write) or from anomaly detection (a range Snowflake learns).

---

## 3. Core concepts

| Term | Meaning |
| --- | --- |
| **Data metric function (DMF)** | A function that measures one attribute of your data (NULL count, freshness, row count and so on) and returns a value. The building block of a quality check. |
| **System DMF** | A DMF supplied and maintained by Snowflake in `SNOWFLAKE.CORE`. You can't rename or change one. |
| **Custom DMF** | A DMF you write with `CREATE DATA METRIC FUNCTION` when no system DMF fits. |
| **Association** | The link between a DMF and a table or view, including which columns are passed as arguments. Created with `ALTER TABLE ... ADD DATA METRIC FUNCTION`. |
| **Expectation** | A Boolean expression attached to an association. DMF + expectation = a data quality check. A result that makes the expression FALSE is an *expectation violation*. |
| **Anomaly detection** | An algorithm trained on a DMF's history that flags results above or below a predicted range. Currently for volume and freshness. |
| **DMF schedule** | How often the DMFs on an object run. Default: once an hour. |

### Supported object kinds

| You **can** set a DMF on | You **cannot** set a DMF on |
| --- | --- |
| Table (including temporary and transient) | Hybrid table |
| View | Stream |
| Materialized view | |
| Dynamic table | |
| External table | |
| Apache Iceberg table | |
| Event table | |

---

## 4. System DMFs

All system DMFs live in the `CORE` schema of the shared `SNOWFLAKE` database, so they are referenced as `SNOWFLAKE.CORE.<name>`. Snowflake groups them into six categories.

### Accuracy

Each of these exists as a `_COUNT` and a `_PERCENT` variant.

| DMF family | What it measures |
| --- | --- |
| `NULL_COUNT` / `NULL_PERCENT` | NULL values in a column |
| `BLANK_COUNT` / `BLANK_PERCENT` | Blank values in a column |
| `NEGATIVE_COUNT` / `NEGATIVE_PERCENT` | Negative values in a numeric column |
| `ZERO_COUNT` / `ZERO_PERCENT` | Values equal to zero in a numeric column |
| `FUTURE_TIMESTAMP_COUNT` / `_PERCENT` | Date/timestamp values later than the scheduled evaluation time |
| `INVALID_JSON_COUNT` / `_PERCENT` | Non-NULL strings that aren't valid JSON |
| `INVALID_NUMERIC_TYPE_CAST_COUNT` / `_PERCENT` | Non-NULL strings that can't be parsed as a number |
| `CASE_FORMAT_VIOLATION_COUNT` / `_PERCENT` | Non-NULL strings with inconsistent casing (not all upper, all lower or title case) |
| `SPECIAL_CHARACTER_COUNT` / `_PERCENT` | Non-NULL strings containing non-alphanumeric characters |
| `UNTRIMMED_STRING_COUNT` / `_PERCENT` | Non-NULL strings with leading or trailing whitespace |

### Freshness

| DMF | What it measures |
| --- | --- |
| `FRESHNESS` | How fresh the data is, from a timestamp column or from the most recent DML operation |
| `DATA_METRIC_SCHEDULE_TIME` | Building block for writing your own freshness metric |

> **Source discrepancy:** the system DMF reference table spells this `DATA_METRIC_SCHEDULE_TIME`; the SQL function reference lists it as `DATA_METRIC_SCHEDULED_TIME`. Check the function reference before using it in code.

### Schema

| DMF | What it measures |
| --- | --- |
| `SCHEMA_CHANGE_COUNT` | Column adds, drops, renames or type changes detected between consecutive evaluations |

### Statistics

| DMF | What it measures |
| --- | --- |
| `AVG`, `MIN`, `MAX`, `MEDIAN`, `STDDEV`, `VARIANCE` | Basic statistics of a column |
| `APPROX_QUANTILE_25`, `_50`, `_99` | Approximate 25th, 50th and 99th percentile of a numeric column |
| `STRING_LENGTH_AVG`, `_MIN`, `_MAX` | String length of non-NULL values |
| `OUTLIER_COUNT` / `OUTLIER_PERCENT` | Values outside the asymmetric Tukey fences |
| `OUTLIER_IQR_COUNT` / `_PERCENT` | Values outside the standard Tukey fences (1.5 × interquartile range) |
| `OUTLIER_ZSCORE_COUNT` / `_PERCENT` | Values with a Z-score above 3 |
| `EXTREME_OUTLIER_COUNT` / `_PERCENT` | Values outside the extreme asymmetric Tukey fences |
| `EXTREME_OUTLIER_IQR_COUNT` / `_PERCENT` | Values outside the extreme Tukey fences (3 × interquartile range) |
| `EXTREME_OUTLIER_ZSCORE_COUNT` / `_PERCENT` | Values with a Z-score above 4.5 |

### Uniqueness

| DMF | What it measures |
| --- | --- |
| `DUPLICATE_COUNT` | Duplicate values in a column, **including** NULLs |
| `UNIQUE_COUNT` | Unique, **non-NULL** values in a column |
| `ACCEPTED_VALUES` | Whether values match a Boolean expression (the docs file this under Uniqueness) |

### Volume

| DMF | What it measures |
| --- | --- |
| `ROW_COUNT` | Number of records in the table or view |

> **Source discrepancy:** the "checks by group" page and the 10.16 release notes refer to a system DMF named `REFERENTIAL_INTEGRITY_COUNT`. It does not appear in the system DMF reference table as retrieved on 5 October 2026. Confirm its availability in your account before relying on it; the custom DMF in section 5 covers the same need.

---

## 5. Custom DMFs

Use a custom DMF when no system DMF expresses your rule: a business rule across columns, a pattern check, or a cross-table referential check.

### Rules

- Created with `CREATE DATA METRIC FUNCTION`; requires the `CREATE DATA METRIC FUNCTION` privilege on the schema. That privilege does **not** let you create ordinary UDFs (that needs `CREATE FUNCTION`).
- The return type can only be `NUMBER`.
- Arguments are *table* arguments: `arg_t TABLE(arg_c1 <type>, ...)`.
- `CREATE OR ALTER DATA METRIC FUNCTION` updates a DMF in place rather than dropping and recreating it.
- A DMF can be made secure (`SECURE` keyword, or `ALTER FUNCTION ... SET SECURE`) and can carry tags.
- A custom DMF **cannot be dropped** while it is still associated with any table or view.

### Single-table example

```sql
-- Count rows whose email doesn't look like an email address
CREATE OR REPLACE DATA METRIC FUNCTION dq.dmfs.invalid_email_count(
  arg_t TABLE (arg_c VARCHAR)
)
RETURNS NUMBER
AS
$$
  SELECT COUNT_IF(
    NOT REGEXP_LIKE(arg_c, '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$')
  )
  FROM arg_t
$$;
```

### Multi-table example: referential integrity

A custom DMF can take more than one table argument. The table you attach it to becomes the first argument; you name the second table, fully qualified, when you associate it.

```sql
-- Count child rows whose key has no parent
CREATE OR REPLACE DATA METRIC FUNCTION dq.dmfs.orphan_count(
  arg_child  TABLE (arg_fk NUMBER),
  arg_parent TABLE (arg_pk NUMBER)
)
RETURNS NUMBER
AS
$$
  SELECT COUNT(*)
  FROM arg_child
  WHERE arg_fk IS NOT NULL
    AND arg_fk NOT IN (SELECT arg_pk FROM arg_parent WHERE arg_pk IS NOT NULL)
$$;

-- orders is the child; customers is named as the second table argument
ALTER TABLE sales_db.sales.orders
  ADD DATA METRIC FUNCTION dq.dmfs.orphan_count
    ON (customer_id, TABLE (sales_db.sales.customers (customer_id)));
```

A result above 0 means there are orders pointing at customers that don't exist.

### Housekeeping

```sql
-- Describe (the signature must be given)
DESC FUNCTION dq.dmfs.invalid_email_count(TABLE(VARCHAR));

-- List DMFs
SHOW DATA METRIC FUNCTIONS IN ACCOUNT;

-- Make secure
ALTER FUNCTION dq.dmfs.invalid_email_count(TABLE(VARCHAR)) SET SECURE;

-- Drop (only after every association is removed)
DROP FUNCTION dq.dmfs.invalid_email_count(TABLE(VARCHAR));
```

---

## 6. Associating a DMF with an object

### After the object exists

```sql
-- Column-level metric
ALTER TABLE sales.orders
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_COUNT ON (customer_id);

-- Table-level metric: ROW_COUNT takes no column
ALTER TABLE sales.orders
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.ROW_COUNT ON ();

-- ACCEPTED_VALUES takes the column plus a lambda;
-- it returns how many rows do NOT satisfy the expression
ALTER TABLE sales.orders
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.ACCEPTED_VALUES
    ON (status, status -> status IN ('NEW', 'SHIPPED', 'CANCELLED'));

-- Views use ALTER VIEW with the same clause
ALTER VIEW sales.v_open_orders
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.ROW_COUNT ON ();
```

The same DMF can be attached to the same object several times as long as the column arguments differ.

### At creation time

The `WITH DATA METRIC FUNCTION` clause starts monitoring the moment the object exists.

```sql
CREATE OR REPLACE TABLE sales.payments (
  payment_id NUMBER,
  order_id   NUMBER,
  amount     NUMBER(12,2)
)
WITH DATA METRIC FUNCTION (
  SNOWFLAKE.CORE.DUPLICATE_COUNT ON (payment_id)
    EXPECTATION unique_payment (VALUE = 0),
  SNOWFLAKE.CORE.NEGATIVE_COUNT ON (amount)
    EXPECTATION no_negative_amount (VALUE = 0)
);
```

Points to remember:

- For tables and event tables the clause follows the column definitions. For views, materialized views and dynamic tables it goes **before** `AS SELECT`.
- Multiple bindings are comma-separated inside one pair of parentheses; don't repeat the `WITH DATA METRIC FUNCTION` keywords.
- The form without enclosing parentheses still works but is deprecated.

| Statement | What happens to DMF bindings |
| --- | --- |
| Any binding invalid | The whole `CREATE` fails; nothing is left half-attached (atomic) |
| `CREATE OR REPLACE` | Old object and all its bindings are replaced from scratch |
| `CREATE IF NOT EXISTS` on an existing object | No-op; existing bindings unchanged |
| `CLONE` | Clone inherits the source's bindings |
| `LIKE` | New object inherits the source table's bindings |

### Per-association properties

An association can carry: `EXPECTATION`, `ANOMALY_DETECTION`, `SENSITIVITY`, `WITHIN GROUP`, `GROUP LIMIT`, `EXECUTE AS ROLE`, `DATA_QUALITY_NOTIFICATION`. Each is covered in its own section below.

### Removing an association

```sql
ALTER TABLE sales.orders
  DROP DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_COUNT ON (customer_id);
```

---

## 7. Scheduling

The `DATA_METRIC_SCHEDULE` object parameter controls how often DMFs run. **All DMFs on one table or view share one schedule.** The default is one hour.

### Three ways to schedule

| Mode | Example value | Use when |
| --- | --- | --- |
| Interval in minutes | `'5 MINUTE'` | You want a fixed cadence |
| Cron expression | `'USING CRON 0 8 * * * UTC'` | You want checks aligned to a load window or business hours |
| Trigger on change | `'TRIGGER_ON_CHANGES'` | You want checks only when DML changes the table |

```sql
ALTER TABLE sales.orders SET DATA_METRIC_SCHEDULE = '5 MINUTE';
ALTER TABLE sales.orders SET DATA_METRIC_SCHEDULE = 'USING CRON 0 8 * * MON,TUE,WED,THU,FRI UTC';
ALTER TABLE sales.orders SET DATA_METRIC_SCHEDULE = 'TRIGGER_ON_CHANGES';

-- Inspect (views and materialized views also use IN TABLE)
SHOW PARAMETERS LIKE 'DATA_METRIC_SCHEDULE' IN TABLE sales.orders;
```

### Caveats

- Reclustering does **not** fire a trigger-based schedule.
- The trigger mode is only available for certain kinds of tables (see `ALTER TABLE ... SET DATA_METRIC_SCHEDULE`), and it can't be set at schema level.
- Schedule changes take about **10 minutes** to apply to DMFs already on the table. Newly added DMFs aren't subject to that lag.
- When analysing results, filter on `measurement_time` (when the metric was actually evaluated), not the scheduled time. DML can land between the two.

### Suspending and resuming

```sql
-- One DMF
ALTER TABLE sales.orders
  MODIFY DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_COUNT ON (customer_id) SUSPEND;
ALTER TABLE sales.orders
  MODIFY DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_COUNT ON (customer_id) RESUME;

-- Every DMF on the table: empty schedule
ALTER TABLE sales.orders SET DATA_METRIC_SCHEDULE = '';
```

### Calling a DMF by hand

Useful for testing before you associate anything. Unscheduled calls are not billed as Data Quality Monitoring (section 17).

```sql
SELECT SNOWFLAKE.CORE.NULL_COUNT(SELECT customer_id FROM sales.orders);

-- Custom DMF with two table arguments: each query in its own parentheses
SELECT dq.dmfs.orphan_count(
  (SELECT customer_id FROM sales.orders),
  (SELECT customer_id FROM sales.customers)
);
```

`ROW_COUNT` and the schedule-time DMF take no arguments, so they don't follow this pattern.

---

## 8. Expectations

An expectation turns a metric into a pass/fail check.

### The expression

- `VALUE` is a keyword standing for whatever the DMF returned.
- TRUE means the expectation is met; FALSE is reported as a violation.
- Allowed operators: `=`, `!=`, `<>`, `<`, `>`, `<=`, `>=`, `AND`, `OR`, `NOT`, `EQUAL_NULL`.
- Not allowed: references to other tables, views or UDFs; subqueries; arithmetic on `VALUE`; quoting `VALUE` as a string; string casts.
- One association can hold several expectations. Names must be unique within an association but can repeat across associations.

### Lifecycle

```sql
-- Add with the association
ALTER TABLE sales.orders
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_COUNT ON (customer_id)
    EXPECTATION no_null_customer (VALUE = 0);

-- Two thresholds on one metric: a warning tier and a critical tier
ALTER TABLE sales.orders
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.FRESHNESS ON (loaded_at)
    EXPECTATION fresh_warn (VALUE < 3600),
                fresh_crit (VALUE < 14400);

-- Add to an existing association
ALTER TABLE sales.orders
  MODIFY DATA METRIC FUNCTION SNOWFLAKE.CORE.DUPLICATE_COUNT ON (order_id)
    ADD EXPECTATION unique_order (VALUE = 0);

-- Change the expression
ALTER TABLE sales.orders
  MODIFY DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_COUNT ON (customer_id)
    MODIFY EXPECTATION no_null_customer (VALUE < 5);

-- Remove
ALTER TABLE sales.orders
  MODIFY DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_COUNT ON (customer_id)
    DROP EXPECTATION no_null_customer;
```

### Test now, without waiting for the schedule

```sql
SELECT *
FROM TABLE(SYSTEM$EVALUATE_DATA_QUALITY_EXPECTATIONS(
  REF_ENTITY_NAME => 'sales_db.sales.orders'));
```

### Where violations show up

| Object | What it is |
| --- | --- |
| `SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS_RAW` | Dedicated event table with raw results. With an expectation, each run writes one row for the DMF evaluation (`EVALUATION_RESULT`) plus one row per expectation (`EXPECTATION_VIOLATION_STATUS`). |
| `SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_EXPECTATION_STATUS` (view) | Flattened, easier to query |
| `DATA_QUALITY_MONITORING_EXPECTATION_STATUS` (table function) | Same information, different access-control model |

### Auditing which expectations exist

```sql
-- For one object
SELECT *
FROM TABLE(INFORMATION_SCHEMA.DATA_METRIC_FUNCTION_EXPECTATIONS(
  REF_ENTITY_NAME   => 'sales_db.sales.orders',
  REF_ENTITY_DOMAIN => 'table'));

-- Account-wide
SELECT *
FROM SNOWFLAKE.ACCOUNT_USAGE.DATA_METRIC_FUNCTION_EXPECTATIONS
ORDER BY expectation_name;
```

---

## 9. Anomaly detection

> **Status:** the documentation marks anomaly detection as a Preview feature (open to Enterprise Edition accounts and above).

Expectations need you to know the acceptable value in advance. Anomaly detection is for cases where you don't: Snowflake trains an algorithm on the DMF's history and flags results outside a predicted range.

### What it works on

| DMF | Detects anomalies in |
| --- | --- |
| `ROW_COUNT` | Data volume |
| `FRESHNESS` | How often the table is updated |

### Training period

| DMF cadence | Minimum history | Notes |
| --- | --- | --- |
| Runs frequently | 2 weeks | Needed to learn weekly seasonality. Trains on up to 60 days if available; Snowflake recommends 60 days for high confidence (monthly seasonality). |
| Infrequent or trigger-based | 2 data points | Example: a monthly DMF needs two months of history. |

While training, the `anomaly_detection_status` column of `DATA_METRIC_FUNCTION_REFERENCES` shows `TRAINING_IN_PROGRESS`.

### Commands

```sql
-- Enable when associating
ALTER TABLE sales.orders
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.ROW_COUNT ON ()
    ANOMALY_DETECTION = TRUE;

-- Enable on an existing association
ALTER TABLE sales.orders
  MODIFY DATA METRIC FUNCTION SNOWFLAKE.CORE.ROW_COUNT ON ()
    SET ANOMALY_DETECTION = TRUE;

-- Tune sensitivity: LOW, MEDIUM (default) or HIGH
ALTER TABLE sales.orders
  MODIFY DATA METRIC FUNCTION SNOWFLAKE.CORE.ROW_COUNT ON ()
    SET SENSITIVITY = 'HIGH';

-- Disable
ALTER TABLE sales.orders
  MODIFY DATA METRIC FUNCTION SNOWFLAKE.CORE.ROW_COUNT ON ()
    SET ANOMALY_DETECTION = FALSE;
```

| Symptom | Adjustment |
| --- | --- |
| Too many false positives | Set sensitivity to `LOW` (fewer anomalies) |
| Real problems being missed | Set sensitivity to `HIGH` (more anomalies) |

### Reading the results

- Event table: with anomaly detection on, each run writes a second row with record type `ANOMALY_DETECTION_STATUS`. The evaluation result holds the returned value and a Boolean for "was this an anomaly". Extra fields give `upper_bound`, `lower_bound` and `forecast`.
- Flattened view: `SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_ANOMALY_DETECTION_STATUS`.
- The DMF schedule does not control how often Snowflake checks for an anomaly.

---

## 10. Checks by group (WITHIN GROUP)

> **Status:** generally available as of release 10.16 (4 to 6 May 2026).

By default a DMF returns one number for the whole column or table. `WITHIN GROUP` evaluates it once per distinct combination of grouping columns, giving one result row per group (for example NULL count per region).

```sql
ALTER TABLE sales.orders
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_COUNT ON (customer_id)
    WITHIN GROUP (region, channel)
    GROUP LIMIT 200;
```

### Rules

- `GROUP LIMIT` is two keywords with no equals sign and must come straight after `WITHIN GROUP`. Valid range 1 to 1000; default 1000.
- If the number of groups at evaluation time exceeds the limit, the evaluation **fails and writes no results** for that run.
- Grouping columns and limit are fixed at creation. To change them, drop and re-create the association.
- Only one association is allowed per DMF + table + column combination, so one grouping per combination.
- Works with most system DMFs and most custom DMFs. Not supported: `FRESHNESS`, `REFERENTIAL_INTEGRITY_COUNT`, schema-level associations.
- `ANOMALY_DETECTION` is automatically disabled when `WITHIN GROUP` is present.
- It can be combined with the `FILTER` clause on the same association (see "Apply data quality checks to a subset of rows" in the docs; not covered in this guide).
- Some metrics aren't additive: per-group `AVG` or `STDDEV` can't be combined into the table-level figure.

### Custom DMF compatibility with WITHIN GROUP

| DMF body structure | Supported |
| --- | --- |
| Single table query | Yes |
| Subquery | Yes |
| `FLATTEN` | Yes |
| `JOIN` | No |
| CTE | No |
| `UNION` / `UNION ALL` | No |
| `DISTINCT` | No |
| Window functions | No |

### Results and notifications

- Results carry a `GROUP_BY_INFO` array column (empty for non-grouped associations) identifying the group.
- Expectations are evaluated per group, and per-group results are recorded.
- **Notifications are not per group.** One evaluation fires at most one notification, based on the worst group (maximum metric value).

```sql
SELECT metric_name, value, group_by_info
FROM SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS
WHERE table_name = 'ORDERS' AND metric_name = 'NULL_COUNT'
ORDER BY measurement_time DESC;
```

---

## 11. Schema-level monitoring

One statement can associate a DMF with every supported object in a schema. Only two system DMFs are allowed here: `ROW_COUNT` and `FRESHNESS`.

```sql
ALTER SCHEMA sales
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.ROW_COUNT ON ()
    ANOMALY_DETECTION = TRUE
    EXCLUDE_TABLE_TYPES = ('VIEW', 'MATERIALIZED_VIEW');

-- Schema schedule (default 60 minutes)
ALTER SCHEMA sales SET DATA_METRIC_SCHEDULE = '120 MINUTE';
```

### Key behaviours

- Anomalies are detected per object, not for the schema as a whole. `ANOMALY_DETECTION` defaults to FALSE.
- `EXCLUDE_TABLE_TYPES` accepts `'DYNAMIC_TABLE'`, `'EVENT_TABLE'`, `'EXTERNAL_TABLE'`, `'ICEBERG_TABLE'`, `'MATERIALIZED_VIEW'`, `'TABLE'`, `'VIEW'` and `'TRANSIENT'`.
- `'TABLE'` excludes every table including transient ones. To skip only transient tables, use `'TRANSIENT'`.
- Session temporary tables are never associated at schema level (per a pending behaviour change).
- `FRESHNESS` needs a column argument on views and external tables, so a schema-level `FRESHNESS` skips those.
- A trigger-based schedule can't be set at schema level.
- `WITHIN GROUP` isn't supported at schema level.

### Overriding for one object

The schema statement creates ordinary object-level associations, so you can override them:

```sql
-- Turn off anomaly detection for one table
ALTER TABLE sales.stg_orders
  MODIFY DATA METRIC FUNCTION SNOWFLAKE.CORE.ROW_COUNT ON ()
    SET ANOMALY_DETECTION = FALSE;

-- Stop monitoring one table altogether
ALTER TABLE sales.stg_orders
  DROP DATA METRIC FUNCTION SNOWFLAKE.CORE.ROW_COUNT ON ();
```

Results expose a `level` column: `TABLE` (associated directly) or `SCHEMA` (created by a schema-level statement).

```sql
SELECT *
FROM TABLE(INFORMATION_SCHEMA.DATA_METRIC_FUNCTION_REFERENCES(
  REF_ENTITY_NAME   => 'sales_db.sales',
  REF_ENTITY_DOMAIN => 'schema'));
```

---

## 12. Viewing results

Three routes to the same data, with different access requirements.

| Route | Object | Best when | Required role |
| --- | --- | --- | --- |
| Raw event table | `SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS_RAW` | You want raw data to build your own views or procedures, and grant those selectively | `SNOWFLAKE.DATA_QUALITY_MONITORING_ADMIN` application role |
| Flattened view | `SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS` | No post-processing needed and you don't want to expose raw data | `..._ADMIN` or `SNOWFLAKE.DATA_QUALITY_MONITORING_VIEWER` application role |
| Table function | `DATA_QUALITY_MONITORING_RESULTS(...)` | You want to limit access to one table's results | `..._ADMIN`, `..._VIEWER` or `..._LOOKUP` application role, plus USAGE on the DMF and SELECT or OWNERSHIP on the table |

Notes:

- `PUBLIC` is granted the `DATA_QUALITY_MONITORING_LOOKUP` application role, so any role can call the table function (subject to the DMF and table privileges).
- The table function returns the same columns as the view but accepts only one table per call.
- `SNOWFLAKE.GOVERNANCE_VIEWER` does **not** grant access to the results view.
- If an association specifies `EXECUTE AS ROLE`, that role must be active in your session to use the table function.

```sql
SELECT measurement_time, table_name, metric_name, value
FROM SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS
WHERE table_name = 'ORDERS'
ORDER BY measurement_time DESC;
```

### Seeing what is attached to an object

```sql
SELECT *
FROM TABLE(INFORMATION_SCHEMA.DATA_METRIC_FUNCTION_REFERENCES(
  REF_ENTITY_NAME   => 'sales_db.sales.orders',
  REF_ENTITY_DOMAIN => 'table'));
```

This output is also where you read the schedule and schedule status, the role the DMF runs as, anomaly-detection status, notification status and grouping configuration. A status such as `SUSPENDED_INSUFFICIENT_PRIVILEGE_TO_EXECUTE_DATA_METRIC_FUNCTION` tells you the table owner role lost the `EXECUTE DATA METRIC FUNCTION` privilege.

---

## 13. Notifications

A notification can be sent whenever an expectation is violated or an anomaly is detected. Notifications are switched on **per database**; individual associations can then opt out.

### Workflow

1. **Decide who is notified.** Either list email addresses directly in the database settings, or create a notification integration (email, or webhook for systems such as Slack).
2. **Grant privileges to the database owner:** `MANAGE DATA QUALITY` on the account, plus `USAGE` on any integration used.
3. **Turn notifications on** with `ALTER DATABASE ... SET DATA_QUALITY_MONITORING_SETTINGS`, a dollar-quoted YAML block.

```sql
-- 1. Email integration (recipients must be verified addresses)
CREATE NOTIFICATION INTEGRATION dq_email_int
  TYPE = EMAIL
  ENABLED = TRUE
  ALLOWED_RECIPIENTS = ('data-team@example.com');

-- 2. Privileges for the role that owns the database
GRANT MANAGE DATA QUALITY ON ACCOUNT TO ROLE data_steward;
GRANT USAGE ON INTEGRATION dq_email_int TO ROLE data_steward;

-- 3. Database settings
ALTER DATABASE sales_db SET DATA_QUALITY_MONITORING_SETTINGS =
$$
notification:
  enabled: TRUE
  integrations:
    - DQ_EMAIL_INT
  cooldown_hours: 4
  metadata_included: TRUE
$$;
```

| Setting | Effect |
| --- | --- |
| `enabled` | Notifications on or off for the database |
| `email_recipients` | Email addresses, without needing an integration |
| `integrations` | One or more notification integrations (multiple channels allowed) |
| `cooldown_hours` | Minimum gap between notifications |
| `metadata_included` | Whether the message names the affected object and DMF |

### Opting one association out

```sql
ALTER TABLE sales.orders
  MODIFY DATA METRIC FUNCTION SNOWFLAKE.CORE.BLANK_COUNT ON (notes)
    SET DATA_QUALITY_NOTIFICATION = FALSE;
```

Check the `data_quality_notification_status` column of `DATA_METRIC_FUNCTION_REFERENCES` to see whether notifications are on for an association.

---

## 14. Remediation with SYSTEM$DATA_METRIC_SCAN

A DMF tells you *how many* rows are bad. `SYSTEM$DATA_METRIC_SCAN` returns *which* rows.

### Supported DMFs

Only these six system DMFs: `NULL_COUNT`, `NULL_PERCENT`, `BLANK_COUNT`, `BLANK_PERCENT`, `DUPLICATE_COUNT`, `ACCEPTED_VALUES`. Custom DMFs can't be used.

### Usage

```sql
-- Rows with a NULL customer_id
SELECT *
FROM TABLE(SYSTEM$DATA_METRIC_SCAN(
  REF_ENTITY_NAME => 'sales_db.sales.orders',
  METRIC_NAME     => 'snowflake.core.null_count',
  ARGUMENT_NAME   => 'customer_id'));

-- Same check against the table as it was at a past moment (Time Travel)
SELECT *
FROM TABLE(SYSTEM$DATA_METRIC_SCAN(
  REF_ENTITY_NAME => 'sales_db.sales.orders',
  METRIC_NAME     => 'snowflake.core.null_count',
  ARGUMENT_NAME   => 'customer_id',
  AT_TIMESTAMP    => '2026-10-01 02:00:00 +0530'));

-- ACCEPTED_VALUES needs ARGUMENT_EXPRESSION; rows that do NOT match are returned
SELECT *
FROM TABLE(SYSTEM$DATA_METRIC_SCAN(
  REF_ENTITY_NAME     => 'sales_db.sales.orders',
  METRIC_NAME         => 'snowflake.core.accepted_values',
  ARGUMENT_NAME       => 'status',
  ARGUMENT_EXPRESSION => 'status IN (''NEW'', ''SHIPPED'', ''CANCELLED'')'));

-- Only one group of a grouped association
SELECT *
FROM TABLE(SYSTEM$DATA_METRIC_SCAN(
  REF_ENTITY_NAME     => 'sales_db.sales.orders',
  METRIC_NAME         => 'snowflake.core.null_count',
  ARGUMENT_NAME       => 'customer_id',
  WITHIN_GROUP_VALUES => '{"REGION": "APAC"}'));
```

### Fixing data with it

Because it is a table function, its output can drive DML:

```sql
-- Turn blank emails into NULLs
UPDATE sales.customers c
SET email = NULL
WHERE c.customer_id IN (
  SELECT customer_id
  FROM TABLE(SYSTEM$DATA_METRIC_SCAN(
    REF_ENTITY_NAME => 'sales_db.sales.customers',
    METRIC_NAME     => 'snowflake.core.blank_count',
    ARGUMENT_NAME   => 'email')));
```

### Cautions

- On a table protected by a masking or row access policy, results depend on the caller's role and can be incomplete or unexpected.
- For `ACCEPTED_VALUES`, the scan uses the expression you pass in the call and ignores the one stored on the association.

---

## 15. Monitoring in Snowsight

**Path:** Catalog » Explorer » select the object » **Data Quality** tab » **Monitoring**. If nothing is attached yet, **Set up** opens a pre-filled worksheet.

### What the page shows

- **Quality Dimensions:** system DMFs grouped by category (Accuracy, Freshness and so on); all custom DMFs under **Custom**. One row per association, with the latest result and a seven-day trend.
- **Run Schedule** widget: the object's `DATA_METRIC_SCHEDULE`.
- **Checks by dimension** widget: red means at least one DMF in that group failed a check.

### Investigating a failure: the documented six steps

| Step | Question | Where to look |
| --- | --- | --- |
| 1 | Were there any failed checks? | Count at the top of the Monitoring page |
| 2 | Which category failed? | Checks by dimension widget |
| 3 | Which association failed? | Expand the category, scan the Quality Checks column |
| 4 | What exactly is the check? | Side panel » Quality Checks: Name, Expression, Status |
| 5 | What else is affected? | Side panel » Impacted Assets |
| 6 | Which records failed? | Side panel » View failed records (supported system DMFs only) |

### Side panel details

- **View Lineage:** lineage of the object behind the DMF.
- **View failed records:** opens a worksheet pre-filled with a `SYSTEM$DATA_METRIC_SCAN` query.
- **Impacted Assets:** downstream objects in lineage. For a single-column DMF, a downstream object is listed only if it actually contains data from that column. For a multi-column DMF, all downstream objects are listed.
- **Run History:** the DMF's result over time.

There is also an account-wide data quality monitoring dashboard, and a data profiling feature; see the docs pages "Using the data quality monitoring dashboard" and "Use data profiling to understand your data" (not covered in this guide). The intro page also describes **Cortex Data Quality**, which uses AI to suggest checks from your metadata and usage patterns.

---

## 16. Access control

### Common tasks

| Task | Required |
| --- | --- |
| Associate a DMF with a table or view | `EXECUTE DATA METRIC FUNCTION` on the account **and** USAGE on the DMF **and** either OWNERSHIP on the table, or SELECT on the table with that role named in `EXECUTE AS ROLE` |
| View associations | USAGE on the DMF and SELECT on the object |
| Set the schedule | OWNERSHIP on the table, or any privilege on the table plus `EXECUTE DATA METRIC FUNCTION` on the account |
| Create a custom DMF | `CREATE DATA METRIC FUNCTION` on the schema |
| Call a DMF manually | USAGE on the DMF and SELECT on the object in the call |
| Add a DMF to a schema | OWNERSHIP on the schema, `MANAGE DATA QUALITY` and `EXECUTE DATA METRIC FUNCTION` on the account, and the `SNOWFLAKE.DATA_METRIC_USER` database role |
| Set up notifications | Database owner needs `MANAGE DATA QUALITY` on the account and USAGE on any integration |

### Things that trip people up

- **Database roles can't hold global privileges.** If an object is owned by a database role, transfer ownership to a custom or system role before setting a DMF on it.
- **Who the DMF runs as.** Without `EXECUTE AS ROLE`, the DMF runs as the table owner. This matters because masking and row access policies can behave differently per role.
- **`EXECUTE AS ROLE` lets a non-owner own the checks.** A data governor with only SELECT can attach and run DMFs. It can't be changed with `MODIFY`; drop and re-create the association.
- **Custom DMF grants need the signature.**
- **Schema-level:** the DMF stops running if the schema owner loses `MANAGE DATA QUALITY`.

```sql
-- Non-owner association
ALTER TABLE sales.orders
  ADD DATA METRIC FUNCTION dq.dmfs.invalid_email_count ON (contact_email)
    EXECUTE AS ROLE dq_analyst;

-- Grant on a custom DMF: arguments must be specified
GRANT USAGE ON FUNCTION dq.dmfs.invalid_email_count(TABLE(VARCHAR)) TO ROLE data_engineer;
```

### A minimal role setup

Adapted from the grants shown in Snowflake's getting-started tutorial:

```sql
GRANT EXECUTE DATA METRIC FUNCTION ON ACCOUNT TO ROLE dq_role;
GRANT DATABASE ROLE SNOWFLAKE.DATA_METRIC_USER TO ROLE dq_role;
GRANT APPLICATION ROLE SNOWFLAKE.DATA_QUALITY_MONITORING_VIEWER TO ROLE dq_role;
GRANT DATABASE ROLE SNOWFLAKE.USAGE_VIEWER TO ROLE dq_role;          -- usage views
GRANT CREATE DATA METRIC FUNCTION ON SCHEMA dq.dmfs TO ROLE dq_role; -- custom DMFs
```

---

## 17. Cost

| Item | Billed? |
| --- | --- |
| Creating a DMF | No |
| Calling a DMF manually in a `SELECT` | Not billed as Data Quality Monitoring |
| A **scheduled** DMF computing on an object | Yes: serverless compute, shown as "Data Quality Monitoring" on the bill |
| Writing results to the event table | Yes: shown as "Logging" |
| Snowflake's own background checks behind the dashboard preview | No |

Rates are in the Snowflake Service Consumption Table.

```sql
-- Credits used by DMFs
SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.DATA_QUALITY_MONITORING_USAGE_HISTORY LIMIT 100;

-- Daily metering; filter service_type = 'DATA_QUALITY_MONITORING'
SELECT * FROM SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY
WHERE service_type = 'DATA_QUALITY_MONITORING';
```

> **Author note:** the cost levers that follow from the above are the schedule frequency (every DMF on the table runs each time), the number of associations, and table size. `TRIGGER_ON_CHANGES` avoids paying for runs on tables that haven't changed.

---

## 18. Limitations, consolidated

**Platform**

- Enterprise Edition or higher; not available in trial accounts.
- 50,000 DMF associations per account. Each DMF set on a table or view counts as one.
- No DMFs on hybrid tables or streams.
- No DMFs on shared tables or views, and no granting DMF privileges to a share.
- No DMFs on objects in a reader account.
- Setting a DMF on an object tag isn't supported.

**Scheduling**

- One schedule per object, shared by all its DMFs.
- About 10 minutes for schedule changes to reach existing DMFs.
- Trigger mode: limited table kinds, not fired by reclustering, not available at schema level.

**Expectations**

- No cross-table references, UDFs, subqueries or arithmetic on `VALUE`.

**Anomaly detection**

- Preview; `ROW_COUNT` and `FRESHNESS` only; needs a training period; disabled under `WITHIN GROUP`.

**Grouping**

- Max 1000 groups; immutable after creation; no `FRESHNESS`; not at schema level; restricted custom DMF shapes.

**Schema-level**

- `ROW_COUNT` and `FRESHNESS` only; `FRESHNESS` skips views and external tables; no session temporary tables.

**Remediation**

- `SYSTEM$DATA_METRIC_SCAN` supports six system DMFs only; no custom DMFs; policy-protected tables may return incomplete rows.

**Custom DMFs**

- Return type `NUMBER` only; can't be dropped while associated.

---

## 19. Worked example, comparisons and self-check

### 19.1 End-to-end example

> **Author note:** this scenario is written for this guide. Every statement uses syntax documented in the sources; object names are invented.

**Scenario:** `sales_db.sales.orders` is loaded daily. Requirements: no duplicate `order_id`, no NULL `customer_id`, every `customer_id` exists in `customers`, `status` is one of three values, data no older than 26 hours, and an alert if daily volume looks abnormal.

```sql
-- 1. Schedule: run after the 06:00 UTC load
ALTER TABLE sales_db.sales.orders
  SET DATA_METRIC_SCHEDULE = 'USING CRON 30 6 * * * UTC';

-- 2. Uniqueness
ALTER TABLE sales_db.sales.orders
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.DUPLICATE_COUNT ON (order_id)
    EXPECTATION unique_order_id (VALUE = 0);

-- 3. Completeness
ALTER TABLE sales_db.sales.orders
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_COUNT ON (customer_id)
    EXPECTATION no_null_customer (VALUE = 0);

-- 4. Referential integrity (custom DMF from section 5)
ALTER TABLE sales_db.sales.orders
  ADD DATA METRIC FUNCTION dq.dmfs.orphan_count
    ON (customer_id, TABLE (sales_db.sales.customers (customer_id)))
    EXPECTATION no_orphan_orders (VALUE = 0);

-- 5. Validity
ALTER TABLE sales_db.sales.orders
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.ACCEPTED_VALUES
    ON (status, status -> status IN ('NEW', 'SHIPPED', 'CANCELLED'))
    EXPECTATION valid_status (VALUE = 0);

-- 6. Freshness: 26 hours = 93600 seconds
ALTER TABLE sales_db.sales.orders
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.FRESHNESS ON (loaded_at)
    EXPECTATION fresh_within_26h (VALUE < 93600);

-- 7. Volume: no fixed threshold, let Snowflake learn the pattern
ALTER TABLE sales_db.sales.orders
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.ROW_COUNT ON ()
    ANOMALY_DETECTION = TRUE;

-- 8. Verify immediately rather than waiting for 06:30
SELECT *
FROM TABLE(SYSTEM$EVALUATE_DATA_QUALITY_EXPECTATIONS(
  REF_ENTITY_NAME => 'sales_db.sales.orders'));

-- 9. Confirm what is attached and its status
SELECT *
FROM TABLE(INFORMATION_SCHEMA.DATA_METRIC_FUNCTION_REFERENCES(
  REF_ENTITY_NAME   => 'sales_db.sales.orders',
  REF_ENTITY_DOMAIN => 'table'));
```

Then switch on notifications for `sales_db` (section 13), and when a check fails, pull the offending rows with `SYSTEM$DATA_METRIC_SCAN` (section 14). Note that step 4's custom DMF can't be scanned that way; for orphans you would run the DMF's own query logic by hand.

### 19.2 Side-by-side comparisons

**Expectation vs anomaly detection**

| | Expectation | Anomaly detection |
| --- | --- | --- |
| Who defines "bad" | You, as a Boolean expression | Snowflake, from history |
| Works with | Any system or custom DMF | `ROW_COUNT` and `FRESHNESS` only |
| Ready when | Immediately | After training (2 weeks, or 2 data points) |
| Best for | Hard rules: zero duplicates, zero NULLs | Patterns you can't pin to one number: daily volume, load cadence |
| Tuning | Edit the expression | `SENSITIVITY` LOW / MEDIUM / HIGH |
| Status | Generally available | Preview |
| Why one wins | Precise and explainable; no false positives if the rule is right | Catches problems you didn't think to write a rule for |

**System DMF vs custom DMF**

| | System DMF | Custom DMF |
| --- | --- | --- |
| Setup | None | You write and maintain SQL |
| Cross-table checks | No | Yes, with multiple table arguments |
| `SYSTEM$DATA_METRIC_SCAN` support | Six of them | None |
| `WITHIN GROUP` support | Most | Only simple query shapes |
| Schema-level association | `ROW_COUNT`, `FRESHNESS` | No |

**Schedule modes**

| | Interval | Cron | Trigger on changes |
| --- | --- | --- | --- |
| Runs when | Every N minutes | At set clock times | After DML on the table |
| Pays for runs on unchanged data | Yes | Yes | No |
| Catches a load that never arrived | Yes (freshness keeps aging) | Yes | No: nothing changes, so nothing runs |
| Schema-level | Yes | Yes | No |

> **Author note on the last row of "catches a load that never arrived":** this follows from how the trigger works rather than from an explicit statement in the docs. If "the load didn't run" is a failure you need to detect, pair trigger-based tables with a time-based freshness check elsewhere.

**DMFs vs dbt tests**

> **Author note:** this comparison is commentary, not from Snowflake's documentation.

| | Snowflake DMFs | dbt tests |
| --- | --- | --- |
| When they run | On a schedule or on change, independent of any pipeline | During `dbt build` / `dbt test` |
| Can block bad data from flowing downstream | No, they observe | Yes, a failing test stops the run |
| Cover objects dbt doesn't build | Yes | Only if declared as sources |
| History and trend | Stored automatically in the event table | Needs extra packages or tooling |
| Compute | Serverless, billed separately | Your warehouse |
| Portability | Snowflake only | Any dbt adapter |

They are complementary: dbt tests as a build-time gate, DMFs as continuous monitoring between runs.

### 19.3 Self-check questions

**Q1. A DMF returns 12. Is that a data quality problem?**
Not on its own. A DMF only measures. It becomes pass or fail when compared with an expectation, or when anomaly detection judges it against a learned range.

**Q2. You set `'5 MINUTE'` on a table with eight DMFs. Can two of them run hourly instead?**
No. All DMFs on a table or view share one schedule. You can suspend individual DMFs, but not give them a different cadence.

**Q3. What is the default schedule if you never set one?**
One hour.

**Q4. Which DMFs support anomaly detection, and how long before it starts working?**
`ROW_COUNT` and `FRESHNESS`. Frequent DMFs need at least two weeks of history (60 days recommended); infrequent or trigger-based ones need at least two data points.

**Q5. Write an expectation that fails when more than 1% of a column is NULL.**
Attach `SNOWFLAKE.CORE.NULL_PERCENT` with `EXPECTATION low_nulls (VALUE <= 1)`. Confirm the unit `NULL_PERCENT` returns (0 to 100 vs 0 to 1) in its function reference before setting the threshold.

**Q6. Why can't you scan failed rows for your custom referential-integrity DMF?**
`SYSTEM$DATA_METRIC_SCAN` accepts only six system DMFs. Custom DMFs aren't supported.

**Q7. A data steward has SELECT but not OWNERSHIP on a table. How can they attach a DMF?**
Use `EXECUTE AS ROLE <their role>` on the association, with `EXECUTE DATA METRIC FUNCTION` on the account and USAGE on the DMF.

**Q8. You add `WITHIN GROUP (store_id)` and the table has 4,000 stores. What happens?**
The evaluation fails and writes no results, because the maximum group limit is 1000. Group by a lower-cardinality column.

**Q9. Notifications are enabled on the database, but one noisy check should stay silent. How?**
`ALTER TABLE ... MODIFY DATA METRIC FUNCTION ... SET DATA_QUALITY_NOTIFICATION = FALSE` on that association.

**Q10. Which of these are billed: creating a DMF, a manual `SELECT` of a DMF, a scheduled run?**
Only the scheduled run (serverless compute under "Data Quality Monitoring"), plus logging for writing results.

**Q11. You cloned a table that had five DMFs. Does the clone have them?**
Yes. A clone inherits the source's DMF bindings. So does `CREATE TABLE ... LIKE`.

**Q12. Which three objects can you read results from, and which needs the highest privilege?**
The raw event table, the flattened view and the table function. The raw event table needs the `DATA_QUALITY_MONITORING_ADMIN` application role.

---

## 20. Sources

All pages are from docs.snowflake.com, read on 5 October 2026.

| Topic | Page |
| --- | --- |
| Concepts, supported objects, cost, limits | [Introduction to data quality checks](https://docs.snowflake.com/en/user-guide/data-quality-intro) |
| System DMF list | [System data metric functions](https://docs.snowflake.com/en/user-guide/data-quality-system-dmfs) |
| Custom DMFs | [Custom data metric functions](https://docs.snowflake.com/en/user-guide/data-quality-custom-dmfs) |
| DMF DDL | [CREATE DATA METRIC FUNCTION](https://docs.snowflake.com/en/sql-reference/sql/create-data-metric-function) |
| Association, creation-time clause, schedule, suspend, manual calls | [Use SQL to set up data metric functions](https://docs.snowflake.com/en/user-guide/data-quality-working) |
| Expectations | [Use SQL to work with expectations](https://docs.snowflake.com/en/user-guide/data-quality-expectations) |
| Anomaly detection | [Detecting anomalies in data quality](https://docs.snowflake.com/en/user-guide/data-quality-anomaly) |
| Grouping | [Apply data quality checks by group](https://docs.snowflake.com/en/user-guide/data-quality-group-by) |
| Grouping GA date | [10.16 Release Notes](https://docs.snowflake.com/en/release-notes/2026/10_16) |
| Schema-level | [Monitor the data quality of a schema](https://docs.snowflake.com/en/user-guide/data-quality-schema-level) |
| Results | [View results of a data metric function](https://docs.snowflake.com/en/user-guide/data-quality-results) |
| Notifications | [Sending notifications for data quality issues](https://docs.snowflake.com/en/user-guide/data-quality-notifications) |
| Remediation | [Remediation of data quality issues](https://docs.snowflake.com/en/user-guide/data-quality-fixing) |
| Scan function | [SYSTEM$DATA_METRIC_SCAN](https://docs.snowflake.com/en/sql-reference/functions/system_data_metric_scan) |
| Snowsight | [Monitoring data quality checks in Snowsight](https://docs.snowflake.com/en/user-guide/data-quality-ui-monitor) |
| Access control | [Access control for data quality](https://docs.snowflake.com/en/user-guide/data-quality-access-control) |
| Association metadata | [DATA_METRIC_FUNCTION_REFERENCES](https://docs.snowflake.com/en/sql-reference/functions/data_metric_function_references) |
| Tutorial grants | [Tutorial: Getting started with data metric functions](https://docs.snowflake.com/en/user-guide/tutorials/data-quality-tutorial-start) |
| Original GA announcement | [8.28 Release Notes (2024)](https://docs.snowflake.com/en/release-notes/2024/8_28) |

### What is not from these pages

- Section 1's statement about constraint enforcement (background knowledge; verify separately).
- The cost-lever note in section 17.
- The worked scenario in 19.1 (invented objects, documented syntax).
- The "load that never arrived" row and the DMFs vs dbt tests table in 19.2.
- The self-check questions in 19.3 (answers are derived from the sources).
- All SQL examples use invented object names; they follow documented syntax but were not executed against a Snowflake account.

### Topics the docs cover that this guide does not

Cortex Data Quality in depth, the account-wide monitoring dashboard, data profiling, the `FILTER` clause for checking a subset of rows, DMF replication, and the Snowsight setup flow.