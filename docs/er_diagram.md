# EquityIQ — Entity Relationship Diagram

Rendered automatically by GitHub (Mermaid). Notation: `||--o{` = "exactly one to zero-or-many".
`PK` primary key, `FK` foreign key, `UK` unique key.

```mermaid
erDiagram
    SECURITY_UNIVERSE ||--o| COMPANIES : "whitelists (ticker)"
    COMPANIES ||--o{ STOCK_PRICES : "has daily prices"
    COMPANIES ||--o{ CORPORATE_ACTIONS : "has dividends / splits"
    COMPANIES |o--o{ DATA_QUALITY_ISSUES : "may be affected by"

    INGESTION_LOGS ||--o{ RAW_STOCK_PRICES : "loads"
    INGESTION_LOGS ||--o{ RAW_CORPORATE_ACTIONS : "loads"
    INGESTION_LOGS ||--o{ RAW_COMPANY_REFERENCE : "loads"
    INGESTION_LOGS |o--o{ DATA_QUALITY_ISSUES : "first raised in"

    RAW_STOCK_PRICES ||--o| STOCK_PRICES : "promoted to (lineage)"
    RAW_CORPORATE_ACTIONS |o--o| CORPORATE_ACTIONS : "promoted to (lineage)"
    RAW_COMPANY_REFERENCE |o--o| COMPANIES : "promoted to (lineage)"

    DATA_QUALITY_RULES ||--o{ DATA_QUALITY_ISSUES : "detects"
    RAW_STOCK_PRICES |o--o{ DATA_QUALITY_ISSUES : "raw record at fault"
    RAW_CORPORATE_ACTIONS |o--o{ DATA_QUALITY_ISSUES : "raw action at fault"
    RAW_COMPANY_REFERENCE |o--o{ DATA_QUALITY_ISSUES : "raw reference at fault"

    SECURITY_UNIVERSE {
        varchar ticker PK
        varchar assigned_sector
        boolean is_active
    }
    TRADING_CALENDAR {
        varchar exchange PK
        date calendar_date PK
        boolean is_trading_day
        boolean is_early_close
        varchar holiday_name
    }
    COMPANIES {
        int company_id PK
        varchar ticker UK "FK -> security_universe"
        varchar company_name
        varchar sector
        varchar provider_sector
        varchar industry
        varchar exchange
        char currency
        bigint raw_reference_id FK
    }
    STOCK_PRICES {
        bigint price_id PK
        int company_id FK "UK with trade_date"
        date trade_date
        numeric open_price
        numeric high_price
        numeric low_price
        numeric close_price
        numeric adjusted_close
        bigint volume
        bigint raw_record_id FK
    }
    CORPORATE_ACTIONS {
        bigint action_id PK
        int company_id FK "UK with date + type"
        date action_date
        varchar action_type "DIVIDEND | STOCK_SPLIT"
        numeric dividend_amount
        numeric split_ratio
        bigint raw_action_id FK
    }
    INGESTION_LOGS {
        bigint ingestion_batch_id PK
        varchar batch_type
        varchar source
        jsonb retrieval_parameters
        int records_received
        int records_accepted
        int records_rejected
        int records_flagged
        varchar status
    }
    RAW_STOCK_PRICES {
        bigint raw_record_id PK
        bigint ingestion_batch_id FK
        text ticker
        text trade_date
        text close_price "all values stored as text"
        jsonb raw_payload
    }
    RAW_CORPORATE_ACTIONS {
        bigint raw_action_id PK
        bigint ingestion_batch_id FK
        text ticker
        text action_type
    }
    RAW_COMPANY_REFERENCE {
        bigint raw_reference_id PK
        bigint ingestion_batch_id FK
        text ticker
        text company_name
    }
    DATA_QUALITY_RULES {
        varchar rule_id PK
        varchar rule_name UK
        varchar rule_category
        varchar severity
        varchar issue_class
        varchar handling
    }
    DATA_QUALITY_ISSUES {
        bigint issue_id PK
        text issue_key UK
        varchar rule_id FK
        bigint raw_record_id FK
        int company_id FK
        varchar status
        varchar severity
    }
```

## Reading the cardinalities

| Relationship | Meaning |
|---|---|
| companies 1 — many stock_prices | One company has many daily prices; each price belongs to exactly one company. `(company_id, trade_date)` is unique, so at most one price per company per day. |
| raw_stock_prices 1 — 0..1 stock_prices | A raw row is promoted at most once. A quarantined or duplicate raw row is never promoted (0). Every validated price points back to exactly one raw row. |
| data_quality_rules 1 — many issues | Each issue is raised by exactly one rule. |
| raw records 0..1 — many issues | One raw row can fail several rules. An issue about a *missing* trading session has no raw row, so the link is optional. |
| security_universe 1 — 0..1 companies | A ticker must be in the universe before it can become a production company. |

`ref.trading_calendar` has no foreign keys: it is joined by date (and exchange) in validation queries rather than enforced as a constraint.
