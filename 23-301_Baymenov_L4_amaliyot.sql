-- ============================================================
-- DEAA Lecture 4: pgAdmin practice
-- Star schema, SCD Type 2 and analytical queries (PostgreSQL)
-- Student: <Group_Surname>
-- ============================================================

-- Check that we are connected to the correct database
SELECT current_database();


-- ============================================================
-- 0. Schema
-- ============================================================

-- Drop the old schema (if any) and create a clean one
DROP SCHEMA IF EXISTS dw CASCADE;
CREATE SCHEMA dw;

-- Use dw as the default schema for this session
SET search_path TO dw;


-- ============================================================
-- 1. dim_date (one row per day, 2020-2035, with holidays)
-- ============================================================

CREATE TABLE dim_date (
    date_key      INTEGER PRIMARY KEY,           -- smart key, e.g. 20261107
    full_date     DATE NOT NULL UNIQUE,
    day_of_month  SMALLINT NOT NULL,
    day_name      TEXT NOT NULL,
    week_of_year  SMALLINT NOT NULL,
    month_num     SMALLINT NOT NULL,
    month_name    TEXT NOT NULL,
    quarter       SMALLINT NOT NULL,
    year          SMALLINT NOT NULL,
    is_weekend    BOOLEAN NOT NULL,
    is_holiday    BOOLEAN NOT NULL DEFAULT FALSE,
    holiday_name  TEXT
);

-- Generate every date from 2020 to 2035 and fill the attributes
INSERT INTO dim_date
SELECT  TO_CHAR(d, 'YYYYMMDD')::INT,             -- date_key
        d,                                       -- full_date
        EXTRACT(DAY FROM d),
        TO_CHAR(d, 'Day'),
        EXTRACT(WEEK FROM d),
        EXTRACT(MONTH FROM d),
        TO_CHAR(d, 'Month'),
        EXTRACT(QUARTER FROM d),
        EXTRACT(YEAR FROM d),
        EXTRACT(ISODOW FROM d) IN (6, 7),        -- Saturday or Sunday
        FALSE, NULL                              -- holidays are set below
FROM generate_series('2020-01-01'::DATE, '2035-12-31'::DATE, '1 day') AS d;

-- Mark fixed-date holidays (religious holidays change every year, so they are not included)
UPDATE dim_date SET is_holiday = TRUE, holiday_name = CASE
    WHEN month_num = 1  AND day_of_month = 1  THEN 'Yangi yil'
    WHEN month_num = 3  AND day_of_month = 8  THEN 'Xotin-qizlar kuni'
    WHEN month_num = 3  AND day_of_month = 21 THEN 'Navro''z'
    WHEN month_num = 5  AND day_of_month = 9  THEN 'Xotira va qadrlash kuni'
    WHEN month_num = 9  AND day_of_month = 1  THEN 'Mustaqillik kuni'
    WHEN month_num = 10 AND day_of_month = 1  THEN 'O''qituvchi va murabbiylar kuni'
    WHEN month_num = 12 AND day_of_month = 8  THEN 'Konstitutsiya kuni'
END
WHERE (month_num, day_of_month) IN ((1,1),(3,8),(3,21),(5,9),(9,1),(10,1),(12,8));

-- Unknown member: used when the date of a fact is not known
INSERT INTO dim_date VALUES (-1, '1900-01-01', 1, 'Unknown', 1, 1, 'Unknown', 1, 1900, FALSE, FALSE, NULL);

-- Check: expected 5845 rows in total and 112 holiday rows
SELECT COUNT(*) AS all_rows,
       COUNT(*) FILTER (WHERE is_holiday) AS holiday_rows
FROM dim_date;


SET search_path TO dw;

-- ============================================================
-- 2. dim_store (SCD Type 2 on format)
-- ============================================================

CREATE TABLE dim_store (
    store_key    SERIAL PRIMARY KEY,             -- surrogate key
    store_code   TEXT NOT NULL,                  -- natural key from the source system
    store_name   TEXT NOT NULL,
    city         TEXT NOT NULL,
    region       TEXT NOT NULL,
    format       TEXT NOT NULL,                  -- minimarket / supermarket / hypermarket (Type 2)
    valid_from   DATE NOT NULL,                  -- version start date
    valid_to     DATE NOT NULL DEFAULT '9999-12-31',  -- version end date (open = 9999-12-31)
    is_current   BOOLEAN NOT NULL DEFAULT TRUE   -- TRUE for the latest version
);

