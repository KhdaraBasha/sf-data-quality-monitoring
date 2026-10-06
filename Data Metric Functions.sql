-- Set up role, permissions, and objects
use role accountadmin;
create role if not exists dq_demo_role;
set me = current_user();
grant role dq_demo_role to user identifier($me);
grant role dq_demo_role to role sysadmin;

grant create database on account to role dq_demo_role;
grant execute data metric function on account to role dq_demo_role;
grant application role snowflake.data_quality_monitoring_viewer to role dq_demo_role;
grant database role snowflake.usage_viewer to role dq_demo_role;
grant database role snowflake.data_metric_user to role dq_demo_role;

create warehouse if not exists dq_wh
    warehouse_size =xsmall
    auto_resume = true
    auto_suspend = 60;

grant usage on warehouse dq_wh to role dq_demo_role;

use role dq_demo_role;
use warehouse dq_wh;
create database if not exists dq_db;
create schema if not exists sch;

-- Create fake, imperfect data
CREATE OR REPLACE TABLE customers (
    account_number NUMBER(38,0),
    first_name VARCHAR(16777216),
    last_name VARCHAR(16777216),
    email VARCHAR(16777216),
    phone VARCHAR(16777216),
    created_at TIMESTAMP_NTZ(9),
    street VARCHAR(16777216),
    city VARCHAR(16777216),
    state VARCHAR(16777216),
    country VARCHAR(16777216),
    zip_code NUMBER(38,0)
);

-- Notice null values and incorrect emails
INSERT INTO customers (account_number, city, country, email, first_name, last_name, phone, state, street, zip_code)
VALUES (1589420, 'san francisco', 'usa', 'john.doe@', 'john', 'doe', 1234567890, null, null, null);

INSERT INTO customers (account_number, city, country, email, first_name, last_name, phone, state, street, zip_code)
VALUES (8028387, 'san francisco', 'usa', 'bart.simpson@example.com', 'bart', 'simpson', 1012023030, null, 'market st', 94102);

INSERT INTO customers (account_number, city, country, email, first_name, last_name, phone, state, street, zip_code)
VALUES 
    (1589420, 'san francisco', 'usa', 'john.doe@example.com', 'john', 'doe', 1234567890, 'ca', 'concar dr', 94402),
    (2834123, 'san mateo', 'usa', 'jane.doe@example.com', 'jane', 'doe', 3641252911, 'ca', 'concar dr', 94402),
    (4829381, 'san mateo', 'usa', 'jim.doe@example.com', 'jim', 'doe', 3641252912, 'ca', 'concar dr', 94402),
    (9821802, 'san francisco', 'usa', 'susan.smith@example.com', 'susan', 'smith', 1234567891, 'ca', 'geary st', 94121),
    (8028387, 'san francisco', 'usa', 'bart.simpson@example.com', 'bart', 'simpson', 1012023030, 'ca', 'market st', 94102);

-- Explore system DMFs
select snowflake.core.null_percent
    (
        select state from customers 
    );

select snowflake.core.duplicate_count
    (
        select account_number from customers
    );

select *
from table(system$data_metric_scan(
    ref_entity_name => 'customers',
    metric_name => 'snowflake.core.duplicate_count',
    argument_name => 'account_number'
    ));

-- create user-defined DMF for invalid emails
create data metric function if not exists 
    invalid_email_count( arg_t table(arg_c1 string))
    returns number as
    'SELECT COUNT_IF(FALSE = (ARG_C1 REGEXP ''^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,4}$'')) 
    FROM ARG_T';

select invalid_email_count(
    select email from customers
    );

alter table customers
    add data metric function invalid_email_count on (email);

alter table customers
    add data metric function snowflake.core.duplicate_count on (account_number);

-- what DMFs are assigned to the customers table?
select * from table (information_schema.data_metric_function_references(
    ref_entity_name => 'dq_db.sch.customers',
    ref_entity_domain => 'table'
    ));

-- review run history of the invalid email DMF
select scheduled_time, measurement_time, table_name, metric_name, value 
from snowflake.local.data_quality_monitoring_results
where true
and metric_name = 'invalid_email_count'
and metric_database = 'dq_db'
order by scheduled_time desc
;

-- how many serverless credits have been consumed by the scheduled data monitiring process?
select *
from snowflake.account_usage.data_quality_monitoring_usage_history
where true
and start_time >= current_timestamp - interval '3 days'
order by start_time desc;
