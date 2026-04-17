# Architecture: rotostats

**Run:** `sgp-2026-04-16`
**Branch:** `feature/sgp` @ `22b7f4b`
**Date:** 2026-04-16

---

## System Architecture

### Module Structure

```mermaid
%%{init: {'theme': 'neutral'}}%%
graph TD
    subgraph API["API Layer (exported functions)"]
        SGP["sgp()"]
        SGPD["sgp_denominators()"]
        CRS["convert_rate_stats()"]
        LC["league_config()"]
        LH["league_history()"]
        W["Weight constructors\nflat / linear_decay / exp_decay"]
        YW["Year-window helpers\nafter / before / between / last"]
        CS["cal / cal_spec"]
    end

    subgraph S3["S3 Layer (class methods)"]
        S3D["sgp_denominators S3\nprint / names / length / as.double / [ / [["]
        S3LC["league_config S3\nprint / pool_sizes"]
        S3LH["league_history S3\nprint"]
    end

    subgraph CORE["Core Logic"]
        SGP_BODY["sgp() body\nSteps 1–15\ncounting + rate SGP\npool construction\nbaseline derivation"]
        SGPD_BODY["sgp_denominators() body\ncalibration loop\nOLS / gap / SD\nbootstrap CIs"]
    end

    subgraph HELPERS["Internal Helpers"]
        SGPDH["sgp-denominators-helpers.R\nINVERSE_CATEGORIES\nMETADATA_COLS\napply_year_window\ncompute_weight\nexpected_range_normal\nresolve_weight"]
        POOL["pool_sizes()\nin league-config.R"]
        NEWDENOM["new_sgp_denominators()\nin sgp-denominators-s3.R"]
    end

    subgraph PKG["Package Skeleton"]
        PKG_R["rotostats-package.R\n@keywords internal"]
    end

    SGP --> SGP_BODY
    SGPD --> SGPD_BODY
    CRS --> SGPD_BODY

    SGP_BODY --> POOL
    SGP_BODY --> S3D
    SGP_BODY --> CRS

    SGPD_BODY --> SGPDH
    SGPD_BODY --> NEWDENOM
    SGPD_BODY --> CRS

    NEWDENOM --> S3D
    S3LC --> POOL
    LC --> S3LC
    LH --> S3LH

    W --> SGPD_BODY
    YW --> SGPD_BODY
    CS --> SGPD_BODY

    style SGP fill:#1e90ff,stroke:#1565c0,color:#fff
```

### Function Call Graph

```mermaid
%%{init: {'theme': 'neutral'}}%%
graph TD
    A["sgp()"] --> B["Step 1: normalize column names"]
    A --> C["Step 2–5: validate rate_conversion"]
    A --> D["Step 6: validate league_history / config"]
    A --> E["Step 7: derive scored_cats"]
    A --> F["Step 8: warn missing columns"]
    A --> G["Step 9: handle SVHD"]
    A --> H["Step 10: baseline year + avg_ERA/WHIP/AVG"]
    A --> I["Step 11: pool constants"]
    A --> J["Steps 13–14: compute SGP columns"]
    A --> K["Step 15: assemble data frame"]

    C --> C1["cli_abort\nrotostats_error_invalid_rate_conversion"]
    C --> C2["cli_abort\nrotostats_error_not_implemented"]
    C --> C3["convert_rate_stats() — delegate"]

    D --> D1["cli_abort\nrotostats_error_missing_config_field"]
    D --> D2["cli_abort\nrotostats_error_missing_required_column"]

    F --> F1["cli_warn\nrotostats_warning_missing_category_column"]

    G --> G1["rlang::inform .frequency=once"]

    H --> H1["stats::weighted.mean ERA/WHIP"]
    H --> H2["stats::weighted.mean AVG"]
    H --> H3["cli_inform baseline year used"]

    I --> I1["pool_sizes(league_config)"]
    I --> I2["order + head — pitcher pool"]
    I --> I3["order + head — hitter pool"]

    J --> J1["vectorized division counting cats"]
    J --> J2["blended ERA formula vectorized"]
    J --> J3["blended WHIP formula vectorized"]
    J --> J4["blended AVG formula sign flip"]
    J --> J5["cli_warn zero IP/AB"]

    K --> K1["as.data.frame sgp_cols"]
    K --> K2["rowSums na.rm=FALSE"]

    style A fill:#1e90ff,stroke:#1565c0,color:#fff
    style J fill:#1e90ff,stroke:#1565c0,color:#fff
```

**sgp_denominators() call graph (for reference):**

```mermaid
%%{init: {'theme': 'neutral'}}%%
graph TD
    SD["sgp_denominators()"] --> SD1["validate inputs"]
    SD --> SD2["infer / validate scoring_categories"]
    SD --> SD3["build year sets + weight fns"]
    SD --> SD4["denominator loop per category"]
    SD --> SD5["bootstrap CIs (optional)"]
    SD --> SD6["new_sgp_denominators()"]

    SD4 --> SD4a["apply_year_window()"]
    SD4 --> SD4b["compute_weight()"]
    SD4 --> SD4c["OLS: stats::lm()"]
    SD4 --> SD4d["gap / trimmed_gap"]
    SD4 --> SD4e["sd: expected_range_normal()"]

    SD6 --> S3["sgp_denominators S3 object\nattr dot rate_conversion"]
```