-- Unknown member
INSERT INTO dim_store (store_key, store_code, store_name, city, region, format, valid_from)
VALUES (-1, 'UNK', 'Unknown', 'Unknown', 'Unknown', 'Unknown', '1900-01-01');

-- Initial store data
INSERT INTO dim_store (store_code, store_name, city, region, format, valid_from) VALUES
('S-041', 'Chilonzor',  'Toshkent',  'Toshkent sh.', 'minimarket',  '2024-01-01'),
('S-042', 'Yunusobod',  'Toshkent',  'Toshkent sh.', 'supermarket', '2024-01-01'),
('S-107', 'Registon',   'Samarqand', 'Samarqand',    'supermarket', '2024-01-01'),
('S-203', 'Chust',      'Chust',     'Namangan',     'minimarket',  '2025-03-01');


SET search_path TO dw;

-- ============================================================
-- 3. dim_product (SCD Type 2 on category)
-- ============================================================

CREATE TABLE dim_product (
    product_key  SERIAL PRIMARY KEY,             -- surrogate key
    sku          TEXT NOT NULL,                  -- natural key
    product_name TEXT NOT NULL,
    brand        TEXT,
    category     TEXT NOT NULL,                  -- Type 2: history is kept
    subcategory  TEXT,
    unit         TEXT,
    weight_g     INTEGER,
    valid_from   DATE NOT NULL,
    valid_to     DATE NOT NULL DEFAULT '9999-12-31',
    is_current   BOOLEAN NOT NULL DEFAULT TRUE
);

-- Unknown member
INSERT INTO dim_product (product_key, sku, product_name, category, valid_from)
VALUES (-1, 'UNK', 'Unknown', 'Unknown', '1900-01-01');

-- Initial product data
INSERT INTO dim_product (sku, product_name, brand, category, subcategory, unit, weight_g, valid_from) VALUES
('P-0001', 'Sut 2.5% 1 l',        'Musaffo', 'Dairy',     'Milk',    'pcs', 1030, '2024-01-01'),
('P-0002', 'Non (obi non)',       NULL,      'Bakery',    'Bread',   'pcs',  400, '2024-01-01'),
('P-0003', 'Energy drink 0.5 l',  'Flash',   'Beverages', 'Energy',  'pcs',  520, '2024-01-01'),
('P-0004', 'Guruch Lazer 1 kg',   'Oltin',   'Grocery',   'Rice',    'pcs', 1000, '2024-01-01');


SET search_path TO dw;

-- ============================================================
-- 4. dim_customer (Type 2 on region and loyalty_tier, Type 1 on phone)
-- ============================================================

CREATE TABLE dim_customer (
    customer_key  SERIAL PRIMARY KEY,            -- surrogate key
    customer_id   TEXT NOT NULL,                 -- natural key (loyalty card number)
    full_name     TEXT NOT NULL,
    phone         TEXT,                          -- Type 1: overwritten in all versions
    city          TEXT,
    region        TEXT NOT NULL,                 -- Type 2
    loyalty_tier  TEXT NOT NULL,                 -- Type 2
    valid_from    DATE NOT NULL,
    valid_to      DATE NOT NULL DEFAULT '9999-12-31',
    is_current    BOOLEAN NOT NULL DEFAULT TRUE
);

-- Special members: key 0 = no loyalty card (not applicable), key -1 = unknown
INSERT INTO dim_customer (customer_key, customer_id, full_name, region, loyalty_tier, valid_from) VALUES
(-1, 'UNK', 'Unknown',          'Unknown', 'Unknown', '1900-01-01'),
( 0, 'N/A', 'No loyalty card',  'N/A',     'N/A',     '1900-01-01');

-- Initial customer data
INSERT INTO dim_customer (customer_id, full_name, phone, city, region, loyalty_tier, valid_from) VALUES
('C-10077', 'Dilnoza K.', '+998901110011', 'Samarqand', 'Samarqand',    'silver', '2023-02-14'),
('C-10078', 'Aziz T.',    '+998933330022', 'Toshkent',  'Toshkent sh.', 'gold',   '2024-06-01');

-- Allow only ONE current row per natural key
CREATE UNIQUE INDEX ux_customer_current ON dim_customer (customer_id) WHERE is_current;
CREATE UNIQUE INDEX ux_store_current    ON dim_store    (store_code)  WHERE is_current;
CREATE UNIQUE INDEX ux_product_current  ON dim_product  (sku)         WHERE is_current;


