-- Helper views for the product-master context graph.
-- Run ONCE in BigQuery (project erp-set-up) before `contextgraph apply`.
--   bq query --use_legacy_sql=false < sql/views.sql
-- or paste into the BigQuery console.
--
-- PIM views live in ctx_upside_master_data. Live views live in bronze and
-- reach silver/gold via fully-qualified names.

-- =====================================================================
-- PIM (gen-lang-client-0520145261.ctx_upside_master_data)
-- =====================================================================

-- Product node: flatten the three 1:1 facets onto DIM_PRODUCT so Product
-- is one clean node (mirrors how Monginis folded pricing onto Product).
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.ctx_upside_master_data.V_PRODUCT_ENRICHED` AS
SELECT
  p.SKU,
  p.DISPLAY_NAME,
  p.FLAVOUR,
  p.SIZE_GM,
  p.SIZE_LABEL,
  p.VERSION,
  p.STATUS,
  p.VEG_NONVEG,
  p.IS_ACTIVE,
  p.DESCRIPTION,
  p.IMAGES_LINK,
  pr.BASE_PRICE_INR,
  pr.GST_RATE,
  pr.MRP_INR,
  pr.TOTAL_COGS_INR,
  pr.SHELF_LIFE_DAYS,
  pk.PACKAGING_TYPE,
  pk.GS1_BARCODE,
  pk.ORG_LABELLING_COMPLIANCE,
  nu.SERVING_SIZE,
  -- Taxonomy denormalised onto the SKU row (2026-09-23). Category and
  -- ProductLine stopped being entity types and became levels of the
  -- ProductCategory hierarchy, which attaches to Product.category /
  -- Product.product_line — so the NAMES have to arrive as Product properties.
  -- Without these two columns the hierarchy shows "0 matched", because nothing
  -- populates the properties it is attached to.
  c.CATEGORY_NAME,
  l.PRODUCT_LINE_NAME
FROM `gen-lang-client-0520145261.ctx_upside_master_data.DIM_PRODUCT` p
LEFT JOIN `gen-lang-client-0520145261.ctx_upside_master_data.DIM_CATEGORY`     c ON c.CATEGORY_ID = p.CATEGORY_ID
LEFT JOIN `gen-lang-client-0520145261.ctx_upside_master_data.DIM_PRODUCT_LINE` l ON l.PRODUCT_LINE_ID = p.PRODUCT_LINE_ID
LEFT JOIN `gen-lang-client-0520145261.ctx_upside_master_data.PRODUCT_PRICING`   pr USING (SKU)
LEFT JOIN `gen-lang-client-0520145261.ctx_upside_master_data.PRODUCT_PACKAGING` pk USING (SKU)
LEFT JOIN `gen-lang-client-0520145261.ctx_upside_master_data.PRODUCT_NUTRITION` nu USING (SKU);

-- Claim node: give each highlight a stable single-column id.
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.ctx_upside_master_data.V_PRODUCT_CLAIM` AS
SELECT
  CONCAT(SKU, '-', CAST(HIGHLIGHT_SEQ AS STRING)) AS CLAIM_ID,
  SKU,
  HIGHLIGHT_SEQ,
  HIGHLIGHT_TEXT
FROM `gen-lang-client-0520145261.ctx_upside_master_data.PRODUCT_HIGHLIGHT`;

-- Nutrient dimension (empty until parse_nutrients.py populates PRODUCT_NUTRIENT).
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.ctx_upside_master_data.V_NUTRIENT_DIM` AS
SELECT DISTINCT NUTRIENT_NAME
FROM `gen-lang-client-0520145261.ctx_upside_master_data.PRODUCT_NUTRIENT`;

-- Manufacturing capability envelope: one row per product line actually made
-- today, with category, active SKU count, observed COGS range and shelf life.
-- Feeds idea_capture_triage's feasibility step — a form factor absent from this
-- view is one the company has NEVER produced.
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.ctx_upside_master_data.V_PRODUCT_LINE_CAPABILITY` AS
SELECT
  l.PRODUCT_LINE_ID,
  l.PRODUCT_LINE_NAME,
  c.CATEGORY_NAME,
  COUNT(*)                      AS ACTIVE_SKUS,
  ROUND(MIN(v.TOTAL_COGS_INR))  AS MIN_COGS_INR,
  ROUND(MAX(v.TOTAL_COGS_INR))  AS MAX_COGS_INR,
  ROUND(AVG(v.SHELF_LIFE_DAYS)) AS AVG_SHELF_LIFE_DAYS
FROM `gen-lang-client-0520145261.ctx_upside_master_data.DIM_PRODUCT` d
JOIN `gen-lang-client-0520145261.ctx_upside_master_data.V_PRODUCT_ENRICHED` v ON v.SKU = d.SKU
JOIN `gen-lang-client-0520145261.ctx_upside_master_data.DIM_PRODUCT_LINE`   l ON l.PRODUCT_LINE_ID = d.PRODUCT_LINE_ID
JOIN `gen-lang-client-0520145261.ctx_upside_master_data.DIM_CATEGORY`       c ON c.CATEGORY_ID = d.CATEGORY_ID
WHERE v.IS_ACTIVE
GROUP BY 1, 2, 3;

-- Triage similarity candidates: five grains in one rowset behind a SRC discriminator,
-- read by idea_capture_triage's two matching steps.
--
-- FOUR PACKED COLUMNS, as V_PIPELINE_PRIORITY_CANDIDATES below. STEP INPUT DATA is a silent
-- 9000-char TAIL slice and every column name repeats as a JSON key per row; the old
-- ten-column shape measured 16904. Fields are packed positionally into D — keep this layout
-- in sync with each step's legend. HYPOTHESIS/THESIS_FIT dropped: free text per row, and
-- dataset_upsert coalesces nulls, so the write-back survives without them.
--
-- D by SRC:
--   1_IDEA  <stage>|<target_cogs>
--   2_PORT  <status>|<category>|<cogs>   (ProductStatus, not IdeaStage)
--   3_CAT   <packed k=v counts>
--   4_COMP  <competitor_id>|<category>
--   9_END   empty
--
-- SPLIT ACROSS TWO STEPS, each with its own 9000 budget: match_pipeline_ideas filters
-- SRC IN ('1_IDEA','9_END'), match_portfolio_and_market takes the rest. Packed-but-unsplit
-- fits today at 7790, but DIM_IDEA grows on every approve/reject.
--
-- SRC IS NUMERICALLY PREFIXED so alphabetical order is importance order: both steps read
-- `order_by: SRC asc` and the cut takes the TAIL. Place new grains by importance, 9_END last.
--
-- MEASURED: step A 673 chars / 7 rows, step B 6441 / 57. Re-measure on any change:
--   SELECT LENGTH(TO_JSON_STRING(ARRAY_AGG(t))) FROM V_TRIAGE_SIMILARITY_CANDIDATES t
-- If B overflows, cut in order: COMP cap below 2, then CAT's units_90d/growth_pct, then NM
-- length. NOT by lowering `limit` — that drops whole tail arms including the sentinel,
-- hiding the overflow this design exists to expose.
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.ctx_upside_master_data.V_TRIAGE_SIMILARITY_CANDIDATES` AS
-- 1_IDEA — every pipeline idea, rejected ones included: a prior rejection is the strongest
-- REJECT signal the triage has.
SELECT
  '1_IDEA'                              AS SRC,
  i.IDEA_ID                             AS ID,
  i.NAME                                AS NM,
  CONCAT(IFNULL(i.STAGE, ''), '|', IFNULL(CAST(i.TARGET_COGS_INR AS STRING), '')) AS D
FROM `gen-lang-client-0520145261.ctx_upside_master_data.DIM_IDEA` i
UNION ALL
-- 2_PORT — every active SKU. One missing here reads as "no duplicate", and
-- portfolio_duplicate EXACT is a TIER 1 auto-reject.
SELECT
  '2_PORT'                              AS SRC,
  v.SKU                                 AS ID,
  v.DISPLAY_NAME                        AS NM,
  CONCAT(IFNULL(CAST(v.STATUS AS STRING), ''), '|', IFNULL(c.CATEGORY_NAME, ''), '|',
         IFNULL(CAST(ROUND(v.TOTAL_COGS_INR) AS STRING), '')) AS D
FROM `gen-lang-client-0520145261.ctx_upside_master_data.V_PRODUCT_ENRICHED` v
JOIN `gen-lang-client-0520145261.ctx_upside_master_data.DIM_PRODUCT`  d ON d.SKU = v.SKU
JOIN `gen-lang-client-0520145261.ctx_upside_master_data.DIM_CATEGORY` c ON c.CATEGORY_ID = d.CATEGORY_ID
WHERE v.IS_ACTIVE
UNION ALL
-- 3_CAT — one row per category, so competitor counts are READ, not counted off the capped
-- COMP rows. NULL IS NOT ZERO on the two competitor fields: DIM_COMPETITOR.CATEGORY is free
-- text and V_CATEGORY_MARKET_SIGNAL LEFT JOINs a normalised key, so NULL means "vocabulary
-- doesn't align", not "no competitors" — IFNULL(...,0) would erase that. ACTIVE_SKUS is
-- different: NULL there is a measured "we don't sell here".
SELECT
  '3_CAT'                               AS SRC,
  s.CATEGORY_NAME                       AS ID,
  s.CATEGORY_NAME                       AS NM,
  CONCAT(
    'competitor_products=', IFNULL(CAST(s.ACTIVE_COMPETITOR_PRODUCTS AS STRING), 'not_comparable'),
    '; competitors=',       IFNULL(CAST(s.DISTINCT_COMPETITORS       AS STRING), 'not_comparable'),
    '; active_skus=',       IFNULL(CAST(s.ACTIVE_SKUS_IN_CATEGORY    AS STRING), '0'),
    '; units_90d=',         IFNULL(CAST(s.UNITS_90D                  AS STRING), 'none'),
    '; growth_pct=',        IFNULL(CAST(s.GROWTH_PCT                 AS STRING), 'no_baseline')
  )                                     AS D
FROM `gen-lang-client-0520145261.ctx_upside_master_data.V_CATEGORY_MARKET_SIGNAL` s
UNION ALL
-- 4_COMP — active competitor products, CAPPED AT 2 PER CATEGORY. Examples only; the counts
-- live on 3_CAT. Never count these rows.
SELECT SRC, ID, NM, D FROM (
  SELECT
    '4_COMP'                            AS SRC,
    cp.COMPETITOR_PRODUCT_ID            AS ID,
    cp.PRODUCT_NAME                     AS NM,
    CONCAT(IFNULL(cp.COMPETITOR_ID, ''), '|', IFNULL(cm.CATEGORY, '')) AS D,
    ROW_NUMBER() OVER (PARTITION BY cm.CATEGORY ORDER BY cp.COMPETITOR_PRODUCT_ID) AS rn
  FROM `gen-lang-client-0520145261.ctx_upside_master_data.DIM_COMPETITOR_PRODUCT` cp
  LEFT JOIN `gen-lang-client-0520145261.ctx_upside_master_data.DIM_COMPETITOR` cm
    ON cm.COMPETITOR_ID = cp.COMPETITOR_ID AND cm.IS_ACTIVE
  WHERE cp.IS_ACTIVE
)
WHERE rn <= 2
UNION ALL
-- 9_END — ONE sentinel, the only thing making "un-truncated" checkable rather than asserted.
-- Both steps include it and '9_' sorts after every other label, so it is the first row a
-- tail cut destroys: absent means cut. Never renumber it below an arm.
SELECT '9_END' AS SRC, 'END_OF_CANDIDATES' AS ID, 'END_OF_CANDIDATES' AS NM, '' AS D;

-- ---------------------------------------------------------------------
-- Innovation pipeline prioritisation (processes/innovation_pipeline_prioritisation.yaml)
-- ---------------------------------------------------------------------

-- One row per ACTIVE brief; every machine-knowable number computed here so the LLM
-- only reads it.
--   IS NULL arm: `NULL NOT IN (...)` is NULL — without it a brief with no STAGE
--     vanishes silently instead of ranking as un-staged.
--   STAGE_RANK duplicates vocabularies.yaml's IdeaStage order (SQL can't read it).
--     Add stages to both; unmapped yields NULL.
--   COGS_FIT: explicit 'UNKNOWN' arm so a null target never reads 'INSIDE'.
--   DAYS_IN_STAGE derived per read, never stored: DIM_IDEA is written only by
--     idea_capture_triage's dataset_upsert, so a stored count would freeze there.
--     STAGE_ENTERED_AT resets per stage change = "days stuck", not days since capture.
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.ctx_upside_master_data.V_IDEA_PRIORITY_INPUTS` AS
WITH envelope AS (
  -- The cost envelope this company actually manufactures inside, collapsed to one
  -- row and cross-joined so every brief carries it.
  SELECT
    ROUND(MIN(MIN_COGS_INR)) AS PORTFOLIO_MIN_COGS_INR,
    ROUND(MAX(MAX_COGS_INR)) AS PORTFOLIO_MAX_COGS_INR
  FROM `gen-lang-client-0520145261.ctx_upside_master_data.V_PRODUCT_LINE_CAPABILITY`
)
SELECT
  i.IDEA_ID,
  i.NAME,
  i.STAGE,
  i.HYPOTHESIS,
  i.THESIS_FIT,
  i.TARGET_COGS_INR,
  DATE_DIFF(CURRENT_DATE(), DATE(i.STAGE_ENTERED_AT), DAY) AS DAYS_IN_STAGE,
  CASE i.STAGE
    WHEN 'Capture'     THEN 1
    WHEN 'Triage'      THEN 2
    WHEN 'Feasibility' THEN 3
    WHEN 'Pipeline'    THEN 4
    WHEN 'Development' THEN 5
  END                                     AS STAGE_RANK,
  e.PORTFOLIO_MIN_COGS_INR,
  e.PORTFOLIO_MAX_COGS_INR,
  CASE
    WHEN i.TARGET_COGS_INR IS NULL                                                  THEN 'UNKNOWN'
    WHEN CAST(i.TARGET_COGS_INR AS FLOAT64) < e.PORTFOLIO_MIN_COGS_INR              THEN 'BELOW'
    WHEN CAST(i.TARGET_COGS_INR AS FLOAT64) > e.PORTFOLIO_MAX_COGS_INR              THEN 'ABOVE'
    ELSE 'INSIDE'
  END                                     AS COGS_FIT
