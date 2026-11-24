
-- ============================================================
-- ICT371: ADVANCED DATABASE
-- QUESTION 1: PHARMACY STOCK AND DAILY SALES
-- ============================================================


CREATE SCHEMA IF NOT EXISTS ict371_q1;

-- Set the working schema
SET search_path TO ict371_q1, public;


-- ============================================================
-- (a) DATABASE AND SEED DATA 
-- ============================================================


DROP TABLE IF EXISTS
    daily_sales,
    stock_audit,
    sales,
    medicines
CASCADE;


-- ------------------------------------------------------------
-- TABLE 1: MEDICINES
-- ------------------------------------------------------------

CREATE TABLE medicines (
    medicine_id SERIAL PRIMARY KEY,
    medicine_name VARCHAR(100) NOT NULL,
    unit_price NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty INTEGER NOT NULL CHECK (stock_qty >= 0)
);

-- ============================================================
-- (a) CONTINUATION: INSERT MEDICINES AND SEED DATA
-- ============================================================

-- Insert three medicines into the medicines table

INSERT INTO medicines (
    medicine_name,
    unit_price,
    stock_qty
)
VALUES
    ('Paracetamol 500mg', 5.00, 200),
    ('Amoxicillin 250mg', 12.50, 100),
    ('Ibuprofen 400mg', 8.00, 150);


-- ------------------------------------------------------------
-- INSERT SIX SALES THROUGH THE STORED PROCEDURE
-- ------------------------------------------------------------

CALL pr_record_sale(1, 10, DATE '2026-11-20');

CALL pr_record_sale(2, 5, DATE '2026-11-20');

CALL pr_record_sale(1, 20, DATE '2026-11-21');

CALL pr_record_sale(3, 15, DATE '2026-11-22');

CALL pr_record_sale(2, 10, DATE '2026-11-22');

CALL pr_record_sale(1, 5, DATE '2026-11-23');


-- ------------------------------------------------------------
-- QUICK CHECKS FOR PART (a)
-- ------------------------------------------------------------

-- Display all medicines
SELECT * FROM medicines;

-- Display all recorded sales
SELECT * FROM sales;

-- Display stock audit records (should show 6 rows)
SELECT * FROM stock_audit;


-- ------------------------------------------------------------
-- TABLE 2: SALES
-- ------------------------------------------------------------

CREATE TABLE sales (
    sale_id SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    quantity INTEGER NOT NULL CHECK (quantity > 0),
    unit_price NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    sold_on DATE NOT NULL
);


-- ------------------------------------------------------------
-- TABLE 3: STOCK_AUDIT
-- ------------------------------------------------------------

CREATE TABLE stock_audit (
    audit_id SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    old_qty INTEGER,
    new_qty INTEGER,
    changed_at TIMESTAMP NOT NULL DEFAULT now()
);


-- ------------------------------------------------------------
-- TABLE 4: DAILY_SALES
-- ------------------------------------------------------------

CREATE TABLE daily_sales (
    sales_date DATE PRIMARY KEY,
    total_qty INTEGER NOT NULL,
    total_amount NUMERIC(12,2) NOT NULL
);



-- ============================================================
-- (b) FUNCTION 
-- ============================================================

CREATE OR REPLACE FUNCTION fn_sale_value(
    p_medicine_id INTEGER,
    p_quantity INTEGER
)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_price NUMERIC;
BEGIN

    -- Reject an invalid quantity
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: %', p_quantity;
    END IF;

    -- Look up the current medicine price
    SELECT unit_price
    INTO v_price
    FROM medicines
    WHERE medicine_id = p_medicine_id;

    -- Reject an unknown medicine
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine id: %', p_medicine_id;
    END IF;

    -- Return the total sale value
    RETURN v_price * p_quantity;

END;
$$;



-- ============================================================
-- (c) PROCEDURE
-- ============================================================

CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INTEGER,
    p_quantity INTEGER,
    p_sold_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC;
    v_stock INTEGER;
BEGIN

    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: %', p_quantity;
    END IF;

    SELECT unit_price, stock_qty
    INTO v_price, v_stock
    FROM medicines
    WHERE medicine_id = p_medicine_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine id: %', p_medicine_id;
    END IF;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION
            'Not enough stock: have %, need %',
            v_stock, p_quantity;
    END IF;
	
    INSERT INTO sales (
        medicine_id,
        quantity,
        unit_price,
        sold_on
    )
    VALUES (
        p_medicine_id,
        p_quantity,
        v_price,
        p_sold_on
    );

    UPDATE medicines
    SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;
END;
$$;



-- ============================================================
-- (d) TRIGGER
-- ============================================================

-- Create the trigger function

CREATE OR REPLACE FUNCTION trg_fn_stock_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN

    INSERT INTO stock_audit (
        medicine_id,
        old_qty,
        new_qty
    )
    VALUES (
        OLD.medicine_id,
        OLD.stock_qty,
        NEW.stock_qty
    );

    RETURN NEW;

END;
$$;


--CREATE TRIGGER

CREATE TRIGGER trg_medicines_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW


WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)

EXECUTE FUNCTION trg_fn_stock_audit();




-- ============================================================
-- (e) VIEW
-- ============================================================

CREATE OR REPLACE VIEW v_low_stock AS
SELECT
    medicine_id,
    medicine_name,
    unit_price,
    stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;


-- Before the sale: no rows should appear
SELECT * FROM v_low_stock;


-- ------------------------------------------------------------
-- TEST THE LOW-STOCK VIEW
-- Amoxicillin has 85 units remaining after the six sales.
-- Sell another 80 units, leaving only 5 units.
-- ------------------------------------------------------------

CALL pr_record_sale(2, 80, DATE '2026-11-24');


-- After the sale: Amoxicillin should appear in the view
SELECT * FROM v_low_stock;



-- ============================================================
-- (f) INDEX 
-- ============================================================

-- Create a composite B-tree index.

CREATE INDEX idx_sales_medicine_sold_on
ON sales (medicine_id, sold_on);

ANALYZE sales;


-- ------------------------------------------------------------
-- DEMONSTRATE THE INDEX USING EXPLAIN
-- The table is small, so sequential scanning would normally
-- be preferred. Disable it temporarily for demonstration.
-- ------------------------------------------------------------

SET enable_seqscan = off;

EXPLAIN
SELECT *
FROM sales
WHERE medicine_id = 1
AND sold_on BETWEEN DATE '2026-11-20'
                AND DATE '2026-11-23';


-- Restore the normal PostgreSQL planner setting
RESET enable_seqscan;



-- ============================================================
-- (g) SCHEDULED JOB 
-- ============================================================

CREATE OR REPLACE PROCEDURE pr_refresh_sales(
    p_day DATE
)
LANGUAGE plpgsql
AS $$
BEGIN


    INSERT INTO daily_sales (
        sales_date,
        total_qty,
        total_amount
    )
    SELECT
        p_day,
        COALESCE(SUM(quantity), 0),
        COALESCE(SUM(quantity * unit_price), 0)
    FROM sales
    WHERE sold_on = p_day

    ON CONFLICT (sales_date)
    DO UPDATE SET
        total_qty = EXCLUDED.total_qty,
        total_amount = EXCLUDED.total_amount;

END;
$$;


-- ------------------------------------------------------------
-- TEST THE DAILY SALES PROCEDURE
-- Run the procedure for 20 November 2026.

CALL pr_refresh_sales(DATE '2026-11-20');

-- Run it again to demonstrate that totals are not doubled.

CALL pr_refresh_sales(DATE '2026-11-20');

-- Display the daily sales summary.

SELECT * FROM daily_sales
ORDER BY sales_date;