SET search_path TO dw;

-- ============================================================
-- 5. fact_sales (grain: one receipt line)
-- ============================================================

CREATE TABLE fact_sales (
    sales_id      BIGSERIAL PRIMARY KEY,
    date_key      INTEGER  NOT NULL REFERENCES dim_date(date_key),
    store_key     INTEGER  NOT NULL REFERENCES dim_store(store_key),
    product_key   INTEGER  NOT NULL REFERENCES dim_product(product_key),
    customer_key  INTEGER  NOT NULL REFERENCES dim_customer(customer_key),
    receipt_no    TEXT     NOT NULL,             -- degenerate dimension (no own table)
    line_no       SMALLINT NOT NULL,
    quantity      INTEGER  NOT NULL,
    unit_price    NUMERIC(14,2) NOT NULL,        -- money in UZS, never FLOAT
    discount      NUMERIC(14,2) NOT NULL DEFAULT 0,
    net_amount    NUMERIC(14,2) NOT NULL,
    vat_amount    NUMERIC(14,2) NOT NULL,
    UNIQUE (receipt_no, line_no)                 -- grain test: one row per receipt line
);

-- Helper: returns the customer surrogate key that was valid on a given date
-- (returns -1 if the customer is not found)
CREATE OR REPLACE FUNCTION customer_key_on(p_customer_id TEXT, p_date DATE)
RETURNS INTEGER LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT customer_key FROM dim_customer
          WHERE customer_id = p_customer_id
            AND p_date >= valid_from AND p_date < valid_to), -1);
$$;


SET search_path TO dw;

-- Receipt R-300001, line 1: Dilnoza buys 2 x milk (Registon store, March 2026)
INSERT INTO fact_sales (date_key, store_key, product_key, customer_key,
                        receipt_no, line_no, quantity, unit_price, discount, net_amount, vat_amount)
SELECT 20260314, s.store_key, p.product_key, customer_key_on('C-10077', '2026-03-14'),
       'R-300001', 1, 2, 15000, 0, 30000, 3214.29
FROM dim_store s, dim_product p
WHERE s.store_code = 'S-107' AND s.is_current AND p.sku = 'P-0001' AND p.is_current;

-- Receipt R-300001, line 2: same receipt, energy drink with a discount
INSERT INTO fact_sales (date_key, store_key, product_key, customer_key,
                        receipt_no, line_no, quantity, unit_price, discount, net_amount, vat_amount)
SELECT 20260314, s.store_key, p.product_key, customer_key_on('C-10077', '2026-03-14'),
       'R-300001', 2, 1, 9000, 1000, 8000, 857.14
FROM dim_store s, dim_product p
WHERE s.store_code = 'S-107' AND s.is_current AND p.sku = 'P-0003' AND p.is_current;

-- Receipt R-300002: cash sale without loyalty card -> customer_key 0
INSERT INTO fact_sales (date_key, store_key, product_key, customer_key,
                        receipt_no, line_no, quantity, unit_price, discount, net_amount, vat_amount)
SELECT 20260314, s.store_key, p.product_key, 0,
       'R-300002', 1, 3, 4000, 0, 12000, 1285.71
FROM dim_store s, dim_product p
WHERE s.store_code = 'S-041' AND s.is_current AND p.sku = 'P-0002' AND p.is_current;

-- Check: expected 3 rows (customer_key 1, 1, 0)
SELECT f.receipt_no, f.line_no, f.customer_key, s.store_name, p.product_name, f.net_amount
FROM fact_sales f
JOIN dim_store   s ON s.store_key   = f.store_key
JOIN dim_product p ON p.product_key = f.product_key
ORDER BY f.receipt_no, f.line_no;


SET search_path TO dw;

-- ============================================================
-- 6. SCD Type 2 load: Dilnoza moves to Toshkent on 2026-07-01
-- ============================================================

BEGIN;

-- 6a. Close the current version of the customer
UPDATE dim_customer
   SET valid_to = DATE '2026-07-01', is_current = FALSE
 WHERE customer_id = 'C-10077' AND is_current;

-- 6b. Insert the new version (Type 1 columns are copied, Type 2 columns change)
INSERT INTO dim_customer (customer_id, full_name, phone, city, region, loyalty_tier, valid_from)
SELECT customer_id, full_name, phone, 'Toshkent', 'Toshkent sh.', loyalty_tier, DATE '2026-07-01'
  FROM dim_customer
 WHERE customer_id = 'C-10077' AND valid_to = DATE '2026-07-01';