FROM `gen-lang-client-0520145261.ctx_upside_master_data.DIM_IDEA` i
CROSS JOIN envelope e
WHERE i.STAGE IS NULL OR i.STAGE NOT IN ('Rejected', 'Launch');

-- Per-category demand, compliance and channel facts, aggregated ONCE here instead of
-- three times downstream. Also the `category_signal` key behind the Category Demand
-- card — hence raw counts alongside the scored ones.
--   Signal = REALISED DEMAND. Competitor columns are reviewer-only, NOT scored:
--     16 hand-curated Pune rows over 6 categories, too coarse to rank ~38.
--   ORDER_STATE <> 'Cancelled' = the repo's completed-orders filter; TOTAL = revenue
--     (per the Sales widgets in link_datasets.yaml).
--   GROWTH_PCT via SAFE_DIVIDE: no prior sales -> NULL, not 0. "No baseline" != flat.
--   DIM_COMPETITOR.CATEGORY is free text, vocabulary need not match DIM_CATEGORY;
--     the LEFT JOIN normalises case/space and leaves NULL on mismatch. NULL means
--     "not comparable", NOT "no competitors".
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.ctx_upside_master_data.V_CATEGORY_MARKET_SIGNAL` AS
WITH sku_category AS (
  SELECT p.SKU, c.CATEGORY_NAME
  FROM `gen-lang-client-0520145261.ctx_upside_master_data.DIM_PRODUCT` p
  JOIN `gen-lang-client-0520145261.ctx_upside_master_data.DIM_CATEGORY` c
    ON c.CATEGORY_ID = p.CATEGORY_ID
),
sales AS (
  SELECT
    sc.CATEGORY_NAME,
    SUM(IF(b.ORDER_DATE >= DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY), b.QUANTITY, NULL)) AS UNITS_90D,
    SUM(IF(b.ORDER_DATE >= DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY), b.TOTAL,    NULL)) AS NET_REVENUE_90D,
    SUM(IF(b.ORDER_DATE <  DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY), b.QUANTITY, NULL)) AS UNITS_PRIOR_90D
  FROM `gen-lang-client-0520145261.silver.BUSINESS_ANALYTICS` b
  JOIN sku_category sc ON sc.SKU = b.SKU_ID
  WHERE b.ORDER_STATE <> 'Cancelled'
    AND b.ORDER_DATE >= DATE_SUB(CURRENT_DATE(), INTERVAL 180 DAY)
  GROUP BY 1
),
forecast AS (
  -- FORECAST_DATE >= CURRENT_DATE() is LOAD-BEARING. IS_LATEST_FORECAST does not
  -- isolate one run — measured, 312 distinct FORECAST_DATEs over 16 stores. Without
  -- the filter this summed 312 days of past 1-3 day predictions into 18,413 units,
  -- against 10,490 ACTUAL 90-day sales, one field from UNITS_90D. No forward rows
  -- -> NULL -> renders `none`.
  SELECT
    sc.CATEGORY_NAME,
    ROUND(SUM(f.PREDICTED_SALES_QUANTITY), 1) AS FORECAST_UNITS_NEXT
  FROM `gen-lang-client-0520145261.gold.FORECAST_RESULTS_UPDATE` f
  JOIN sku_category sc ON sc.SKU = f.SKU_ID
  WHERE f.IS_LATEST_FORECAST = TRUE
    AND f.DAYS_AHEAD BETWEEN 1 AND 3
    AND f.FORECAST_DATE >= CURRENT_DATE()
  GROUP BY 1
),
-- Active-SKU count plus the three compliance presence counts, in ONE pass — the
-- count is the denominator of all three ratios, so computing it separately would
-- scan the same rows twice. Presence tests cast to STRING so they hold whatever
-- the column type turns out to be; the cast costs nothing and cannot error.
active_sku_facts AS (
  SELECT
    sc.CATEGORY_NAME,
    COUNT(*)                                                                       AS ACTIVE_SKUS_IN_CATEGORY,
    COUNTIF(TRIM(CAST(v.ORG_LABELLING_COMPLIANCE AS STRING)) NOT IN ('', 'false')) AS SKUS_WITH_LABEL_COMPLIANCE,
    COUNTIF(TRIM(CAST(v.GS1_BARCODE AS STRING)) <> '')                             AS SKUS_WITH_BARCODE,
    COUNTIF(al.SKU IS NOT NULL)                                                    AS SKUS_WITH_DECLARED_ALLERGENS
  FROM sku_category sc
  JOIN `gen-lang-client-0520145261.ctx_upside_master_data.V_PRODUCT_ENRICHED` v ON v.SKU = sc.SKU
  LEFT JOIN (
    SELECT DISTINCT SKU FROM `gen-lang-client-0520145261.ctx_upside_master_data.MAP_PRODUCT_ALLERGEN`
  ) al ON al.SKU = sc.SKU
  WHERE v.IS_ACTIVE
  GROUP BY 1
),
-- Channels per category. SEPARATE GROUP BY on purpose: MAP_PRODUCT_CHANNEL fans a
-- SKU to 14-15 rows and would multiply active_sku_facts' COUNTIFs. Sharing
-- sku_category already kills the duplicate base join; merging further needs every
-- aggregate rewritten as COUNT(DISTINCT IF(...)).
-- APPLICABLE IS NOT A BOOLEAN — 794 rows measured: 'Suitable For' 490, NULL 229,
-- 'Combo/Large Pack' 64, 'Small Pack' 11. It is PACK FORMAT. A truthy predicate
-- once matched nothing, reporting 0 listed everywhere. "Listed" = row exists.
-- INERT today: every stocked category maps 14-15 of 15 channels, so channel_fit
-- cannot move the ranking. Kept per use-case row #17; matters once mapping is
-- per-SKU.
channel_coverage AS (
  SELECT
    sc.CATEGORY_NAME,
    COUNT(DISTINCT IF(m.APPLICABLE IS NOT NULL, m.CHANNEL_ID, NULL)) AS CHANNELS_LISTED,
    COUNT(DISTINCT ch.CHANNEL_ID)                                    AS CHANNELS_MAPPED
  FROM sku_category sc
  JOIN `gen-lang-client-0520145261.ctx_upside_master_data.V_PRODUCT_ENRICHED` v ON v.SKU = sc.SKU
  LEFT JOIN `gen-lang-client-0520145261.ctx_upside_master_data.MAP_PRODUCT_CHANNEL` m ON m.SKU = sc.SKU
  LEFT JOIN `gen-lang-client-0520145261.ctx_upside_master_data.DIM_CHANNEL` ch ON ch.CHANNEL_ID = m.CHANNEL_ID
  WHERE v.IS_ACTIVE
  GROUP BY 1
),
competitors AS (
  SELECT
    UPPER(TRIM(cm.CATEGORY))                 AS CATEGORY_KEY,
    COUNT(*)                                 AS ACTIVE_COMPETITOR_PRODUCTS,
    COUNT(DISTINCT cm.COMPETITOR_ID)         AS DISTINCT_COMPETITORS
  FROM `gen-lang-client-0520145261.ctx_upside_master_data.DIM_COMPETITOR_PRODUCT` cp
  JOIN `gen-lang-client-0520145261.ctx_upside_master_data.DIM_COMPETITOR` cm
    ON cm.COMPETITOR_ID = cp.COMPETITOR_ID AND cm.IS_ACTIVE
  WHERE cp.IS_ACTIVE
  GROUP BY 1
)
SELECT
  c.CATEGORY_NAME,
  s.UNITS_90D,
  s.NET_REVENUE_90D,
  s.UNITS_PRIOR_90D,
  ROUND(SAFE_DIVIDE(s.UNITS_90D - s.UNITS_PRIOR_90D, s.UNITS_PRIOR_90D) * 100, 1) AS GROWTH_PCT,
  f.FORECAST_UNITS_NEXT,
  k.ACTIVE_SKUS_IN_CATEGORY,
  k.SKUS_WITH_LABEL_COMPLIANCE,
  k.SKUS_WITH_BARCODE,
  k.SKUS_WITH_DECLARED_ALLERGENS,
  n.CHANNELS_LISTED,
  n.CHANNELS_MAPPED,
  x.ACTIVE_COMPETITOR_PRODUCTS,
  x.DISTINCT_COMPETITORS
-- Every join stays a LEFT JOIN off DIM_CATEGORY: a category with no active SKUs
-- (Health Bars, Dessert bites) is absent from both SKU CTEs and must arrive here
-- as NULL, so the IFNULL(...,0) in V_PIPELINE_PRIORITY_CANDIDATES scores it a
-- genuine 0. See ZERO IS NOT NEUTRAL there.
FROM `gen-lang-client-0520145261.ctx_upside_master_data.DIM_CATEGORY` c
LEFT JOIN sales            s ON s.CATEGORY_NAME = c.CATEGORY_NAME
LEFT JOIN forecast         f ON f.CATEGORY_NAME = c.CATEGORY_NAME
LEFT JOIN active_sku_facts k ON k.CATEGORY_NAME = c.CATEGORY_NAME
LEFT JOIN channel_coverage n ON n.CATEGORY_NAME = c.CATEGORY_NAME
LEFT JOIN competitors      x ON x.CATEGORY_KEY  = UPPER(TRIM(c.CATEGORY_NAME));

-- The one un-truncated feed for the scoring step: four grains unioned behind a SRC
-- discriminator. Each arm documents its DATA layout; the step's legend mirrors it —
-- keep in sync.
--
-- SHAPE IS FORCED BY TWO ENGINE LIMITS. `_compact_facts` previews any list fact
-- over 4 rows down to 4 and only a step's own `fetch` escapes, so all ~38 briefs
-- plus reference data must come through ONE fetch. STEP INPUT DATA caps at 9000
-- chars, hence: 4 columns only (a column is a JSON key on every row, so width buys
-- `"UNITS_90D":null` padding), fields packed into DATA, ingredient master as ONE
-- cell (~2k vs ~23k), BRIEF positional not labelled (~1.1k), no HYPOTHESIS,
-- CATEGORY scored not raw (~1.2k).
-- Measured pre-SQL-scoring: BRIEF 4.2k + CATEGORY 1.6k + ENVELOPE 0.1k +
-- INGREDIENT 2.0k = 8.4k, 600 spare; labelled was 9.2k and did NOT fit. Re-measure
-- and record here; if over 9000, cut the ingredient cap before brief rows:
--   SELECT LENGTH(TO_JSON_STRING(ARRAY_AGG(t))) FROM V_PIPELINE_PRIORITY_CANDIDATES t
--
-- Overflow is SILENT, so degradation is ordered: SRC sorts BRIEF < CATEGORY <
-- ENVELOPE < INGREDIENT and the step fetches `order_by: SRC asc`, so the cap eats
-- ingredients first, briefs last. Keep that ordering if you add a grain.
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.ctx_upside_master_data.V_PIPELINE_PRIORITY_CANDIDATES` AS
WITH
-- SCORING LADDERS — 5 of 6 factors scored here, not in the prompt, so they cannot
-- drift run-to-run. `ingredient_availability` stays with the model (ingredients
-- derived from a NAME, matched by meaning). The total cannot collapse here either:
-- a brief's CATEGORY is a model judgement while there is no Idea->Category edge.
-- Hence two weighted subtotals:
--   priority_score = BRIEF_SUBTOTAL (30) + CAT_SUBTOTAL (50) + ingredient x 4 (20)
-- Cut-points mirror metadata.scoring_ladders / .scoring_weights in
-- processes/innovation_pipeline_prioritisation.yaml. Change all three together.
--
-- ZERO IS NOT NEUTRAL. 2.5 = input literally missing (no target COGS, no stage
-- date). No active SKUs scores a genuine 0 — measured "we don't sell here", not
-- absent data — hence IFNULL(...,0), never the midpoint, on every SAFE_DIVIDE
-- below. Do not "fix" this.

