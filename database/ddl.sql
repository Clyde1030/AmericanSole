-- =============================================================================
-- American Sole ERP Database Schema (PostgreSQL)
-- =============================================================================
-- Business context:
--   American Sole is a shoe manufacturer in San Antonio, TX.
--   Overseas vendor Tunlite (China) ships semi-finished goods (uppers + soles).
--   American Sole performs final assembly (sole attaching) and ships to US
--   customers (shoe brands).
-- =============================================================================

-- ============================================================
-- CORE SCHEMA — shared entities across all domains
-- ============================================================
CREATE SCHEMA IF NOT EXISTS core;

-- Every business partner: customers, vendors, or both
CREATE TABLE core.company (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name        TEXT NOT NULL,
    created_at  TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- Lookup: CUSTOMER, VENDOR
CREATE TABLE core.company_role_type (
    id    SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name  TEXT NOT NULL UNIQUE   -- 'CUSTOMER', 'VENDOR'
);

-- A company can hold multiple roles (e.g. both customer and vendor)
CREATE TABLE core.company_role (
    company_id  BIGINT   NOT NULL REFERENCES core.company (id),
    role_id     SMALLINT NOT NULL REFERENCES core.company_role_type (id),
    PRIMARY KEY (company_id, role_id)
);

CREATE TABLE core.address (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id  BIGINT NOT NULL REFERENCES core.company (id),
    line_1      TEXT   NOT NULL,
    line_2      TEXT,
    city        TEXT   NOT NULL,
    state       TEXT,
    postal_code TEXT,
    country     TEXT   NOT NULL,
    is_primary  BOOLEAN DEFAULT FALSE
);

-- ============================================================
-- PRODUCT SCHEMA — catalog, sizes, materials, BOM
-- ============================================================
CREATE SCHEMA IF NOT EXISTS product;

CREATE TABLE product.brand (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id  BIGINT NOT NULL REFERENCES core.company (id),
    name        TEXT   NOT NULL,
    UNIQUE (company_id, name) -- WWW can only have one Harley, but USBoot can have a Harley too
);

CREATE TABLE product.style (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    brand_id    BIGINT NOT NULL REFERENCES product.brand (id),
    name        TEXT   NOT NULL,
    description TEXT,
    is_active   BOOLEAN DEFAULT TRUE,
    UNIQUE (brand_id, name) --- Brunt can only have CTBT, but USBoot can also have a CTBT
);

-- Lookup: standardized shoe sizes
CREATE TABLE product.size (
    id          SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    size_label  TEXT         NOT NULL UNIQUE,   -- display value: '8', '8.5', '9'
    size_number NUMERIC(3,1) NOT NULL UNIQUE    -- sortable numeric value
);

-- Lookup: units of measure for materials
CREATE TABLE product.unit_of_measure (
    id     SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name   TEXT NOT NULL UNIQUE,   -- 'pair', 'sq_ft', 'lb', 'unit', 'gallon'
    symbol TEXT NOT NULL UNIQUE
);

-- Material categories: upper, last, sole, adhesive, packaging, etc.
--    id    category       name                  uom
---------------------------------------------------
--    1      sole         Rubber Sole Model A.   pair
---------------------------------------------------
--    2      upper        Leather Upper X.       pair
---------------------------------------------------
--    3      adhesive.    Glue Z                 lb
---------------------------------------------------

CREATE TABLE product.material_category (
    id   SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name TEXT NOT NULL UNIQUE
);

CREATE TABLE product.material (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    category_id SMALLINT NOT NULL REFERENCES product.material_category (id),
    name        TEXT     NOT NULL,
    uom_id      SMALLINT NOT NULL REFERENCES product.unit_of_measure (id),
    description TEXT,
    UNIQUE (category_id, name) -- prevent duplicated "sole rubber A" records
);



-- Bill of Materials: what materials a style requires per unit (pair)
--    material               qty_per_unit
---------------------------------------------------
--    Rubber Sole Model A    1 pair
---------------------------------------------------
--    Leather Upper X        1 pair
---------------------------------------------------
--    Glue.                  0.2 lbs
---------------------------------------------------

CREATE TABLE product.bill_of_material (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    style_id    BIGINT   NOT NULL REFERENCES product.style (id),
    material_id BIGINT   NOT NULL REFERENCES product.material (id),
    qty_per_unit NUMERIC(10,4) NOT NULL,   -- quantity needed per pair
    UNIQUE (style_id, material_id) -- prevent coexisted ("CTBT", "Glue Z", 0.2) and ("CTBT", "Glue Z", 0.3) records
);



-- ============================================================
-- SALES SCHEMA — customer purchase orders
-- ============================================================
CREATE SCHEMA IF NOT EXISTS sales;

CREATE TABLE sales.purchase_order (
    id                    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    purchase_order_number TEXT   NOT NULL UNIQUE,
    company_id            BIGINT NOT NULL REFERENCES core.company (id),
    order_date            DATE,
    customer_requested_xf DATE,            -- customer requested ex-factory date
    status                TEXT   NOT NULL DEFAULT 'OPEN'
                          CHECK (status IN ('OPEN','IN_PROGRESS','COMPLETED','CANCELLED')),
    created_at            TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE sales.po_line (
    id                BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    purchase_order_id BIGINT NOT NULL REFERENCES sales.purchase_order (id),
    style_id          BIGINT NOT NULL REFERENCES product.style (id),
    line_number       SMALLINT NOT NULL,   -- ordinal within the PO
    UNIQUE (purchase_order_id, line_number)
);

CREATE TABLE sales.po_line_size (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    po_line_id  BIGINT   NOT NULL REFERENCES sales.po_line (id),
    size_id     SMALLINT NOT NULL REFERENCES product.size (id),
    quantity    INT      NOT NULL CHECK (quantity > 0),
    UNIQUE (po_line_id, size_id)
);

-- ============================================================
-- PROCUREMENT SCHEMA — orders placed to vendors (e.g. Tunlite)
-- ============================================================
CREATE SCHEMA IF NOT EXISTS procurement;

-- Orders American Sole places to Tunlite for uppers + lasts
CREATE TABLE procurement.vendor_order (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vendor_order_number TEXT   NOT NULL UNIQUE,
    vendor_company_id   BIGINT NOT NULL REFERENCES core.company (id),
    order_date          DATE,
    status              TEXT   NOT NULL DEFAULT 'OPEN'
                        CHECK (status IN ('OPEN','CONFIRMED','IN_PRODUCTION','SHIPPED','RECEIVED','CANCELLED')),
    created_at          TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- Each vendor order line maps to a sales PO line (build-to-order)
CREATE TABLE procurement.vendor_order_line (
    id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vendor_order_id  BIGINT NOT NULL REFERENCES procurement.vendor_order (id),
    po_line_id       BIGINT REFERENCES sales.po_line (id),   -- nullable if speculative order
    style_id         BIGINT NOT NULL REFERENCES product.style (id),
    line_number      SMALLINT NOT NULL,
    UNIQUE (vendor_order_id, line_number)
);

CREATE TABLE procurement.vendor_order_line_size (
    id                    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vendor_order_line_id  BIGINT   NOT NULL REFERENCES procurement.vendor_order_line (id),
    size_id               SMALLINT NOT NULL REFERENCES product.size (id),
    quantity              INT      NOT NULL CHECK (quantity > 0),
    UNIQUE (vendor_order_line_id, size_id)
);

-- ============================================================
-- LOGISTICS SCHEMA — inbound freight (Tunlite→SA) & outbound (SA→customer)
-- ============================================================
CREATE SCHEMA IF NOT EXISTS logistics;

-- Inbound shipment from overseas vendor to San Antonio
CREATE TABLE logistics.inbound_shipment (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    shipment_number     TEXT   UNIQUE,
    vendor_company_id   BIGINT NOT NULL REFERENCES core.company (id),
    vendor_order_id     BIGINT REFERENCES procurement.vendor_order (id),

    transport_mode      TEXT NOT NULL CHECK (transport_mode IN ('OCEAN','AIR','COURIER')),
    container_number    TEXT,
    tracking_number     TEXT,

    port_of_origin      TEXT,              -- e.g. 'Shanghai'
    port_of_destination TEXT,              -- e.g. 'Houston'

    etd                 DATE,              -- estimated time of departure
    eta                 DATE,              -- estimated time of arrival
    actual_departure    DATE,
    actual_arrival      DATE,

    status              TEXT NOT NULL DEFAULT 'BOOKED'
                        CHECK (status IN ('BOOKED','IN_TRANSIT','CUSTOMS','DELIVERED','CANCELLED')),
    created_at          TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE logistics.inbound_shipment_line (
    id                    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    inbound_shipment_id   BIGINT NOT NULL REFERENCES logistics.inbound_shipment (id),
    vendor_order_line_id  BIGINT NOT NULL REFERENCES procurement.vendor_order_line (id)
);

CREATE TABLE logistics.inbound_shipment_line_size (
    id                        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    inbound_shipment_line_id  BIGINT   NOT NULL REFERENCES logistics.inbound_shipment_line (id),
    size_id                   SMALLINT NOT NULL REFERENCES product.size (id),
    quantity                  INT      NOT NULL CHECK (quantity > 0),
    UNIQUE (inbound_shipment_line_id, size_id)
);

-- Outbound shipment from San Antonio to customer
CREATE TABLE logistics.outbound_shipment (
    id                BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    shipment_number   TEXT   UNIQUE,
    company_id        BIGINT NOT NULL REFERENCES core.company (id),  -- customer

    transport_mode    TEXT CHECK (transport_mode IN ('GROUND','AIR','OCEAN','COURIER')),
    tracking_number   TEXT,

    ship_date         DATE,
    delivery_date     DATE,

    status            TEXT NOT NULL DEFAULT 'PENDING'
                      CHECK (status IN ('PENDING','PICKED','SHIPPED','DELIVERED','CANCELLED')),
    created_at        TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE logistics.outbound_shipment_line (
    id                      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    outbound_shipment_id    BIGINT NOT NULL REFERENCES logistics.outbound_shipment (id),
    po_line_id              BIGINT NOT NULL REFERENCES sales.po_line (id)
);

CREATE TABLE logistics.outbound_shipment_line_size (
    id                          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    outbound_shipment_line_id   BIGINT   NOT NULL REFERENCES logistics.outbound_shipment_line (id),
    size_id                     SMALLINT NOT NULL REFERENCES product.size (id),
    quantity                    INT      NOT NULL CHECK (quantity > 0),
    UNIQUE (outbound_shipment_line_id, size_id)
);

-- ============================================================
-- OPERATIONS SCHEMA — work orders, workstations, production steps
-- ============================================================
CREATE SCHEMA IF NOT EXISTS operations;

CREATE TABLE operations.workstation (
    id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name TEXT NOT NULL UNIQUE   -- 'Sole Attach', 'QC', 'Finishing', 'Packing'
);

-- Production routing: ordered steps each style goes through
CREATE TABLE operations.production_step (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    style_id        BIGINT   NOT NULL REFERENCES product.style (id),
    workstation_id  BIGINT   NOT NULL REFERENCES operations.workstation (id),
    step_order      SMALLINT NOT NULL,    -- sequence within the style's routing
    description     TEXT,
    UNIQUE (style_id, step_order)
);

CREATE TABLE operations.work_order (
    id                 BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    work_order_number  TEXT   NOT NULL UNIQUE,
    status             TEXT   NOT NULL DEFAULT 'OPEN'
                       CHECK (status IN ('OPEN','IN_PROGRESS','COMPLETED','CANCELLED')),
    created_at         TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- Which PO lines a work order fulfills
CREATE TABLE operations.work_order_line (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    work_order_id   BIGINT NOT NULL REFERENCES operations.work_order (id),
    po_line_id      BIGINT NOT NULL REFERENCES sales.po_line (id),
    UNIQUE (work_order_id, po_line_id)
);

CREATE TABLE operations.work_order_line_size (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    work_order_line_id  BIGINT   NOT NULL REFERENCES operations.work_order_line (id),
    size_id             SMALLINT NOT NULL REFERENCES product.size (id),
    quantity            INT      NOT NULL CHECK (quantity > 0),
    UNIQUE (work_order_line_id, size_id)
);

-- ============================================================
-- INVENTORY SCHEMA — stock levels and movement history
-- ============================================================
CREATE SCHEMA IF NOT EXISTS inventory;

-- Current stock snapshot — one row per (material or finished good) × location × status
CREATE TABLE inventory.inventory (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    style_id    BIGINT   REFERENCES product.style (id),      -- for finished/semi-finished goods
    material_id BIGINT   REFERENCES product.material (id),   -- for raw materials
    size_id     SMALLINT REFERENCES product.size (id),       -- null for unsized materials
    location    TEXT     NOT NULL,                            -- 'FACTORY', 'WAREHOUSE'
    status      TEXT     NOT NULL
                CHECK (status IN ('RAW','INBOUND','WIP','FG','ALLOCATED','SHIPPED')),
    quantity    INT      NOT NULL DEFAULT 0,

    -- Either style or material must be set, not both
    CHECK (
        (style_id IS NOT NULL AND material_id IS NULL) OR
        (style_id IS NULL AND material_id IS NOT NULL)
    ),
    UNIQUE (style_id, material_id, size_id, location, status)
);

CREATE TABLE inventory.inventory_transaction (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    style_id        BIGINT   REFERENCES product.style (id),
    material_id     BIGINT   REFERENCES product.material (id),
    size_id         SMALLINT REFERENCES product.size (id),

    from_status     TEXT,
    to_status       TEXT,
    quantity        INT  NOT NULL,

    reference_type  TEXT,   -- 'VENDOR_ORDER', 'WORK_ORDER', 'OUTBOUND_SHIPMENT', 'ADJUSTMENT'
    reference_id    BIGINT,

    created_at      TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================
-- FINANCE SCHEMA — pricing with historical tracking
-- ============================================================
CREATE SCHEMA IF NOT EXISTS finance;

-- Lookup: pricing component types
CREATE TABLE finance.price_component (
    id   SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name TEXT NOT NULL UNIQUE
    -- e.g. 'DEVELOPMENT_AND_TOOLING', 'EXPORT_FROM_CHINA', 'AGENT_FEE',
    --      'FOB', 'TARIFF', 'ECP', 'RETAIL'
);

-- Pricing per customer × style × component, with effective date ranges
-- This allows different prices for different customers/styles and progressive yearly changes
CREATE TABLE finance.style_price (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id          BIGINT   NOT NULL REFERENCES core.company (id),    -- customer
    style_id            BIGINT   NOT NULL REFERENCES product.style (id),
    price_component_id  SMALLINT NOT NULL REFERENCES finance.price_component (id),
    amount              NUMERIC(12,4) NOT NULL,
    currency            TEXT NOT NULL DEFAULT 'USD',
    effective_from      DATE NOT NULL,      -- start of validity (inclusive)
    effective_to        DATE,               -- end of validity (null = current)

    -- No overlapping date ranges for the same customer+style+component
    UNIQUE (company_id, style_id, price_component_id, effective_from)
);

-- ============================================================
-- HR SCHEMA — warehouse workers
-- ============================================================
CREATE SCHEMA IF NOT EXISTS hr;

-- Lookup: job roles in the warehouse
CREATE TABLE hr.role (
    id   SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name TEXT NOT NULL UNIQUE   -- 'ASSEMBLER', 'PACKER', 'QC_INSPECTOR', 'LEAD', 'SUPERVISOR'
);

-- Lookup: seniority / pay levels
CREATE TABLE hr.level (
    id   SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name TEXT NOT NULL UNIQUE   -- 'ENTRY', 'MID', 'SENIOR', 'LEAD'
);

CREATE TABLE hr.employee (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    first_name  TEXT     NOT NULL,
    last_name   TEXT     NOT NULL,
    role_id     SMALLINT NOT NULL REFERENCES hr.role (id),
    level_id    SMALLINT NOT NULL REFERENCES hr.level (id),
    rate        NUMERIC(8,2) NOT NULL CHECK (rate > 0),  -- hourly rate in USD
    is_active   BOOLEAN  NOT NULL DEFAULT TRUE,
    hired_date  DATE,
    terminated_date DATE,
    created_at  TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================
-- INDEXES — foreign keys and frequently queried fields
-- ============================================================

-- core
CREATE INDEX idx_address_company     ON core.address (company_id);
CREATE INDEX idx_company_role_co     ON core.company_role (company_id);

-- product
CREATE INDEX idx_brand_company       ON product.brand (company_id);
CREATE INDEX idx_style_brand         ON product.style (brand_id);
CREATE INDEX idx_material_category   ON product.material (category_id);
CREATE INDEX idx_bom_style           ON product.bill_of_material (style_id);
CREATE INDEX idx_bom_material        ON product.bill_of_material (material_id);

-- sales
CREATE INDEX idx_po_company          ON sales.purchase_order (company_id);
CREATE INDEX idx_po_number           ON sales.purchase_order (purchase_order_number);
CREATE INDEX idx_pol_po              ON sales.po_line (purchase_order_id);
CREATE INDEX idx_pol_style           ON sales.po_line (style_id);
CREATE INDEX idx_pols_line           ON sales.po_line_size (po_line_id);

-- procurement
CREATE INDEX idx_vo_vendor           ON procurement.vendor_order (vendor_company_id);
CREATE INDEX idx_vol_vo              ON procurement.vendor_order_line (vendor_order_id);
CREATE INDEX idx_vol_po_line         ON procurement.vendor_order_line (po_line_id);
CREATE INDEX idx_vols_vol            ON procurement.vendor_order_line_size (vendor_order_line_id);

-- logistics
CREATE INDEX idx_inb_vendor          ON logistics.inbound_shipment (vendor_company_id);
CREATE INDEX idx_inb_vo              ON logistics.inbound_shipment (vendor_order_id);
CREATE INDEX idx_inb_status          ON logistics.inbound_shipment (status);
CREATE INDEX idx_inb_eta             ON logistics.inbound_shipment (eta);
CREATE INDEX idx_inbl_shipment       ON logistics.inbound_shipment_line (inbound_shipment_id);
CREATE INDEX idx_outb_company        ON logistics.outbound_shipment (company_id);
CREATE INDEX idx_outb_status         ON logistics.outbound_shipment (status);
CREATE INDEX idx_outbl_shipment      ON logistics.outbound_shipment_line (outbound_shipment_id);
CREATE INDEX idx_outbl_po_line       ON logistics.outbound_shipment_line (po_line_id);

-- operations
CREATE INDEX idx_wo_status           ON operations.work_order (status);
CREATE INDEX idx_wol_wo              ON operations.work_order_line (work_order_id);
CREATE INDEX idx_wol_pol             ON operations.work_order_line (po_line_id);
CREATE INDEX idx_wols_wol            ON operations.work_order_line_size (work_order_line_id);
CREATE INDEX idx_pstep_style         ON operations.production_step (style_id);

-- inventory
CREATE INDEX idx_inv_style           ON inventory.inventory (style_id);
CREATE INDEX idx_inv_material        ON inventory.inventory (material_id);
CREATE INDEX idx_inv_status          ON inventory.inventory (status);
CREATE INDEX idx_invtx_style         ON inventory.inventory_transaction (style_id);
CREATE INDEX idx_invtx_material      ON inventory.inventory_transaction (material_id);
CREATE INDEX idx_invtx_ref           ON inventory.inventory_transaction (reference_type, reference_id);

-- finance
CREATE INDEX idx_sp_company_style    ON finance.style_price (company_id, style_id);
CREATE INDEX idx_sp_component        ON finance.style_price (price_component_id);
CREATE INDEX idx_sp_effective        ON finance.style_price (effective_from, effective_to);

-- hr
CREATE INDEX idx_emp_role            ON hr.employee (role_id);
CREATE INDEX idx_emp_level           ON hr.employee (level_id);
CREATE INDEX idx_emp_active          ON hr.employee (is_active);