COMMIT;


SET search_path TO dw;

-- 6c. Type 1 change: the phone number is overwritten in ALL versions
UPDATE dim_customer SET phone = '+998901110099' WHERE customer_id = 'C-10077';

-- July receipt: the function now returns the NEW surrogate key automatically
INSERT INTO fact_sales (date_key, store_key, product_key, customer_key,
                        receipt_no, line_no, quantity, unit_price, discount, net_amount, vat_amount)
SELECT 20260712, s.store_key, p.product_key, customer_key_on('C-10077', '2026-07-12'),
       'R-300050', 1, 1, 18000, 0, 18000, 1928.57
FROM dim_store s, dim_product p
WHERE s.store_code = 'S-042' AND s.is_current AND p.sku = 'P-0004' AND p.is_current;

-- Check: two versions of the customer
SELECT customer_key, customer_id, phone, region, valid_from, valid_to, is_current
FROM dim_customer WHERE customer_id = 'C-10077' ORDER BY valid_from;


SET search_path TO dw;

-- ============================================================
-- 7. Analytical queries
-- ============================================================

-- 7a. Net sales by customer region as it was AT THE TIME of the sale
--     (join on the surrogate key keeps history correct)
SELECT c.region, SUM(f.net_amount) AS net_sales
FROM fact_sales f
JOIN dim_customer c ON c.customer_key = f.customer_key
GROUP BY c.region ORDER BY net_sales DESC;

-- 7b. The SAME sales by the customer's CURRENT region ("as is today")
SELECT cur.region AS current_region, SUM(f.net_amount) AS net_sales
FROM fact_sales f
JOIN dim_customer hist ON hist.customer_key = f.customer_key
JOIN dim_customer cur  ON cur.customer_id = hist.customer_id AND cur.is_current
GROUP BY cur.region ORDER BY net_sales DESC;

-- 7c. Dairy sales in Samarqand stores, Q1 2026, by month
SELECT d.year, d.month_num, SUM(f.quantity) AS units, SUM(f.net_amount) AS net_sales
FROM fact_sales f
JOIN dim_date    d ON d.date_key    = f.date_key
JOIN dim_store   s ON s.store_key   = f.store_key
JOIN dim_product p ON p.product_key = f.product_key
WHERE p.category = 'Dairy' AND s.region = 'Samarqand'
  AND d.year = 2026 AND d.quarter = 1
GROUP BY d.year, d.month_num ORDER BY d.month_num;

-- 7d. Average basket on holidays vs normal days
--     (receipt grain is built from the receipt line grain)
WITH receipts AS (
    SELECT f.receipt_no, d.is_holiday, SUM(f.net_amount) AS receipt_total
    FROM fact_sales f JOIN dim_date d ON d.date_key = f.date_key
    GROUP BY f.receipt_no, d.is_holiday
)
SELECT is_holiday, COUNT(*) AS receipts, ROUND(AVG(receipt_total), 0) AS avg_basket_uzs
FROM receipts GROUP BY is_holiday;

-- 7e. Common mistake: joining on the NATURAL key duplicates rows
--     (a customer with 2 versions is counted twice)
SELECT 'wrong (natural key)' AS method, SUM(f.net_amount)
FROM fact_sales f
JOIN dim_customer c ON c.customer_id = (SELECT customer_id FROM dim_customer WHERE customer_key = f.customer_key)
UNION ALL
SELECT 'correct (surrogate key)', SUM(f.net_amount)
FROM fact_sales f JOIN dim_customer c ON c.customer_key = f.customer_key;


SET search_path TO dw;

-- ============================================================
-- 8. Data quality tests (each query must return 0 rows)
-- ============================================================

-- 8a. No customer has two current rows
SELECT customer_id, COUNT(*)
FROM dim_customer WHERE is_current
GROUP BY customer_id HAVING COUNT(*) > 1;

-- 8b. Type 2 validity intervals of one customer do not overlap
SELECT a.customer_id
FROM dim_customer a JOIN dim_customer b
  ON a.customer_id = b.customer_id AND a.customer_key <> b.customer_key
 AND a.valid_from < b.valid_to AND b.valid_from < a.valid_to;