### Data Flow

```mermaid
%%{init: {'theme': 'neutral'}}%%
graph TD
    IN1["league_history\nteam_season data"]
    IN2["league_config\nn_teams roster_slots"]
    IN3["projections\nper-player data frame"]

    IN1 --> SD["sgp_denominators()"]
    IN2 --> SD
    SD --> DENOM["sgp_denominators S3 object\nnamed denominator vector\nrate_conversion attr"]

    IN1 --> SGP["sgp()"]
    IN2 --> SGP
    IN3 --> SGP
    DENOM --> SGP

    SGP --> POOL_CONST{"pool_baseline\n= projection_pool?"}
    POOL_CONST -- yes --> BUILD_POOL["build pool constants\npool_ER pool_IP\npool_WH pool_H pool_AB"]
    BUILD_POOL --> RATE_SGP["vectorized rate-stat SGP\nERA / WHIP / AVG"]

    SGP --> COUNT_SGP["vectorized counting-stat SGP\nprojected / denominator"]

    RATE_SGP --> ASSEMBLE["assemble result data frame"]
    COUNT_SGP --> ASSEMBLE

    ASSEMBLE --> OUT["data.frame\nsgp_HR sgp_R\nsgp_ERA sgp_WHIP sgp_AVG\ntotal_sgp"]

    style SGP fill:#1e90ff,stroke:#1565c0,color:#fff
    style OUT fill:#1e90ff,stroke:#1565c0,color:#fff
```

---

## Module Reference Table

| Module / Function | Purpose | Key Dependencies | Changed in This Run |
|---|---|---|---|
| `R/sgp.R` — `sgp()` | Per-player SGP converter; counting + blended-pool rate-stat methods | `sgp_denominators` S3, `pool_sizes()`, `convert_rate_stats()`, `cli`, `rlang`, `stats` | **YES** |
| `R/sgp-denominators.R` — `sgp_denominators()` | Calibrates per-category SGP denominators from league history | `sgp-denominators-helpers.R`, `sgp-denominators-s3.R`, `cli`, `stats` | No |
| `R/sgp-denominators.R` — `convert_rate_stats()` | Stub; always aborts with `rotostats_error_not_implemented` | `cli` | No |
| `R/sgp-denominators-s3.R` — `new_sgp_denominators()` | Constructor for `sgp_denominators` S3 object; sets `attr(., "rate_conversion")` | Base R | No |
| `R/sgp-denominators-s3.R` — S3 methods | `print`, `names`, `length`, `as.double`, `[`, `[[` for `sgp_denominators` | Base R | No |
| `R/sgp-denominators-helpers.R` | `INVERSE_CATEGORIES`, `METADATA_COLS`, weight helpers, year-window helpers, `expected_range_normal()` | `stats` | No |
| `R/league-config.R` — `league_config()` | Constructor for `league_config` S3 object; validates roster / budget config | `cli` | No |
| `R/league-config.R` — `pool_sizes()` | Returns `list(pitchers, hitters)` from config; used by `sgp()` for pool construction | `league_config` S3 | No |
| `R/league-history.R` — `league_history()` | Constructor for `league_history` S3 object; validates `team_season` schema | `cli` | No |
| `R/rotostats-package.R` | Package-level Rd stub and `@keywords internal` | — | No |

---

## Key Design Decisions (This Run)

1. **Blended-pool fixed-constant approximation**: Pool constants are computed once from the projected top-N players and applied to all evaluees. Each player is blended against the full pool (not pool-excluding-self). Approximation error is bounded at 5–15% for individual players but cancels in aggregate standings comparisons. Monte Carlo validation confirmed errors well under 1% in practice (SV-8).

2. **`attr(denominators, "rate_conversion")` on outer S3 object**: The compatibility check reads from the outer `sgp_denominators` object, not from `$denominators`. Reading the wrong level silently returns `NULL`, which would always pass the check spuriously. Verified correct in tester's EC-2 and EC-11a.

3. **`rotostats_warning_missing_category_column` dual use**: The same class covers "column absent from projections" (Step 8) and "player has 0 or NA playing time" (Steps 14a, 14d). Messages are distinguishable by content; one class makes it easy to suppress both with a single `withCallingHandlers` call.

4. **SVHD auto-derivation with `.frequency_id`**: `rlang::inform(.frequency = "once")` requires `.frequency_id` in rlang >= 1.1.0. The correct call uses `.frequency_id = "sgp_svhd_derivation"`. Omitting this caused a runtime crash (BLOCK-1 in tester round 1, fixed in builder round 2).

5. **`total_sgp` uses `na.rm = FALSE`**: Any per-category NA propagates to `total_sgp` to surface data quality issues downstream. Callers who want partial sums can compute `rowSums(result[, grep("^sgp_", names(result))], na.rm = TRUE)` themselves.