-- Per-category factor scores (0-5 each) and their weighted subtotal (max 50).
category_factor_scores AS (
  SELECT
    m.CATEGORY_NAME,
    m.UNITS_90D,
    m.GROWTH_PCT,
    -- market_signal, max 5: volume (0-3) + growth (0-2). Absolute thresholds, not
    -- percentiles — with 6 categories a percentile swings on one moving. Calibrated
    -- against ~10,500 units sold in 90d. Competitors excluded: the old prompt made
    -- them a tiebreaker that "must not move a score", too vague to make
    -- deterministic. They stay on the Category Demand card.
    (CASE
       WHEN IFNULL(m.UNITS_90D, 0) <= 0 THEN 0
       WHEN m.UNITS_90D <   500        THEN 1
       WHEN m.UNITS_90D <  2000        THEN 2
       ELSE                                 3
     END
     + CASE
         WHEN m.GROWTH_PCT IS NULL OR m.GROWTH_PCT < 0 THEN 0   -- no_baseline or shrinking
         WHEN m.GROWTH_PCT < 25                        THEN 1
         ELSE                                               2
       END)                                                   AS MARKET_SIGNAL,
    -- compliance_readiness, max 5: mean of the three presence ratios. They share
    -- ACTIVE_SKUS as denominator, so numerators over 3 x ACTIVE_SKUS IS that mean.
    -- A PROXY for how well-trodden a CATEGORY's compliance path is, never an
    -- individual idea's readiness — an idea has no label or barcode yet.
    CAST(ROUND(5 * IFNULL(SAFE_DIVIDE(
           m.SKUS_WITH_LABEL_COMPLIANCE + m.SKUS_WITH_BARCODE + m.SKUS_WITH_DECLARED_ALLERGENS,
           3 * m.ACTIVE_SKUS_IN_CATEGORY), 0)) AS INT64)       AS COMPLIANCE_READINESS,
    -- channel_fit, max 5: listed / mapped. Near-inert today — see channel_coverage
    -- in V_CATEGORY_MARKET_SIGNAL.
    CAST(ROUND(5 * IFNULL(SAFE_DIVIDE(m.CHANNELS_LISTED, m.CHANNELS_MAPPED), 0)) AS INT64)
                                                               AS CHANNEL_FIT
  -- Every input now arrives pre-aggregated from one view, so the SKU-level joins
  -- run once instead of three times.
  FROM `gen-lang-client-0520145261.ctx_upside_master_data.V_CATEGORY_MARKET_SIGNAL` m
),
category_scores AS (
  -- Separate level: BigQuery cannot reference a SELECT alias in the same list.
  SELECT
    s.*,
    s.MARKET_SIGNAL * 5 + s.COMPLIANCE_READINESS * 3 + s.CHANNEL_FIT * 2 AS CAT_SUBTOTAL
  FROM category_factor_scores s
),

-- Per-brief factor scores and their weighted subtotal (max 30). Scored here, not
-- in V_IDEA_PRIORITY_INPUTS, so that view stays the raw-input reviewer feed its
-- dataset link and Raw Scoring Inputs card expect.
brief_factor_scores AS (
  SELECT
    b.IDEA_ID,
    b.NAME,
    b.STAGE,
    b.DAYS_IN_STAGE,
    -- cogs_vs_target: the only ladder already exact in the prompt. BELOW is 4, not
    -- 5 — cheaper than anything we make today, so margin looks good but unproven.
    CASE b.COGS_FIT
      WHEN 'INSIDE' THEN 5.0
      WHEN 'BELOW'  THEN 4.0
      WHEN 'ABOVE'  THEN 2.0
      ELSE               2.5        -- 'UNKNOWN' -> neutral midpoint, flagged below
    END                                                        AS COGS_SCORE,
    -- time_in_stage: LONGER SCORES HIGHER — an aging brief needs a decision sooner.
    CASE
      WHEN b.DAYS_IN_STAGE IS NULL THEN 2.5   -- no stage date -> neutral, flagged below
      WHEN b.DAYS_IN_STAGE <  15   THEN 0.0
      WHEN b.DAYS_IN_STAGE <= 30   THEN 1.0
      WHEN b.DAYS_IN_STAGE <= 45   THEN 2.0
      WHEN b.DAYS_IN_STAGE <= 60   THEN 3.0
      WHEN b.DAYS_IN_STAGE <  90   THEN 4.0
      ELSE                              5.0
    END                                                        AS TIME_SCORE,
    -- The `unknowns` list, computed here rather than inferred. 'none' not '' so a
    -- blank positional field can never be misread as a missing one.
    IFNULL(NULLIF(ARRAY_TO_STRING(ARRAY_CONCAT(
      IF(b.COGS_FIT = 'UNKNOWN',      ['cogs_vs_target'], []),
      IF(b.DAYS_IN_STAGE IS NULL,     ['time_in_stage'],  [])
    ), ','), ''), 'none')                                      AS UNKNOWNS
  FROM `gen-lang-client-0520145261.ctx_upside_master_data.V_IDEA_PRIORITY_INPUTS` b
  WHERE b.STAGE IN ('Capture', 'Triage', 'Feasibility')
),
brief_scores AS (
  SELECT
    s.*,
    s.COGS_SCORE * 4 + s.TIME_SCORE * 2 AS BRIEF_SUBTOTAL   -- weights 4 and 2 -> max 30
  FROM brief_factor_scores s
)

-- BRIEF rows: positional DATA, stage|days|cogs_s|time_s|brief_sub|unk. Do not
-- reorder without updating the legend in the process step's instruction.
-- FORMAT('%g') prints a whole score as "5" not "5.0" while keeping the 2.5 neutral.
SELECT
  'BRIEF'    AS SRC,
  b.IDEA_ID  AS ID,
  b.NAME     AS NAME,
  CONCAT(
    IFNULL(b.STAGE, 'unknown'),                         '|',
    IFNULL(CAST(b.DAYS_IN_STAGE AS STRING), 'unknown'),  '|',
    FORMAT('%g', b.COGS_SCORE),                          '|',
    FORMAT('%g', b.TIME_SCORE),                          '|',
    FORMAT('%g', b.BRIEF_SUBTOTAL),                      '|',
    b.UNKNOWNS
  )          AS DATA
FROM brief_scores b

UNION ALL
-- CATEGORY rows: the three factors ALREADY SCORED, plus their subtotal. units90 /
-- growth_pct exist only so the model can cite a figure in `reason`. The raw evidence
-- (prior90, forecast, SKU/channel/label counts, competitors) is not lost — it is on
-- the Category Demand card via `category_signal`; duplicating it here cost ~1.2k.
SELECT
  'CATEGORY',
  CAST(NULL AS STRING),
  s.CATEGORY_NAME,
  CONCAT(
    'ms=',            CAST(s.MARKET_SIGNAL AS STRING),
    '; cr=',          CAST(s.COMPLIANCE_READINESS AS STRING),
    '; cf=',          CAST(s.CHANNEL_FIT AS STRING),
    '; cat_sub=',     CAST(s.CAT_SUBTOTAL AS STRING),
    '; units90=',     IFNULL(CAST(s.UNITS_90D AS STRING), 'none'),
    '; growth_pct=',  IFNULL(CAST(s.GROWTH_PCT AS STRING), 'no_baseline')
  )
FROM category_scores s

UNION ALL
-- One row: the manufacturing cost envelope, which is identical for every brief.
-- Carried once instead of on all 38 BRIEF rows (~1.5k of duplication saved).
SELECT
  'ENVELOPE',
  CAST(NULL AS STRING),
  'portfolio cost envelope',
  CONCAT(
    'cogs_min=', IFNULL(CAST(MIN(MIN_COGS_INR) AS STRING), 'unknown'),
    '; cogs_max=', IFNULL(CAST(MAX(MAX_COGS_INR) AS STRING), 'unknown')
  )
FROM `gen-lang-client-0520145261.ctx_upside_master_data.V_PRODUCT_LINE_CAPABILITY`