-- 8c. Every fact row points to the dimension row that was valid on the sale date
SELECT f.sales_id
FROM fact_sales f
JOIN dim_date d     ON d.date_key = f.date_key
JOIN dim_customer c ON c.customer_key = f.customer_key
WHERE c.customer_key > 0
  AND NOT (d.full_date >= c.valid_from AND d.full_date < c.valid_to);

-- 8d. Reconciliation: sum of lines equals the receipt total
SELECT receipt_no, SUM(quantity * unit_price - discount) - SUM(net_amount) AS diff
FROM fact_sales
GROUP BY receipt_no HAVING SUM(quantity * unit_price - discount) <> SUM(net_amount);



SET search_path TO dw;

-- ============================================================
-- 9. Query plan: compare EXPLAIN ANALYZE before and after indexes
-- ============================================================

-- 9a. Plan BEFORE indexes on the foreign keys
EXPLAIN (ANALYZE, BUFFERS)
SELECT s.region, SUM(f.net_amount)
FROM fact_sales f JOIN dim_store s ON s.store_key = f.store_key
GROUP BY s.region;


SET search_path TO dw;

-- Index the foreign keys of the fact table (typical for a star schema)
CREATE INDEX ix_fact_sales_date     ON fact_sales (date_key);
CREATE INDEX ix_fact_sales_store    ON fact_sales (store_key);
CREATE INDEX ix_fact_sales_product  ON fact_sales (product_key);
CREATE INDEX ix_fact_sales_customer ON fact_sales (customer_key);

-- 9b. Plan AFTER indexes (same query, compare Execution Time with 9a)
EXPLAIN (ANALYZE, BUFFERS)
SELECT s.region, SUM(f.net_amount)
FROM fact_sales f JOIN dim_store s ON s.store_key = f.store_key
GROUP BY s.region;


SET search_path TO dw;

-- ============================================================
-- 10. Student tasks
-- ============================================================

-- T1. Move product P-0003 from 'Beverages' to 'Functional drinks'
--     from 2026-09-01 using SCD Type 2

BEGIN;

-- Close the current version of the product
UPDATE dim_product
   SET valid_to = DATE '2026-09-01', is_current = FALSE
 WHERE sku = 'P-0003' AND is_current;

-- Insert the new version with the new category (other columns are copied)
INSERT INTO dim_product (sku, product_name, brand, category, subcategory, unit, weight_g, valid_from)
SELECT sku, product_name, brand, 'Functional drinks', subcategory, unit, weight_g, DATE '2026-09-01'
  FROM dim_product
 WHERE sku = 'P-0003' AND valid_to = DATE '2026-09-01';

COMMIT;

-- Show both versions of the product
SELECT product_key, sku, category, valid_from, valid_to, is_current
FROM dim_product WHERE sku = 'P-0003' ORDER BY valid_from;

-- Proof: Q1 2026 sales are still shown under 'Beverages'
SELECT p.category, SUM(f.net_amount) AS net_sales
FROM fact_sales f
JOIN dim_date    d ON d.date_key    = f.date_key
JOIN dim_product p ON p.product_key = f.product_key
WHERE d.year = 2026 AND d.quarter = 1
GROUP BY p.category
ORDER BY p.category;


SET search_path TO dw;

-- T2. Move store S-041 to the 'supermarket' format from 2026-05-15 (Type 2)

BEGIN;

-- Close the current version of the store
UPDATE dim_store
   SET valid_to = DATE '2026-05-15', is_current = FALSE
 WHERE store_code = 'S-041' AND is_current;

-- Insert the new version with the new format (other columns are copied)
INSERT INTO dim_store (store_code, store_name, city, region, format, valid_from)
SELECT store_code, store_name, city, region, 'supermarket', DATE '2026-05-15'
  FROM dim_store
 WHERE store_code = 'S-041' AND valid_to = DATE '2026-05-15';

COMMIT;

-- New sale in June 2026: the store key is taken for the sale date (new version)
INSERT INTO fact_sales (date_key, store_key, product_key, customer_key,
                        receipt_no, line_no, quantity, unit_price, discount, net_amount, vat_amount)
SELECT 20260620, s.store_key, p.product_key, 0,
       'R-300030', 1, 2, 4000, 0, 8000, 857.14
FROM dim_store s, dim_product p
WHERE s.store_code = 'S-041'
  AND DATE '2026-06-20' >= s.valid_from AND DATE '2026-06-20' < s.valid_to
  AND p.sku = 'P-0002' AND p.is_current;

