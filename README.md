# DEAA Lecture 4: Star Schema and SCD Type 2 in PostgreSQL

Student: Nurbek Baymenov

Group: 23-301

## About

pgAdmin practice for a retail data warehouse in PostgreSQL. The project builds a star schema
with SCD Type 2 dimensions, loads sample data, runs analytical queries and compares query plans.

## What is inside

- dim_date, dim_store, dim_product, dim_customer (dimensions with surrogate keys)
- fact_sales and fact_returns (fact tables)
- SCD Type 2 loading examples (customer region, product category, store format)
- Analytical queries and data quality tests
- EXPLAIN ANALYZE comparison with and without indexes (100 000 rows)

## How to run

1. Create an empty database in pgAdmin (for example, dwh_practice).
2. Open Query Tool on that database.
3. Open the file 23-301_Baymenov_L4_amaliyot.sql and run it with F5.

The script starts with DROP SCHEMA IF EXISTS dw CASCADE, so it can be re-run from scratch.