UNION ALL
-- Whole ingredient master in one cell. Present = already sourced, absent = net-new.
-- NO stock quantities.
--
-- COMPLETENESS IS SELF-DECLARED BECAUSE THE MODEL CANNOT COUNT. `count=<n>` alone
-- failed: names contain commas ("a non-caloric sweetener blend (erythritol, stevia,
-- allulose)" reads as three), so every run hedged to "partial" on a complete master,
-- pinning ingredient_availability (weight 4) at 2.5 and escalating the ranking. Two
-- markers flag the two truncation modes: `list=complete|partial` (SQL sees its own
-- SUBSTR cut) and trailing `end_of_list` (survives only if the tail did, so its
-- ABSENCE reveals the engine's 9000 cap, invisible to SQL). Terminator stays LAST —
-- mid-string it would survive the cut it must catch.
--
-- SUBSTR 4000 not 2000: 153 names pack to 3,995 chars (avg 24, max 127); at 2000
-- only ~76 survived, halving a weight-4 factor's evidence. KNOWN LIMIT — fits only
-- while DIM_IDEA holds few briefs; at ~35-40 this truncates again and the factor
-- goes quiet (honest, but quiet). Durable fix: normalise DIM_INGREDIENT's
-- near-duplicate spellings (three erythritol/stevia/allulose blends).
SELECT
  'INGREDIENT',
  CAST(NULL AS STRING),
  'ingredient master (already sourced)',
  CONCAT('count=', CAST(i.n AS STRING),
         '; list=', IF(LENGTH(i.names) > 4000, 'partial', 'complete'),
         '; names: ', IFNULL(SUBSTR(i.names, 1, 4000), 'none'),
         '; end_of_list')
FROM (
  SELECT
    COUNT(DISTINCT LOWER(TRIM(INGREDIENT_NAME)))                                                  AS n,
    STRING_AGG(DISTINCT LOWER(TRIM(INGREDIENT_NAME)), ', ' ORDER BY LOWER(TRIM(INGREDIENT_NAME))) AS names
  FROM `gen-lang-client-0520145261.ctx_upside_master_data.DIM_INGREDIENT`
) i;

-- =====================================================================
-- LIVE (gen-lang-client-0520145261.bronze / silver / gold)
-- =====================================================================

-- Complaint node: EVENT_ID is null for rows ingested via the email-parsing
-- path (no ticketing EVENT_ID was ever assigned) — EMAIL_MESSAGE_ID is
-- present and unique whenever EVENT_ID isn't, so coalesce them into one
-- always-populated, always-unique id.
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.bronze.V_COMPLAINT_EVENTS` AS
SELECT * REPLACE (COALESCE(EVENT_ID, EMAIL_MESSAGE_ID) AS EVENT_ID)
FROM `gen-lang-client-0520145261.bronze.CUSTOMER_COMPLAINT_EVENTS`;

-- stocked_at edge: latest FLAGGED_INVENTORY row per store x SKU (one edge each).
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.bronze.V_STOCKED_AT` AS
SELECT * EXCEPT(rn) FROM (
  SELECT
    SKU_ID,
    MASTER_STORE_ID,
    TOTAL_STOCK,
    SAFE_STOCK,
    EXPIRED_STOCK,
    SOONEST_EXPIRY,
    QTY_EXPIRING_WITHIN_RISK_DAYS,
    WASTAGE_FLAG,
    LOW_STOCK_FLAG,
    SHELF_LIFE_DAYS,
    ROW_NUMBER() OVER (PARTITION BY MASTER_STORE_ID, SKU_ID ORDER BY REPORT_DATE DESC) AS rn
  FROM `gen-lang-client-0520145261.bronze.FLAGGED_INVENTORY`
)
WHERE rn = 1;

-- (forecast: no view. The Product "Forecast quantity by store" widget queries
-- the gold base table gold.FORECAST_RESULTS_UPDATE directly via a raw widget
-- query — latest run, next 1-3 days, summed per store. See link_datasets.yaml.)

-- transfer_route edge: FROM/TO_STORE_ID are the same store identity as
-- MASTER_STORE_ID (confirmed) — cast INT64 -> STRING to bridge the type difference.
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.bronze.V_TRANSFER_ROUTE` AS
SELECT
  CAST(FROM_STORE_ID AS STRING) AS FROM_STORE_ID,
  CAST(TO_STORE_ID   AS STRING) AS TO_STORE_ID,
  DISTANCE_KM,
  PREFERRED_FOR_TRANSFER
FROM `gen-lang-client-0520145261.bronze.STORE_TRANSFER_DISTANCES`;

-- complaint_about_product edge (OPTIONAL, deferred): fuzzy item-name -> SKU.
-- Enable the edge in live_bq.yaml once you've validated the match rate.
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.bronze.V_COMPLAINT_RESOLVED` AS
SELECT
  c.EVENT_ID,
  p.SKU AS SKU_ID
FROM `gen-lang-client-0520145261.bronze.V_COMPLAINT_EVENTS` c
JOIN `gen-lang-client-0520145261.ctx_upside_master_data.DIM_PRODUCT` p
  ON UPPER(TRIM(c.ITEM_NAME)) = UPPER(TRIM(p.DISPLAY_NAME));

-- Stock risk per (store, SKU) off each store's latest snapshot — the one "at risk"
-- definition shared by inventory_freshness_semantic_model's KPIs, shelf_life_risk_
-- monitoring and inventory_optimization (replaces their gather + post pipelines).
-- Expired batches are excluded; a pair with no sellable batch drops out.
-- SKU_ID / STORE_ID are the stock_config_for join columns, so the model links to
-- Product and Store. Thresholds ignore LOW_STOCK_CONFIG.IS_ACTIVE, as the edge did.
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.bronze.V_STORE_STOCK_RISK` AS
WITH latest AS (
  SELECT store_id, product_sku, available_quantity, expiry_date, batch_row_number,
         DATE_DIFF(expiry_date, CURRENT_DATE(), DAY) AS dte
  FROM `gen-lang-client-0520145261.bronze.STORE_INVENTORY_DAILY`
  QUALIFY snapshot_date = MAX(snapshot_date) OVER (PARTITION BY store_id)
),
pair AS (
  SELECT store_id AS STORE_ID, product_sku AS SKU_ID,
         SUM(available_quantity)                      AS total_available,
         SUM(IF(dte <= 3, available_quantity, 0))     AS expiring_qty,
         MIN(expiry_date)                             AS soonest_expiry,
         MIN(dte)                                     AS days_to_expiry,
         COUNT(batch_row_number)                      AS batches
  FROM latest
  WHERE dte >= 0
  GROUP BY 1, 2
)
SELECT
  p.*,
  c.MIN_DAYS_SHELF_LIFE AS min_days_shelf_life,
  c.MIN_COUNT           AS min_count,
  c.ABSOLUTE_RISK_COUNT AS absolute_risk_count,
  v.TOTAL_COGS_INR      AS unit_cogs_inr,
  CASE
    WHEN p.days_to_expiry <= c.MIN_DAYS_SHELF_LIFE AND p.total_available <= c.MIN_COUNT THEN 'both'
    WHEN p.days_to_expiry <= c.MIN_DAYS_SHELF_LIFE THEN 'wastage'
    WHEN p.total_available <= c.ABSOLUTE_RISK_COUNT THEN 'critical_low'
    WHEN p.total_available <= c.MIN_COUNT THEN 'low_stock'
    ELSE 'ok'
  END AS risk_type
FROM pair p
LEFT JOIN `gen-lang-client-0520145261.bronze.LOW_STOCK_CONFIG` c
  ON c.SKU_ID = p.SKU_ID AND c.STORE_ID = p.STORE_ID
LEFT JOIN `gen-lang-client-0520145261.ctx_upside_master_data.V_PRODUCT_ENRICHED` v
  ON v.SKU = p.SKU_ID;

-- Inventory plan inputs per (store, SKU): stock risk FULL JOIN next-3-day latest
-- forecast, plus the nearest transfer store. inventory_optimization buckets the
-- action (transfer / liquidate / supply_factory) over these rows in its `post`.
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.bronze.V_INVENTORY_PLAN_INPUTS` AS
WITH fc AS (
  -- ROUND(…, 2) matches the old rollup's rounding, so ceil() gives the same units.
  SELECT MASTER_STORE_ID AS STORE_ID, SKU_ID, ROUND(SUM(PREDICTED_SALES_QUANTITY), 2) AS forecast_3d
  FROM `gen-lang-client-0520145261.gold.FORECAST_RESULTS_UPDATE`
  WHERE IS_LATEST_FORECAST
    AND DATE_DIFF(FORECAST_DATE, CURRENT_DATE(), DAY) BETWEEN 1 AND 3
  GROUP BY 1, 2
),
nearest AS (
  SELECT FROM_STORE_ID AS STORE_ID, TO_STORE_ID AS nearest_store_id, DISTANCE_KM AS distance_km
  FROM `gen-lang-client-0520145261.bronze.V_TRANSFER_ROUTE`
  QUALIFY ROW_NUMBER() OVER (PARTITION BY FROM_STORE_ID ORDER BY DISTANCE_KM, TO_STORE_ID) = 1
)
SELECT
  COALESCE(r.STORE_ID, f.STORE_ID) AS STORE_ID,
  COALESCE(r.SKU_ID, f.SKU_ID)     AS SKU_ID,
  r.total_available                AS available_quantity,
  r.expiring_qty,
  r.soonest_expiry,
  r.days_to_expiry,
  f.forecast_3d,
  n.nearest_store_id,
  n.distance_km
FROM `gen-lang-client-0520145261.bronze.V_STORE_STOCK_RISK` r
FULL OUTER JOIN fc f ON f.STORE_ID = r.STORE_ID AND f.SKU_ID = r.SKU_ID
LEFT JOIN nearest n ON n.STORE_ID = COALESCE(r.STORE_ID, f.STORE_ID);

-- =====================================================================
-- MARKETING (gen-lang-client-0520145261.bronze)  —  campaigns + segments
-- =====================================================================

-- Store's currently-running campaigns this month. RAW_MARKETING_DATA is ad
-- data at the daily x campaign grain with no store id — RES_ID is a
-- platform-specific ad/restaurant id, resolved to MASTER_STORE_ID via
-- STORE_CHANNEL_MAPPING, matching RES_ID against ZOMATO_ID/SWIGGY_ID it came
-- from (INT64 -> STRING). Only Zomato/Swiggy are joined/resolved today;
-- extend the join and PLATFORM case below when Urban Piper/Petpooja ad data
-- is available. Keeps only campaigns live today (CURRENT_DATE
-- between START/END) and sums this calendar month's daily rows to one row
-- per campaign. Dynamic on CURRENT_DATE(), so it re-scopes to "this month /
-- running now" on every render — this is a fast-moving lazy link, not
-- materialised on apply.
-- matched_platform/RES_ID kept for traceability (which platform id resolved this row);
-- ROI recomputed from the summed totals (SAFE_DIVIDE) rather than averaging
-- RAW_MARKETING_DATA's daily per-row ratios, since this view is already collapsing
-- daily rows to one this-month-to-date row per store x campaign. ADS_M2O_PCT/
-- OVERALL_M2O_PCT are carried via ANY_VALUE of the daily ratio (not re-derived
-- from summed totals — no underlying menu-visit/order counts to sum here). DATE
-- here is MAX(r.DATE) — the most recent daily row rolled into this total, not a
-- per-day value.
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.bronze.V_STORE_CAMPAIGN_CURRENT` AS
SELECT
  m.MASTER_STORE_ID,
  r.CAMPAIGN_ID,
  ANY_VALUE(r.RES_ID) AS RES_ID,
  ANY_VALUE(
    CASE
      WHEN r.RES_ID = CAST(m.ZOMATO_ID AS STRING) THEN 'ZOMATO'
      WHEN r.RES_ID = CAST(m.SWIGGY_ID AS STRING) THEN 'SWIGGY'
      ELSE 'UNKNOWN'
    END
  ) AS PLATFORM,
  ANY_VALUE(r.PRODUCT_TYPE) AS PRODUCT_TYPE,
  ANY_VALUE(r.TARGETING) AS TARGETING,
  ANY_VALUE(r.SEGMENTS) AS SEGMENTS,
  MAX(r.DATE) AS DATE,
  MIN(r.START_DATE) AS START_DATE,
  MAX(r.END_DATE) AS END_DATE,
  ROUND(SUM(r.AD_SPEND_RS), 0) AS AD_SPEND_RS,
  ROUND(SUM(r.AD_SALES_RS), 0) AS AD_SALES_RS,
  SUM(r.AD_ORDERS) AS AD_ORDERS,
  SUM(r.AD_IMPRESSIONS) AS AD_IMPRESSIONS,
  SUM(r.AD_CLICKS) AS AD_CLICKS,
  SAFE_DIVIDE(SUM(r.AD_SALES_RS), SUM(r.AD_SPEND_RS)) AS ROI,
  ANY_VALUE(CAST(r.ADS_M2O_PCT AS FLOAT64)) AS ADS_M2O_PCT,
  ANY_VALUE(CAST(r.OVERALL_M2O_PCT AS FLOAT64)) AS OVERALL_M2O_PCT,
  -- ROAS/CTR computed here (not by the campaign_planning_optimisation agent step)
  -- because the process YAML's compute DSL has no arithmetic op (see days_until/
  -- bucket only) — same reason ROI above is SAFE_DIVIDE here rather than in the
  -- process. Keeping the agent step's job to "read this number" instead of
  -- "compute this number" removes a place it was reaching for a tool call instead.
  -- Distinct from ROI: ROAS is net return on spend (sales minus spend, relative
  -- to spend), where ROI above is gross sales-to-spend ratio.
  SAFE_DIVIDE(SUM(r.AD_SALES_RS) - SUM(r.AD_SPEND_RS), SUM(r.AD_SPEND_RS)) AS ROAS,
  SAFE_DIVIDE(SUM(r.AD_CLICKS), SUM(r.AD_IMPRESSIONS)) AS CTR
FROM `gen-lang-client-0520145261.bronze.RAW_MARKETING_DATA` r
JOIN `gen-lang-client-0520145261.bronze.STORE_CHANNEL_MAPPING` m
  ON r.RES_ID IN (
      CAST(m.ZOMATO_ID AS STRING),
      CAST(m.SWIGGY_ID AS STRING)
  )
WHERE r.DATE >= DATE_TRUNC(CURRENT_DATE(), MONTH)
  AND CURRENT_DATE() BETWEEN r.START_DATE AND r.END_DATE
GROUP BY
  m.MASTER_STORE_ID,
  r.CAMPAIGN_ID;

-- Seasonal/historical counterpart to V_STORE_CAMPAIGN_CURRENT, for
-- seasonal_campaign_planning. Same underlying problem as above — RAW_MARKETING_DATA
-- is daily ad data with no store id of its own (RES_ID is a platform ad/restaurant
-- id) — resolved via the same STORE_CHANNEL_MAPPING join against ZOMATO_ID/
-- SWIGGY_ID. The difference: this view drops V_STORE_CAMPAIGN_CURRENT's
-- CURRENT_DATE()-scoped WHERE entirely and rolls up to one row per (store,
-- campaign, CALENDAR MONTH) across ALL history instead of "this month, live
-- now" — so last year's performance around any event date is queryable by MONTH.
-- ROI/ROAS/CTR use the same SAFE_DIVIDE formulas as V_STORE_CAMPAIGN_CURRENT, for
-- the same reason noted there: the process DSL has no arithmetic op, so these
-- ratios must already be correct per row before an agent step ever reads them.
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.bronze.V_STORE_CAMPAIGN_HISTORY` AS
SELECT
  m.MASTER_STORE_ID,
  r.CAMPAIGN_ID,
  DATE_TRUNC(r.DATE, MONTH) AS MONTH,
  ANY_VALUE(r.RES_ID) AS RES_ID,
  ANY_VALUE(
    CASE
      WHEN r.RES_ID = CAST(m.ZOMATO_ID AS STRING) THEN 'ZOMATO'
      WHEN r.RES_ID = CAST(m.SWIGGY_ID AS STRING) THEN 'SWIGGY'
      ELSE 'UNKNOWN'
    END
  ) AS PLATFORM,
  ANY_VALUE(r.PRODUCT_TYPE) AS PRODUCT_TYPE,
  ANY_VALUE(r.TARGETING) AS TARGETING,
  ANY_VALUE(r.SEGMENTS) AS SEGMENTS,
  MIN(r.DATE) AS WINDOW_START,
  MAX(r.DATE) AS WINDOW_END,
  ROUND(SUM(r.AD_SPEND_RS), 0) AS AD_SPEND_RS,
  ROUND(SUM(r.AD_SALES_RS), 0) AS AD_SALES_RS,
  SUM(r.AD_ORDERS) AS AD_ORDERS,
  SUM(r.AD_IMPRESSIONS) AS AD_IMPRESSIONS,
  SUM(r.AD_CLICKS) AS AD_CLICKS,
  SAFE_DIVIDE(SUM(r.AD_SALES_RS), SUM(r.AD_SPEND_RS)) AS ROI,
  ANY_VALUE(CAST(r.ADS_M2O_PCT AS FLOAT64)) AS ADS_M2O_PCT,
  ANY_VALUE(CAST(r.OVERALL_M2O_PCT AS FLOAT64)) AS OVERALL_M2O_PCT,
  SAFE_DIVIDE(SUM(r.AD_SALES_RS) - SUM(r.AD_SPEND_RS), SUM(r.AD_SPEND_RS)) AS ROAS,
  SAFE_DIVIDE(SUM(r.AD_CLICKS), SUM(r.AD_IMPRESSIONS)) AS CTR
FROM `gen-lang-client-0520145261.bronze.RAW_MARKETING_DATA` r
JOIN `gen-lang-client-0520145261.bronze.STORE_CHANNEL_MAPPING` m
  ON r.RES_ID IN (
      CAST(m.ZOMATO_ID AS STRING),
      CAST(m.SWIGGY_ID AS STRING)
  )
GROUP BY
  m.MASTER_STORE_ID,
  r.CAMPAIGN_ID,
  MONTH;

-- segment_on_channel edge: MARKETING_SEGMENT_MASTER.CHANNEL ('SWIGGY'/'ZOMATO')
-- resolves to the Channel node by name (DIM_CHANNEL.CHANNEL_NAME). Gives each
-- CustomerSegment its Channel id (CH-012 Swiggy / CH-015 Zomato).
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.bronze.V_SEGMENT_ON_CHANNEL` AS
SELECT
  s.SEGMENT_ID,
  ch.CHANNEL_ID
FROM `gen-lang-client-0520145261.bronze.MARKETING_SEGMENT_MASTER` s
JOIN `gen-lang-client-0520145261.ctx_upside_master_data.DIM_CHANNEL` ch
  ON UPPER(ch.CHANNEL_NAME) = UPPER(s.CHANNEL);

-- Segment budget allocations: MARKETING_BUDGET.SEGMENT_TYPE == SEGMENT_CODE
-- (per channel) -> exposes SEGMENT_ID so the link can scope to one segment.
-- Shows which stores fund this segment, on which channel, and how much.
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.bronze.V_SEGMENT_BUDGET` AS
SELECT
  s.SEGMENT_ID,
  b.MASTER_STORE_ID,
  b.STORE_NAME,
  b.CHANNEL,
  b.BUDGET_MONTH,
  b.ALLOCATED_BUDGET_RS,
  b.EXPECTED_REVENUE_RS
FROM `gen-lang-client-0520145261.bronze.MARKETING_BUDGET` b
JOIN `gen-lang-client-0520145261.bronze.MARKETING_SEGMENT_MASTER` s
  ON b.SEGMENT_TYPE = s.SEGMENT_CODE
 AND UPPER(b.CHANNEL) = UPPER(s.CHANNEL);

-- ============================================================================
-- ============================================================================
-- V_REVIEW_COMPLAINT_CANDIDATES -- input to formulation_feedback_loop process.
-- ============================================================================
-- Narrows low-rated reviews (<= 3 stars) from the last 30 days. Formats date (D),
-- computes integer day index (N) for rolling 14-day window evaluation, truncates
-- text (T) to 140 chars for prompt budget, and extracts matched SKU (P).
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.bronze.V_REVIEW_COMPLAINT_CANDIDATES` AS
WITH fams AS (
  SELECT MIN(SKU) AS SKU, FAM FROM (
    SELECT SKU, TRIM(REGEXP_REPLACE(
        REGEXP_REPLACE(DISPLAY_NAME, r'(?i)^(Dessert|Mithai|Snack|Savoury|Fudge)\s*-\s*', ''),
        r'(?i)[-\s]*\d+\s*(gm|gms|g|kg|ml)\b\.?', '')) AS FAM
    FROM `gen-lang-client-0520145261.ctx_upside_master_data.V_PRODUCT_ENRICHED`
    WHERE IS_ACTIVE)
  GROUP BY FAM
),
base AS (
  SELECT
    REVIEW_ID,
    MASTER_STORE_ID                            AS S,
    FORMAT_DATE('%Y-%m-%d', DATE(REVIEW_DATE)) AS D,
    DATE_DIFF(DATE(REVIEW_DATE), DATE '2026-01-01', DAY) AS N,
    SUBSTR(REVIEW_TEXT, 0, 140)                AS T
  FROM `gen-lang-client-0520145261.bronze.CUSTOMER_REVIEW_EVENTS`
  WHERE REVIEW_DATE >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
    AND STAR_RATING <= 3
)
SELECT b.S, b.D, b.N, b.T, IFNULL(f.SKU, '') AS P
FROM base b
LEFT JOIN fams f ON STRPOS(UPPER(b.T), UPPER(f.FAM)) > 0
-- Deduplicate reviews matching multiple product families (longest match wins).
QUALIFY ROW_NUMBER() OVER (PARTITION BY b.REVIEW_ID
                           ORDER BY LENGTH(IFNULL(f.FAM, '')) DESC) = 1;


-- ============================================================================
-- V_PRODUCT_FAMILY_NAMES -- closed product vocabulary for formulation_feedback_loop.
-- ============================================================================
-- Single-row reference view aggregating active product family names (NM) and 
-- entry-pack COGS (CG) into a pipe-separated string to ground LLM clustering.
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.ctx_upside_master_data.V_PRODUCT_FAMILY_NAMES` AS
SELECT
  'FAMILIES' AS ID,                       -- constant: the link needs a join column, but this is never entity-scoped
  STRING_AGG(fam, ' | ' ORDER BY fam) AS NM,
  STRING_AGG(IF(cogs IS NULL, NULL, FORMAT('%s=%d', fam, cogs)), ' | ' ORDER BY fam) AS CG
FROM (
  SELECT
    TRIM(
      REGEXP_REPLACE(
        REGEXP_REPLACE(DISPLAY_NAME, r'(?i)^(Dessert|Mithai|Snack|Savoury|Fudge)\s*-\s*', ''),
        r'(?i)[-\s]*\d+\s*(gm|gms|g|kg|ml)\b\.?', '')
    ) AS fam,
    CAST(ROUND(MIN(CAST(TOTAL_COGS_INR AS FLOAT64))) AS INT64) AS cogs
  FROM `gen-lang-client-0520145261.ctx_upside_master_data.V_PRODUCT_ENRICHED`
  WHERE IS_ACTIVE
  GROUP BY fam
);

-- =====================================================================
-- LISTING PACKAGE (gen-lang-client-0520145261.ctx_upside_master_data)
-- Feeds processes/new_listing_creation.yaml. The listing content itself is a
-- straight assembly job; what these views add is ACCURACY -- they normalise the
-- OCR'd nutrition panel, re-express it on both legal bases, check every on-pack
-- claim against the lab figure, and derive the allergens the recipe implies so an
-- under-declaration is caught before a marketplace ever sees it.
-- Order matters: NUTRIENT_CLEAN -> CLAIM_CHECK -> LISTING_PACKAGE.
-- =====================================================================

-- Canonical nutrition panel. PRODUCT_NUTRIENT is vision-OCR output, so the same
-- nutrient arrives as 'Total fat'/'total fat', 'Dietary fiber'/'Diatery fiber'/
-- 'Diaterary fiber', energy in 'Kcal'/'kcal'/'kcl', grams as 'g'/'gm' -- and the
-- panel's own header rows ('Amount per 100 gm', 'serving Size') leaked in as if they
-- were nutrients. This collapses the variants to one vocabulary, drops the headers,
-- and recovers from them the DECLARATION BASIS, without which no nutrition figure
-- can be published (14.71 g protein per 100 g and per 70 g serving are different
-- listings). Marks which nutrients FSSAI mandates and the legal print order.
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.ctx_upside_master_data.V_PRODUCT_NUTRIENT_CLEAN` AS
WITH raw AS (
  SELECT
    SKU,
    NUTRIENT_NAME AS RAW_NAME,
    LOWER(TRIM(NUTRIENT_NAME)) AS n,
    VALUE, UNIT, DV_PCT
  FROM `gen-lang-client-0520145261.ctx_upside_master_data.PRODUCT_NUTRIENT`
),
-- Per-SKU declaration basis, recovered from the OCR header rows that leaked into
-- the table as if they were nutrients ("Amount per 100 gm" / "Amount per serving").
basis AS (
  SELECT
    SKU,
    CASE
      WHEN LOGICAL_OR(n LIKE 'amount per 100%') THEN 'per_100g'
      WHEN LOGICAL_OR(n LIKE 'amount per serv%') THEN 'per_serving'
      -- No basis header survived OCR, but the panel's own serving row says 100 g —
      -- the values are on the per-100 g basis by construction. Labelled `_inferred`
      -- so the listing gate can treat it as a warning, not as verified truth.
      WHEN MAX(IF(n LIKE 'serving size', VALUE, NULL)) = 100 THEN 'per_100g_inferred'
      ELSE 'unknown'
    END AS NUTRIENT_BASIS,
    MAX(IF(n LIKE 'serving size', VALUE, NULL)) AS PANEL_SERVING_GM
  FROM raw GROUP BY SKU
),
canon AS (
  SELECT
    r.SKU, r.RAW_NAME, r.VALUE, r.DV_PCT,
    CASE
      WHEN r.n LIKE '%amount per%' OR r.n LIKE 'serving size' THEN NULL   -- OCR header, not a nutrient
      WHEN r.n LIKE '%calorie%' OR r.n LIKE '%energy%'         THEN 'Energy'
      WHEN r.n LIKE '%protein%'                                THEN 'Protein'
      WHEN r.n LIKE '%saturated%fat%'                          THEN 'Saturated Fat'
      WHEN r.n LIKE '%trans%fat%'                              THEN 'Trans Fat'
      WHEN r.n LIKE '%fat%'                                    THEN 'Total Fat'
      WHEN r.n LIKE '%added%sugar%'                            THEN 'Added Sugars'
      WHEN r.n LIKE '%net%carb%'                               THEN 'Net Carbohydrate'
      WHEN r.n LIKE '%carb%'                                   THEN 'Total Carbohydrate'
      WHEN r.n LIKE '%sugar%'                                  THEN 'Total Sugars'
      WHEN r.n LIKE '%fib%'                                    THEN 'Dietary Fibre'
      WHEN r.n LIKE '%sodium%'                                 THEN 'Sodium'
      WHEN r.n LIKE '%cholesterol%'                            THEN 'Cholesterol'
      ELSE NULL
    END AS NUTRIENT,
    CASE
      WHEN r.n LIKE '%calorie%' OR r.n LIKE '%energy%' THEN 'kcal'
      WHEN LOWER(IFNULL(r.UNIT, '')) IN ('g', 'gm', 'gms', 'gram') THEN 'g'
      WHEN LOWER(IFNULL(r.UNIT, '')) = 'mg' THEN 'mg'
      ELSE NULLIF(LOWER(TRIM(IFNULL(r.UNIT, ''))), '')
    END AS UNIT
  FROM raw r
)
SELECT
  c.SKU,
  c.NUTRIENT,
  c.RAW_NAME,
  c.VALUE,
  c.UNIT,
  c.DV_PCT,
  b.NUTRIENT_BASIS,
  b.PANEL_SERVING_GM,
  c.NUTRIENT IN ('Energy','Protein','Total Carbohydrate','Total Sugars','Added Sugars',
                 'Total Fat','Saturated Fat','Trans Fat','Sodium') AS IS_FSSAI_MANDATORY,
  c.VALUE IS NULL AS VALUE_MISSING,
  -- FSSAI panel print order, so the listing renders the panel the legal way.
  CASE c.NUTRIENT
    WHEN 'Energy' THEN 1 WHEN 'Total Fat' THEN 2 WHEN 'Saturated Fat' THEN 3
    WHEN 'Trans Fat' THEN 4 WHEN 'Cholesterol' THEN 5 WHEN 'Total Carbohydrate' THEN 6
    WHEN 'Total Sugars' THEN 7 WHEN 'Added Sugars' THEN 8 WHEN 'Dietary Fibre' THEN 9
    WHEN 'Protein' THEN 10 WHEN 'Sodium' THEN 11 ELSE 99
  END AS PANEL_ORDER
FROM canon c
JOIN basis b USING (SKU)
WHERE c.NUTRIENT IS NOT NULL;

-- One row per on-pack claim, checked against the lab panel. PRODUCT_HIGHLIGHT is
-- free marketing text copied across pack sizes and flavours ('17g Protein' sits on
-- all six cheesecake SKUs, whose measured protein ranges 11.42-14.71 g), so each
-- claim is parsed into {nutrient, asserted value, basis}, compared against the same
-- nutrient re-expressed on the basis the claim itself asserts, and given a verdict.
-- A NULL lab value never reads as zero -- it reads as 'no_lab_value'.
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.ctx_upside_master_data.V_LISTING_CLAIM_CHECK` AS
WITH panel AS (
  SELECT SKU, NUTRIENT, VALUE, UNIT, NUTRIENT_BASIS, PANEL_SERVING_GM
  FROM `gen-lang-client-0520145261.ctx_upside_master_data.V_PRODUCT_NUTRIENT_CLEAN`
),
-- Same value re-expressed on both legal bases, so a claim can be checked against
-- whichever basis it actually asserts.
panel_both AS (
  SELECT
    SKU, NUTRIENT, UNIT, NUTRIENT_BASIS, PANEL_SERVING_GM,
    CASE WHEN NUTRIENT_BASIS LIKE 'per_100g%' THEN VALUE
         WHEN NUTRIENT_BASIS = 'per_serving' AND PANEL_SERVING_GM > 0 THEN ROUND(VALUE * 100 / PANEL_SERVING_GM, 2)
    END AS LAB_PER_100G,
    CASE WHEN NUTRIENT_BASIS = 'per_serving' THEN VALUE
         WHEN NUTRIENT_BASIS LIKE 'per_100g%' AND PANEL_SERVING_GM > 0 THEN ROUND(VALUE * PANEL_SERVING_GM / 100, 2)
    END AS LAB_PER_SERVING
  FROM panel
),
claims AS (
  SELECT
    c.CLAIM_ID, c.SKU, c.HIGHLIGHT_SEQ, c.HIGHLIGHT_TEXT AS CLAIM_TEXT,
    LOWER(TRIM(c.HIGHLIGHT_TEXT)) AS t
  FROM `gen-lang-client-0520145261.ctx_upside_master_data.V_PRODUCT_CLAIM` c
),
parsed AS (
  SELECT
    CLAIM_ID, SKU, HIGHLIGHT_SEQ, CLAIM_TEXT, t,
    CASE
      WHEN t LIKE '%saturated%fat%'                 THEN 'Saturated Fat'
      WHEN t LIKE '%trans%fat%'                     THEN 'Trans Fat'
      WHEN t LIKE '%protein%'                       THEN 'Protein'
      WHEN t LIKE '%carb%'                          THEN 'Total Carbohydrate'
      WHEN t LIKE '%added sugar%'                   THEN 'Added Sugars'
      WHEN t LIKE '%sugar%'                         THEN 'Total Sugars'
      WHEN t LIKE '%fib%'                           THEN 'Dietary Fibre'
      WHEN t LIKE '%sodium%' OR t LIKE '%salt%'     THEN 'Sodium'
      WHEN t LIKE '%calorie%' OR t LIKE '%energy%'  THEN 'Energy'
      WHEN t LIKE '%fat%'                           THEN 'Total Fat'
      ELSE NULL
    END AS NUTRIENT,
    -- First number in the text: handles both "17g Protein" and "Saturated fat 1g".
    -- Skipped for "%" texts ("100% plant based") so a percentage is never read as grams.
    IF(t LIKE '%\\%%', NULL,
       SAFE_CAST(REGEXP_EXTRACT(t, r'([0-9]+(?:\.[0-9]+)?)') AS FLOAT64)) AS ASSERTED_VALUE,
    IF(t LIKE '%per serving%', 'per_serving', 'as_declared') AS CLAIM_BASIS,
    (t LIKE 'no %' OR t LIKE '%-free%' OR t LIKE '% free' OR t LIKE '%free%'
     OR t LIKE '%without%' OR t LIKE 'zero %') AS IS_ABSENCE
  FROM claims
),
typed AS (
  SELECT
    p.*,
    CASE
      -- A number with no nutrient attached ("10.83 gm") is broken PIM data, not a claim.
      WHEN p.NUTRIENT IS NULL AND p.ASSERTED_VALUE IS NOT NULL  THEN 'malformed'
      WHEN p.NUTRIENT IS NULL                                   THEN 'non_nutritional'
      WHEN p.ASSERTED_VALUE IS NOT NULL                         THEN 'quantified'
      WHEN p.IS_ABSENCE                                         THEN 'absence'
      ELSE 'comparative'
    END AS CLAIM_KIND
  FROM parsed p
)
SELECT
  y.CLAIM_ID, y.SKU, y.HIGHLIGHT_SEQ, y.CLAIM_TEXT, y.CLAIM_KIND,
  y.NUTRIENT, y.ASSERTED_VALUE, y.CLAIM_BASIS,
  b.NUTRIENT_BASIS AS PANEL_BASIS, b.UNIT AS LAB_UNIT,
  b.LAB_PER_100G, b.LAB_PER_SERVING, b.PANEL_SERVING_GM,
  -- The lab figure the claim should be measured against.
  IF(y.CLAIM_BASIS = 'per_serving', b.LAB_PER_SERVING, b.LAB_PER_100G) AS LAB_VALUE_COMPARED,
  CASE
    WHEN y.ASSERTED_VALUE IS NULL THEN NULL
    ELSE ROUND(
      100 * (y.ASSERTED_VALUE - IF(y.CLAIM_BASIS = 'per_serving', b.LAB_PER_SERVING, b.LAB_PER_100G))
      / NULLIF(IF(y.CLAIM_BASIS = 'per_serving', b.LAB_PER_SERVING, b.LAB_PER_100G), 0), 1)
  END AS DEVIATION_PCT,
  CASE
    WHEN y.CLAIM_KIND = 'malformed'                           THEN 'MALFORMED_CLAIM'
    WHEN y.CLAIM_KIND = 'non_nutritional'                     THEN 'not_verifiable_from_pim'
    WHEN y.CLAIM_KIND = 'comparative'                          THEN 'needs_threshold_check'
    -- No panel row at all, OR a row whose VALUE never made it through OCR. Both mean
    -- there is nothing to check the claim against — never let a NULL read as zero.
    WHEN b.NUTRIENT IS NULL
      OR (b.LAB_PER_100G IS NULL AND b.LAB_PER_SERVING IS NULL) THEN 'no_lab_value'
    -- A zero / absence assertion ("No Added Sugar", "0g Trans Fat") is basis-independent:
    -- zero is zero per 100 g and per serving alike, so check it before the basis gate.
    WHEN IFNULL(y.ASSERTED_VALUE, 0) = 0 THEN
      IF(IFNULL(b.LAB_PER_100G, IFNULL(b.LAB_PER_SERVING, 0)) = 0, 'substantiated', 'CONTRADICTED')
    WHEN b.NUTRIENT_BASIS = 'unknown'                         THEN 'basis_unknown'
    WHEN IF(y.CLAIM_BASIS = 'per_serving', b.LAB_PER_SERVING, b.LAB_PER_100G) IS NULL THEN 'no_lab_value'
    WHEN ABS(100 * (y.ASSERTED_VALUE - IF(y.CLAIM_BASIS = 'per_serving', b.LAB_PER_SERVING, b.LAB_PER_100G))
             / NULLIF(IF(y.CLAIM_BASIS = 'per_serving', b.LAB_PER_SERVING, b.LAB_PER_100G), 0)) <= 5 THEN 'substantiated'
    WHEN ABS(100 * (y.ASSERTED_VALUE - IF(y.CLAIM_BASIS = 'per_serving', b.LAB_PER_SERVING, b.LAB_PER_100G))
             / NULLIF(IF(y.CLAIM_BASIS = 'per_serving', b.LAB_PER_SERVING, b.LAB_PER_100G), 0)) <= 20 THEN 'review_tolerance'
    ELSE 'MISMATCH'
  END AS VERDICT
FROM typed y
LEFT JOIN panel_both b ON b.SKU = y.SKU AND b.NUTRIENT = y.NUTRIENT;

-- The complete listing package for one SKU, 1:1, plus its deterministic readiness.
-- Everything a channel asks for -- name, net quantity, veg mark, MRP, GST, barcode,
-- FSSAI licence (regex-extracted from the free-text legal block), manufacturer,
-- storage, ingredient list, allergen declaration, claims, nutrition panel, lab
-- report, image folder -- and then BLOCKING_GAPS / WARNING_GAPS: what would make a
-- marketplace or FSSAI reject this listing, computed in SQL so the gate is the same
-- every run. Long fields are aggregated to scalars on purpose: a 1-row fact reaches
-- the agent whole, where a row list would be previewed to 4 rows (_compact_facts).
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.ctx_upside_master_data.V_LISTING_PACKAGE` AS
WITH ing AS (
  SELECT m.SKU,
         STRING_AGG(i.INGREDIENT_NAME, ', ' ORDER BY m.INGREDIENT_ID) AS INGREDIENT_LIST,
         COUNT(*) AS INGREDIENT_COUNT
  FROM `gen-lang-client-0520145261.ctx_upside_master_data.MAP_PRODUCT_INGREDIENT` m
  JOIN `gen-lang-client-0520145261.ctx_upside_master_data.DIM_INGREDIENT` i USING (INGREDIENT_ID)
  GROUP BY m.SKU
),
-- The recipe is recorded on ONE pack size per (product line, flavour) — 22 of 41 live
-- SKUs have no ingredient rows of their own purely because they are a different size of
-- a SKU that does. Nominate the nearest such sibling as a donor so the listing can be
-- assembled; provenance is surfaced as INGREDIENT_SOURCE so inherited data is never
-- mistaken for verified data.
donor AS (
  SELECT SKU, DONOR_SKU FROM (
    SELECT
      p.SKU,
      d.SKU AS DONOR_SKU,
      ROW_NUMBER() OVER (
        PARTITION BY p.SKU
        ORDER BY ABS(IFNULL(d.SIZE_GM, 0) - IFNULL(p.SIZE_GM, 0)), d.SKU
      ) AS rn
    FROM `gen-lang-client-0520145261.ctx_upside_master_data.DIM_PRODUCT` p
    JOIN `gen-lang-client-0520145261.ctx_upside_master_data.DIM_PRODUCT` d
      ON  d.SKU != p.SKU
      AND d.PRODUCT_LINE_ID = p.PRODUCT_LINE_ID
      AND IFNULL(d.FLAVOUR, '') = IFNULL(p.FLAVOUR, '')
    JOIN ing hi ON hi.SKU = d.SKU
    LEFT JOIN ing own ON own.SKU = p.SKU
    WHERE own.SKU IS NULL
  ) WHERE rn = 1
),
alg AS (
  SELECT m.SKU,
         STRING_AGG(IF(m.CONTAINS_TYPE = 'contains', a.ALLERGEN_NAME, NULL), ', ' ORDER BY a.ALLERGEN_NAME) AS ALLERGEN_CONTAINS,
         STRING_AGG(IF(m.CONTAINS_TYPE = 'may_contain', a.ALLERGEN_NAME, NULL), ', ' ORDER BY a.ALLERGEN_NAME) AS ALLERGEN_MAY_CONTAIN,
         COUNT(*) AS ALLERGEN_ROWS
  FROM `gen-lang-client-0520145261.ctx_upside_master_data.MAP_PRODUCT_ALLERGEN` m
  JOIN `gen-lang-client-0520145261.ctx_upside_master_data.DIM_ALLERGEN` a USING (ALLERGEN_ID)
  GROUP BY m.SKU
),
-- Allergens the recipe IMPLIES, derived from the ingredient names. Compared against the
-- DECLARED containment type below: an implied allergen carried only as "may_contain" is a
-- mis-declaration, not a conservative one. One ingredient can imply several allergens
-- ("Erythritol blend + whey protein isolate" = Polyols AND Dairy), so each allergen is an
-- independent test rather than a first-match CASE.
--
-- ponytail: keyword heuristic. The real fix is an ALLERGEN_ID column on DIM_INGREDIENT;
-- until the PIM has one, decoy words are stripped before matching (nutmeg/coconut are not
-- tree nuts; cocoa/peanut butter are not dairy).
ing_allergen AS (
  SELECT
    m.SKU,
    REGEXP_REPLACE(LOWER(i.INGREDIENT_NAME), r'nutmeg|coconut', '') AS n_nut,
    REGEXP_REPLACE(LOWER(i.INGREDIENT_NAME), r'cocoa butter|peanut butter|nut butter|shea butter', '') AS n_dairy,
    LOWER(i.INGREDIENT_NAME) AS n
  FROM `gen-lang-client-0520145261.ctx_upside_master_data.MAP_PRODUCT_INGREDIENT` m
  JOIN `gen-lang-client-0520145261.ctx_upside_master_data.DIM_INGREDIENT` i USING (INGREDIENT_ID)
),
alg_implied AS (
  SELECT SKU, STRING_AGG(DISTINCT a, ', ' ORDER BY a) AS ALLERGEN_IMPLIED_BY_RECIPE
  FROM ing_allergen,
  UNNEST(ARRAY(SELECT x FROM UNNEST([
    IF(REGEXP_CONTAINS(n_nut,   r'almond|cashew|walnut|pistachio|hazelnut|pecan|peanut|\bnuts?\b'), 'Nuts',    NULL),
    IF(REGEXP_CONTAINS(n_dairy, r'\bmilk|cream|\bbutter|cheese|paneer|khoya|ghee|curd|yoghurt|yogurt|whey|casein|mawa|malai|rabdi'), 'Dairy', NULL),
    IF(REGEXP_CONTAINS(n,       r'\begg|albumen'),                                                   'Eggs',    NULL),
    IF(REGEXP_CONTAINS(n,       r'erythritol|xylitol|maltitol|sorbitol|mannitol|lactitol|isomalt|polyol'), 'Polyols', NULL)
  ]) x WHERE x IS NOT NULL)) AS a
  GROUP BY SKU
),
clm AS (
  SELECT SKU,
         STRING_AGG(HIGHLIGHT_TEXT, ' | ' ORDER BY HIGHLIGHT_SEQ) AS CLAIMS,
         COUNT(*) AS CLAIM_COUNT
  FROM `gen-lang-client-0520145261.ctx_upside_master_data.PRODUCT_HIGHLIGHT`
  GROUP BY SKU
),
chk AS (
  SELECT SKU,
         COUNTIF(VERDICT IN ('MISMATCH', 'CONTRADICTED', 'MALFORMED_CLAIM')) AS CLAIM_BLOCKING_COUNT,
         COUNTIF(VERDICT IN ('review_tolerance', 'basis_unknown', 'no_lab_value', 'needs_threshold_check')) AS CLAIM_REVIEW_COUNT,
         COUNTIF(VERDICT = 'substantiated') AS CLAIM_SUBSTANTIATED_COUNT,
         -- Only the failing claims, in full (no preview truncation): this is what the
         -- reviewer and the agent must read before anything is published.
         STRING_AGG(
           IF(VERDICT IN ('MISMATCH', 'CONTRADICTED', 'MALFORMED_CLAIM'),
              FORMAT('%s -> lab %s %s (%s), %s%%: %s',
                     CLAIM_TEXT,
                     IFNULL(CAST(LAB_VALUE_COMPARED AS STRING), 'n/a'), IFNULL(LAB_UNIT, ''),
                     IFNULL(CLAIM_BASIS, ''), IFNULL(CAST(DEVIATION_PCT AS STRING), 'n/a'), VERDICT),
              NULL),
           '; ' ORDER BY HIGHLIGHT_SEQ) AS CLAIM_FAILURES
  FROM `gen-lang-client-0520145261.ctx_upside_master_data.V_LISTING_CLAIM_CHECK`
  GROUP BY SKU
),
pan AS (
  SELECT SKU,
         ANY_VALUE(NUTRIENT_BASIS) AS NUTRIENT_BASIS,
         ANY_VALUE(PANEL_SERVING_GM) AS PANEL_SERVING_GM,
         -- FSSAI-ordered panel as one printable string, so the whole panel reaches the
         -- listing (and the LLM) in a single 1:1 fact instead of a previewed row list.
         STRING_AGG(
           FORMAT('%s: %s %s%s', NUTRIENT, IFNULL(CAST(VALUE AS STRING), 'MISSING'), IFNULL(UNIT, ''),
                  IF(DV_PCT IS NULL, '', FORMAT(' (%s%% RDA)', CAST(DV_PCT AS STRING)))),
           '; ' ORDER BY PANEL_ORDER) AS NUTRITION_PANEL,
         COUNTIF(IS_FSSAI_MANDATORY AND NOT VALUE_MISSING) AS MANDATORY_NUTRIENTS_PRESENT,
         STRING_AGG(IF(IS_FSSAI_MANDATORY AND VALUE_MISSING, NUTRIENT, NULL), ', ' ORDER BY PANEL_ORDER) AS MANDATORY_NUTRIENTS_BLANK
  FROM `gen-lang-client-0520145261.ctx_upside_master_data.V_PRODUCT_NUTRIENT_CLEAN`
  GROUP BY SKU
),
base AS (
  SELECT
    p.SKU, p.DISPLAY_NAME, p.FLAVOUR, p.SIZE_LABEL, p.SIZE_GM, p.VEG_NONVEG, p.VERSION,
    p.STATUS, p.IS_ACTIVE, NULLIF(TRIM(IFNULL(p.DESCRIPTION, '')), '') AS DESCRIPTION,
    NULLIF(TRIM(IFNULL(p.IMAGES_LINK, '')), '') AS IMAGES_LINK,
    cat.CATEGORY_NAME, pl.PRODUCT_LINE_NAME,
    pr.MRP_INR, pr.GST_RATE, pr.BASE_PRICE_INR, pr.TOTAL_COGS_INR, pr.SHELF_LIFE_DAYS,
    pk.PACKAGING_TYPE, NULLIF(TRIM(IFNULL(pk.GS1_BARCODE, '')), '') AS GS1_BARCODE,
    -- The 14-digit FSSAI licence, pulled out of the free-text legal block that the
    -- product-information sheet keeps it in ("(2) Lic.No-11524036000508").
    REGEXP_EXTRACT(IFNULL(pk.ORG_LABELLING_COMPLIANCE, ''), r'(\d{14})') AS FSSAI_LICENCE_NO,
    TRIM(REGEXP_EXTRACT(IFNULL(pk.ORG_LABELLING_COMPLIANCE, ''), r'(?i)marketed by:?\s*([^\n]+)')) AS MANUFACTURER,
    NULLIF(TRIM(IFNULL(pk.STORAGE_GUIDELINES, '')), '') AS STORAGE_GUIDELINES,
    NULLIF(TRIM(IFNULL(pk.CONSUMPTION_INSTRUCTIONS, '')), '') AS CONSUMPTION_INSTRUCTIONS,
    NULLIF(TRIM(IFNULL(pk.BRAND_POSITIONING, '')), '') AS BRAND_POSITIONING,
    NULLIF(TRIM(IFNULL(nu.SERVING_SIZE, '')), '') AS SERVING_SIZE,
    NULLIF(TRIM(IFNULL(nu.LAB_REPORT_LINK, '')), '') AS LAB_REPORT_LINK,
    nu.REPORT_VALIDITY,
    IF(nu.REPORT_VALIDITY IS NULL, NULL, DATE_DIFF(CURRENT_DATE(), nu.REPORT_VALIDITY, DAY)) AS LAB_REPORT_AGE_DAYS
  FROM `gen-lang-client-0520145261.ctx_upside_master_data.DIM_PRODUCT` p
  LEFT JOIN `gen-lang-client-0520145261.ctx_upside_master_data.DIM_CATEGORY`     cat ON cat.CATEGORY_ID = p.CATEGORY_ID
  LEFT JOIN `gen-lang-client-0520145261.ctx_upside_master_data.DIM_PRODUCT_LINE` pl  ON pl.PRODUCT_LINE_ID = p.PRODUCT_LINE_ID
  LEFT JOIN `gen-lang-client-0520145261.ctx_upside_master_data.PRODUCT_PRICING`   pr USING (SKU)
  LEFT JOIN `gen-lang-client-0520145261.ctx_upside_master_data.PRODUCT_PACKAGING` pk USING (SKU)
  LEFT JOIN `gen-lang-client-0520145261.ctx_upside_master_data.PRODUCT_NUTRITION` nu USING (SKU)
),
joined AS (
  SELECT
    b.*,
    COALESCE(ing.INGREDIENT_LIST, ding.INGREDIENT_LIST) AS INGREDIENT_LIST,
    IFNULL(COALESCE(ing.INGREDIENT_COUNT, ding.INGREDIENT_COUNT), 0) AS INGREDIENT_COUNT,
    CASE WHEN ing.SKU IS NOT NULL THEN 'own'
         WHEN ding.SKU IS NOT NULL THEN CONCAT('inherited_from:', dn.DONOR_SKU)
         ELSE 'missing' END AS INGREDIENT_SOURCE,
    alg.ALLERGEN_CONTAINS, alg.ALLERGEN_MAY_CONTAIN, IFNULL(alg.ALLERGEN_ROWS, 0) AS ALLERGEN_ROWS,
    COALESCE(ai.ALLERGEN_IMPLIED_BY_RECIPE, dai.ALLERGEN_IMPLIED_BY_RECIPE) AS ALLERGEN_IMPLIED_BY_RECIPE,
    clm.CLAIMS, IFNULL(clm.CLAIM_COUNT, 0) AS CLAIM_COUNT,
    IFNULL(chk.CLAIM_BLOCKING_COUNT, 0) AS CLAIM_BLOCKING_COUNT,
    IFNULL(chk.CLAIM_REVIEW_COUNT, 0) AS CLAIM_REVIEW_COUNT,
    IFNULL(chk.CLAIM_SUBSTANTIATED_COUNT, 0) AS CLAIM_SUBSTANTIATED_COUNT,
    chk.CLAIM_FAILURES,
    IFNULL(pan.NUTRIENT_BASIS, 'no_panel') AS NUTRIENT_BASIS,
    pan.PANEL_SERVING_GM, pan.NUTRITION_PANEL,
    IFNULL(pan.MANDATORY_NUTRIENTS_PRESENT, 0) AS MANDATORY_NUTRIENTS_PRESENT,
    pan.MANDATORY_NUTRIENTS_BLANK
  FROM base b
  LEFT JOIN ing            ON ing.SKU = b.SKU
  LEFT JOIN donor dn       ON dn.SKU = b.SKU
  LEFT JOIN ing ding       ON ding.SKU = dn.DONOR_SKU          -- donor's recipe
  LEFT JOIN alg_implied dai ON dai.SKU = dn.DONOR_SKU           -- donor's implied allergens
  LEFT JOIN alg            ON alg.SKU = b.SKU
  LEFT JOIN alg_implied ai ON ai.SKU = b.SKU
  LEFT JOIN clm            ON clm.SKU = b.SKU
  LEFT JOIN chk            ON chk.SKU = b.SKU
  LEFT JOIN pan            ON pan.SKU = b.SKU
),
-- Allergens the recipe implies but that are declared only as "may contain" (or not
-- declared at all). Set-difference done in SQL so the gate is deterministic.
mis AS (
  SELECT
    j.SKU,
    ARRAY_TO_STRING(ARRAY(
      SELECT a FROM UNNEST(SPLIT(IFNULL(j.ALLERGEN_IMPLIED_BY_RECIPE, ''), ', ')) a
      WHERE a != '' AND a NOT IN UNNEST(SPLIT(IFNULL(j.ALLERGEN_CONTAINS, ''), ', '))
    ), ', ') AS ALLERGEN_UNDERDECLARED
  FROM joined j
)
SELECT
  j.*,
  NULLIF(m.ALLERGEN_UNDERDECLARED, '') AS ALLERGEN_UNDERDECLARED,
  -- ---- Deterministic readiness ------------------------------------------------
  -- BLOCKING: a marketplace or FSSAI would reject the listing (or it would be a
  -- mis-declaration). WARNING: publishable, but the listing is thin or unverified.
  ARRAY_TO_STRING(ARRAY(SELECT g FROM UNNEST([
    IF(j.FSSAI_LICENCE_NO IS NULL, 'No FSSAI licence number on record', NULL),
    IF(j.MRP_INR IS NULL, 'No MRP', NULL),
    IF(j.SIZE_LABEL IS NULL, 'No net quantity', NULL),
    IF(j.VEG_NONVEG IS NULL, 'No veg / non-veg mark', NULL),
    IF(j.INGREDIENT_SOURCE = 'missing', 'No ingredient list (and no sibling SKU to inherit one from)', NULL),
    IF(j.ALLERGEN_ROWS = 0, 'No allergen declaration', NULL),
    IF(j.NUTRITION_PANEL IS NULL, 'No nutrition panel', NULL),
    IF(j.NUTRIENT_BASIS = 'unknown',
       'Nutrition panel basis unknown (per 100 g vs per serving cannot be established)', NULL),
    IF(j.MANDATORY_NUTRIENTS_BLANK IS NOT NULL,
       CONCAT('FSSAI-mandatory nutrients blank: ', j.MANDATORY_NUTRIENTS_BLANK), NULL),
    IF(m.ALLERGEN_UNDERDECLARED != '',
       CONCAT('Allergen under-declared (recipe contains it, label says may-contain/absent): ', m.ALLERGEN_UNDERDECLARED), NULL),
    IF(j.CLAIM_BLOCKING_COUNT > 0,
       FORMAT('%d on-pack claim(s) contradicted by the lab panel', j.CLAIM_BLOCKING_COUNT), NULL)
  ]) g WHERE g IS NOT NULL), '; ') AS BLOCKING_GAPS,
  ARRAY_TO_STRING(ARRAY(SELECT g FROM UNNEST([
    IF(STARTS_WITH(j.INGREDIENT_SOURCE, 'inherited'),
       CONCAT('Ingredient list ', j.INGREDIENT_SOURCE, ' (same line + flavour, different pack size) — confirm before publishing'), NULL),
    -- FSSAI requires the ingredient list in descending order of weight. MAP_PRODUCT_
    -- INGREDIENT carries no quantity, so the order below is sheet order, not verified.
    IF(j.INGREDIENT_COUNT > 1, 'Ingredient order is sheet order — descending-by-weight not verifiable from PIM', NULL),
    IF(j.IMAGES_LINK IS NULL, 'No product image folder', NULL),
    IF(j.DESCRIPTION IS NULL, 'No product description', NULL),
    IF(j.LAB_REPORT_LINK IS NULL, 'No nutrition lab report on file', NULL),
    IF(j.LAB_REPORT_AGE_DAYS IS NULL, 'Lab report has no issue date', NULL),
    IF(j.LAB_REPORT_AGE_DAYS > 730, FORMAT('Lab report is %d days old', j.LAB_REPORT_AGE_DAYS), NULL),
    IF(j.NUTRIENT_BASIS = 'per_100g_inferred',
       'Nutrition basis inferred from the serving row, not printed on the panel', NULL),
    IF(j.NUTRIENT_BASIS LIKE 'per_100g%' AND j.PANEL_SERVING_GM IS NOT NULL AND j.PANEL_SERVING_GM != 100,
       FORMAT('Panel is per 100 g but declares a %s g serving — per-serving column not on file', CAST(j.PANEL_SERVING_GM AS STRING)), NULL),
    IF(j.STORAGE_GUIDELINES IS NULL, 'No storage instructions', NULL),
    IF(j.CONSUMPTION_INSTRUCTIONS IS NULL, 'No consumption / serving instructions', NULL),
    IF(j.GS1_BARCODE IS NULL, 'No GS1 barcode', NULL),
    IF(j.MANUFACTURER IS NULL, 'No manufacturer name / address parsed', NULL),
    IF(j.CLAIM_COUNT = 0, 'No marketing claims on record', NULL),
    IF(j.CLAIM_REVIEW_COUNT > 0,
       FORMAT('%d claim(s) unverifiable from PIM or outside tolerance', j.CLAIM_REVIEW_COUNT), NULL)
  ]) g WHERE g IS NOT NULL), '; ') AS WARNING_GAPS
FROM joined j
JOIN mis m USING (SKU);

-- Per-channel commercial terms with the channel NAMED (MAP_PRODUCT_CHANNEL stores only
-- CHANNEL_ID). Every SKU is mapped to all 15 channels with identical price/COGS/shelf
-- life today, so this is the channel's terms of record, not evidence of being listed --
-- the target channel is an input to the process, never inferred from these rows.
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.ctx_upside_master_data.V_LISTING_CHANNEL_PRICING` AS
SELECT
  m.SKU,
  m.CHANNEL_ID,
  c.CHANNEL_NAME,
  c.CHANNEL_TYPE,
  m.APPLICABLE,
  m.CHANNEL_MRP_INR,
  m.CHANNEL_GST_RATE,
  m.CHANNEL_BASE_PRICE_INR,
  m.CHANNEL_COGS_INR,
  m.CHANNEL_SHELF_LIFE_DAYS,
  m.PRIMARY_SALES_OWNER
FROM `gen-lang-client-0520145261.ctx_upside_master_data.MAP_PRODUCT_CHANNEL` m
JOIN `gen-lang-client-0520145261.ctx_upside_master_data.DIM_CHANNEL` c USING (CHANNEL_ID);