-- Sales of store S-041 by format: before and after the change
SELECT s.store_code, s.format, s.valid_from, s.valid_to, SUM(f.net_amount) AS net_sales
FROM fact_sales f
JOIN dim_store s ON s.store_key = f.store_key
WHERE s.store_code = 'S-041'
GROUP BY s.store_code, s.format, s.valid_from, s.valid_to
ORDER BY s.valid_from;


SET search_path TO dw;

-- T3. fact_returns (grain: one returned receipt line), linked to the same dimensions

CREATE TABLE fact_returns (
    return_id          BIGSERIAL PRIMARY KEY,
    date_key           INTEGER  NOT NULL REFERENCES dim_date(date_key),
    store_key          INTEGER  NOT NULL REFERENCES dim_store(store_key),
    product_key        INTEGER  NOT NULL REFERENCES dim_product(product_key),
    customer_key       INTEGER  NOT NULL REFERENCES dim_customer(customer_key),
    return_receipt_no  TEXT     NOT NULL,        -- degenerate dimension: number of the return receipt
    return_line_no     SMALLINT NOT NULL,
    original_receipt   TEXT,                     -- receipt of the original sale
    quantity           INTEGER  NOT NULL,        -- number of returned units
    refund_amount      NUMERIC(14,2) NOT NULL,   -- money returned to the customer, in UZS
    vat_amount         NUMERIC(14,2) NOT NULL,
    UNIQUE (return_receipt_no, return_line_no)   -- grain test: one row per return line
);

-- Return 1: Dilnoza returns 1 milk from receipt R-300001 (March 2026, old customer version)
INSERT INTO fact_returns (date_key, store_key, product_key, customer_key,
                          return_receipt_no, return_line_no, original_receipt,
                          quantity, refund_amount, vat_amount)
SELECT 20260320, s.store_key, p.product_key, customer_key_on('C-10077', '2026-03-20'),
       'RT-500001', 1, 'R-300001', 1, 15000, 1607.14
FROM dim_store s, dim_product p
WHERE s.store_code = 'S-107' AND s.is_current AND p.sku = 'P-0001' AND p.is_current;

-- Return 2: Dilnoza returns the rice from receipt R-300050 (July 2026, new customer version)
INSERT INTO fact_returns (date_key, store_key, product_key, customer_key,
                          return_receipt_no, return_line_no, original_receipt,
                          quantity, refund_amount, vat_amount)
SELECT 20260715, s.store_key, p.product_key, customer_key_on('C-10077', '2026-07-15'),
       'RT-500002', 1, 'R-300050', 1, 18000, 1928.57
FROM dim_store s, dim_product p
WHERE s.store_code = 'S-042' AND s.is_current AND p.sku = 'P-0004' AND p.is_current;

-- Check: 2 rows, customer_key 1 for the March return and 3 for the July return
SELECT return_receipt_no, customer_key, store_key, product_key, refund_amount
FROM fact_returns ORDER BY return_receipt_no;


SET search_path TO dw;

-- Net sales by customer region minus returns.
-- Sales and returns have different grains, so they are summed separately
-- and only then combined (joining the two fact tables directly would duplicate rows).
WITH sales_agg AS (
    SELECT c.region, SUM(f.net_amount) AS sales_amount
    FROM fact_sales f
    JOIN dim_customer c ON c.customer_key = f.customer_key
    GROUP BY c.region
),
returns_agg AS (
    SELECT c.region, SUM(r.refund_amount) AS returned_amount
    FROM fact_returns r
    JOIN dim_customer c ON c.customer_key = r.customer_key
    GROUP BY c.region
)
SELECT COALESCE(s.region, r.region)                                  AS region,
       COALESCE(s.sales_amount, 0)                                   AS sales_amount,
       COALESCE(r.returned_amount, 0)                                AS returned_amount,
       COALESCE(s.sales_amount, 0) - COALESCE(r.returned_amount, 0)  AS net_after_returns
FROM sales_agg s
FULL JOIN returns_agg r ON r.region = s.region
ORDER BY region;


SET search_path TO dw;

-- T4. Generate 100 000 random fact rows and compare EXPLAIN with and without indexes

-- Start without indexes (drop the ones created in section 9)
DROP INDEX IF EXISTS ix_fact_sales_date;
DROP INDEX IF EXISTS ix_fact_sales_store;
DROP INDEX IF EXISTS ix_fact_sales_product;
DROP INDEX IF EXISTS ix_fact_sales_customer;

-- Generate 100 000 random sales rows (receipt numbers start with 'T4-')
-- Keys used: stores 1-4, products 1-4, customers 0-2, dates 2026-01-01 .. 2026-05-14
INSERT INTO fact_sales (date_key, store_key, product_key, customer_key,
                        receipt_no, line_no, quantity, unit_price, discount, net_amount, vat_amount)
SELECT date_key, store_key, product_key, customer_key,
       receipt_no, 1, quantity, unit_price, 0,
       quantity * unit_price,                           -- net_amount
       ROUND(quantity * unit_price * 12 / 112.0, 2)     -- VAT included in the price (12%)
FROM (
    SELECT TO_CHAR(DATE '2026-01-01' + floor(random() * 134)::INT, 'YYYYMMDD')::INT AS date_key,
           1 + floor(random() * 4)::INT   AS store_key,
           1 + floor(random() * 4)::INT   AS product_key,
           floor(random() * 3)::INT       AS customer_key,
           'T4-' || g                     AS receipt_no,
           1 + floor(random() * 5)::INT   AS quantity,
           (1 + floor(random() * 20)::INT) * 1000 AS unit_price
    FROM generate_series(1, 100000) AS g
) t;

-- Update table statistics so the planner knows the new table size
ANALYZE fact_sales;

-- Check: expected 100005 rows in total, 100000 of them generated
SELECT COUNT(*) AS all_rows,
       COUNT(*) FILTER (WHERE receipt_no LIKE 'T4-%') AS generated_rows
FROM fact_sales;


SET search_path TO dw;

-- Plan WITHOUT indexes: query from section 9 (all rows are aggregated)
EXPLAIN (ANALYZE, BUFFERS)
SELECT s.region, SUM(f.net_amount)
FROM fact_sales f JOIN dim_store s ON s.store_key = f.store_key
GROUP BY s.region;

-- Additional selective query (about 0.75% of rows) to show the effect of an index
EXPLAIN (ANALYZE, BUFFERS)
SELECT SUM(f.net_amount)
FROM fact_sales f
WHERE f.date_key = 20260314;

SET search_path TO dw;

-- Index the foreign keys of the fact table
CREATE INDEX ix_fact_sales_date     ON fact_sales (date_key);
CREATE INDEX ix_fact_sales_store    ON fact_sales (store_key);
CREATE INDEX ix_fact_sales_product  ON fact_sales (product_key);
CREATE INDEX ix_fact_sales_customer ON fact_sales (customer_key);

-- Refresh statistics
ANALYZE fact_sales;

-- Plan WITH indexes: same query from section 9
EXPLAIN (ANALYZE, BUFFERS)
SELECT s.region, SUM(f.net_amount)
FROM fact_sales f JOIN dim_store s ON s.store_key = f.store_key
GROUP BY s.region;

-- Plan WITH indexes: selective query
EXPLAIN (ANALYZE, BUFFERS)
SELECT SUM(f.net_amount)
FROM fact_sales f
WHERE f.date_key = 20260314;


-- Remove generated test rows after the experiment
DELETE FROM fact_sales WHERE receipt_no LIKE 'T4-%';


-- ============================================================
-- T4 result: query plan comparison (100 000 fact rows)
-- ============================================================
-- Query 1 (aggregate by store region, all rows):
--   without indexes: <X> ms (<scan type>)
--   with indexes:    <Y> ms (<scan type>)
-- Query 2 (one day, date_key = 20260314):
--   without indexes: <X> ms (<scan type>)
--   with indexes:    <Y> ms (<scan type>)
-- Conclusion: <one or two sentences, I will write them with you>


SET search_path TO dw;

-- How many rows are in the fact table?
SELECT COUNT(*) AS all_rows,
       COUNT(*) FILTER (WHERE receipt_no LIKE 'T4-%') AS generated_rows
FROM fact_sales;

SET search_path TO dw;

-- Which indexes exist on the fact table?
SELECT indexname
FROM pg_indexes
WHERE schemaname = 'dw' AND tablename = 'fact_sales'
ORDER BY indexname;


SET search_path TO dw;

-- Remove the indexes so we can measure WITHOUT them
DROP INDEX IF EXISTS ix_fact_sales_date;
DROP INDEX IF EXISTS ix_fact_sales_store;
DROP INDEX IF EXISTS ix_fact_sales_product;
DROP INDEX IF EXISTS ix_fact_sales_customer;

-- Generate 100 000 random sales rows (receipt numbers start with 'T4-')
INSERT INTO fact_sales (date_key, store_key, product_key, customer_key,
                        receipt_no, line_no, quantity, unit_price, discount, net_amount, vat_amount)
SELECT date_key, store_key, product_key, customer_key,
       receipt_no, 1, quantity, unit_price, 0,
       quantity * unit_price,
       ROUND(quantity * unit_price * 12 / 112.0, 2)
FROM (
    SELECT TO_CHAR(DATE '2026-01-01' + floor(random() * 134)::INT, 'YYYYMMDD')::INT AS date_key,
           1 + floor(random() * 4)::INT   AS store_key,
           1 + floor(random() * 4)::INT   AS product_key,
           floor(random() * 3)::INT       AS customer_key,
           'T4-' || g                     AS receipt_no,
           1 + floor(random() * 5)::INT   AS quantity,
           (1 + floor(random() * 20)::INT) * 1000 AS unit_price
    FROM generate_series(1, 100000) AS g
) t;

-- Refresh table statistics
ANALYZE fact_sales;


SET search_path TO dw;

-- Check: expected 100005 rows in total and 100000 generated
SELECT COUNT(*) AS all_rows,
       COUNT(*) FILTER (WHERE receipt_no LIKE 'T4-%') AS generated_rows
FROM fact_sales;


SET search_path TO dw;

-- Query 1 without indexes
EXPLAIN (ANALYZE, BUFFERS)
SELECT s.region, SUM(f.net_amount)
FROM fact_sales f JOIN dim_store s ON s.store_key = f.store_key
GROUP BY s.region;

SET search_path TO dw;

-- Query 2 without indexes
EXPLAIN (ANALYZE, BUFFERS)
SELECT SUM(f.net_amount)
FROM fact_sales f
WHERE f.date_key = 20260314;

SET search_path TO dw;

-- Create indexes on the foreign keys of the fact table
CREATE INDEX ix_fact_sales_date     ON fact_sales (date_key);
CREATE INDEX ix_fact_sales_store    ON fact_sales (store_key);
CREATE INDEX ix_fact_sales_product  ON fact_sales (product_key);
CREATE INDEX ix_fact_sales_customer ON fact_sales (customer_key);

-- Refresh table statistics
ANALYZE fact_sales;


SET search_path TO dw;

-- Query 1 with indexes
EXPLAIN (ANALYZE, BUFFERS)
SELECT s.region, SUM(f.net_amount)
FROM fact_sales f JOIN dim_store s ON s.store_key = f.store_key
GROUP BY s.region;

SET search_path TO dw;

-- Query 2 with indexes
EXPLAIN (ANALYZE, BUFFERS)
SELECT SUM(f.net_amount)
FROM fact_sales f
WHERE f.date_key = 20260314;

SET search_path TO dw;

-- Query 1 with indexes
EXPLAIN (ANALYZE, BUFFERS)
SELECT s.region, SUM(f.net_amount)
FROM fact_sales f JOIN dim_store s ON s.store_key = f.store_key
GROUP BY s.region;

-- ============================================================
-- T4 result: query plan comparison (100 000 fact rows)
-- ============================================================
-- Query 1 (aggregate by store region, all rows):
--   without indexes: 42.197 ms (Seq Scan on fact_sales)
--   with indexes:    46.526 ms (Seq Scan on fact_sales, same plan)
-- Query 2 (one day, date_key = 20260314, about 0.75% of rows):
--   without indexes: 4.892 ms (Seq Scan, 99253 rows removed by filter)
--   with indexes:    2.038 ms (Bitmap Heap Scan using ix_fact_sales_date)
-- Conclusion: An index helps a selective filter: Query 2 became about
-- 2.4 times faster because the planner used ix_fact_sales_date instead of
-- reading the whole table. Query 1 needs all rows, so the planner kept the
-- Seq Scan and the indexes gave no gain (the 4 ms difference is run-to-run
-- noise). Indexes on the foreign keys pay off for selective queries, not for
-- full-table aggregations.


SET search_path TO dw;

-- Remove generated test rows after the experiment
DELETE FROM fact_sales WHERE receipt_no LIKE 'T4-%';


SET search_path TO dw;

-- Check: only the 5 original fact rows must remain
SELECT COUNT(*) AS all_rows FROM fact_sales;















