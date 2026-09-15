-- ============================================================================
-- CAMADA GOLD - STAR SCHEMA
-- Schema: gold
-- Dependência: schema silver já populado
-- Granularidade da Fato: 1 linha por filme
--
-- BUGS CORRIGIDOS em relação ao script original:
--   1. budget_currency removido do JOIN — só afeta cálculo de profit/ROI
--   2. rt_review_count: subquery corrigida para agrupar por rt_reviews.id
--   3. ratings JOIN: removido m.imdb_id = ur.movie_id (nunca casa, IDs diferentes)
--   4. COALESCE(x, 0) substituído por NULL — ausência de dado ≠ zero
--   5. TRUNCATE com CASCADE para respeitar FK constraints
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS gold;

-- ============================================================================
-- 1. DIMENSÕES
-- ============================================================================

-- dim_date: dimensão de tempo completa, 1 linha por dia
-- gerada via generate_series entre o menor e maior release_date do Silver
CREATE TABLE IF NOT EXISTS gold.dim_date (
    date_key    INTEGER PRIMARY KEY,  -- formato YYYYMMDD
    full_date   DATE,
    year        INTEGER,
    quarter     INTEGER,
    month       INTEGER,
    day         INTEGER,
    day_of_week INTEGER,
    year_month  VARCHAR(7)            -- YYYY-MM
);

-- dim_movie: dimensão central unificando IMDB + RT + LB
-- âncora no IMDB, enriquecida com rt_id e lb_movie_id para joins na fato
CREATE TABLE IF NOT EXISTS gold.dim_movie (
    movie_key   SERIAL PRIMARY KEY,
    imdb_id     VARCHAR(20),
    rt_id       VARCHAR(200),
    lb_movie_id VARCHAR(200),
    title       VARCHAR(500),
    director    VARCHAR(500),   -- fonte: silver.rt_movies
    mpaa_rating VARCHAR(20),    -- fonte: silver.rt_movies.rating
    runtime     INTEGER         -- fonte: silver.lb_movie_data.runtime
);

-- dim_genre: gênero único como linha independente
CREATE TABLE IF NOT EXISTS gold.dim_genre (
    genre_key  SERIAL PRIMARY KEY,
    genre_name VARCHAR(100) UNIQUE
);

-- bridge_movie_genre: resolve o many-to-many filme ↔ gênero
-- necessária porque genres é TEXT[] nas 3 fontes Silver
CREATE TABLE IF NOT EXISTS gold.bridge_movie_genre (
    movie_key INTEGER REFERENCES gold.dim_movie(movie_key),
    genre_key INTEGER REFERENCES gold.dim_genre(genre_key),
    PRIMARY KEY (movie_key, genre_key)
);

-- ============================================================================
-- 2. TABELA FATO
-- ============================================================================

-- fact_movie_metrics: 1 linha por filme com todas as métricas dos KPIs
-- movie_key é PK e FK ao mesmo tempo (relação 1:1 com dim_movie)
CREATE TABLE IF NOT EXISTS gold.fact_movie_metrics (
    movie_key           INTEGER PRIMARY KEY REFERENCES gold.dim_movie(movie_key),
    release_date_key    INTEGER REFERENCES gold.dim_date(date_key),

    -- Métricas financeiras IMDB
    -- budget_currency preservada para transparência
    -- profit_usd e roi são NULL quando budget_currency != 'USD'
    budget_currency     VARCHAR(10),
    budget_usd          DECIMAL(15,2),
    gross_worldwide_usd DECIMAL(15,2),
    profit_usd          DECIMAL(15,2),   -- NULL quando não-USD
    roi                 DECIMAL(10,4),   -- gross/budget, NULL quando não-USD

    -- Métricas IMDB (presentes para TODOS os filmes, independente de moeda)
    imdb_rating         DECIMAL(3,1),
    imdb_votes          BIGINT,
    imdb_meta_score     DECIMAL(4,1),

    -- Métricas Rotten Tomatoes
    rt_tomato_meter     DECIMAL(5,1),
    rt_audience_score   DECIMAL(5,1),
    rt_review_count     INTEGER,         -- total de reviews com score numérico

    -- Métricas Letterboxd
    lb_vote_average     DECIMAL(4,1),
    lb_vote_count       BIGINT,

    -- Métricas de usuários Letterboxd (silver.ratings)
    avg_user_rating     DECIMAL(3,1),
    user_rating_count   INTEGER
);

-- ============================================================================
-- 3. POPULAÇÃO DAS DIMENSÕES
-- ============================================================================

-- CORRIGIDO: CASCADE garante que FKs não bloqueiem o TRUNCATE
TRUNCATE TABLE
    gold.fact_movie_metrics,
    gold.bridge_movie_genre,
    gold.dim_movie,
    gold.dim_genre,
    gold.dim_date
RESTART IDENTITY CASCADE;

-- --------------------------------------------------------------------------
-- 3.1. dim_date
-- generate_series cria 1 linha por dia entre o menor e maior release_date
-- Filmes sem data recebem fallback para não quebrar o generate_series
-- --------------------------------------------------------------------------
WITH min_max_dates AS (
    SELECT
        MIN(COALESCE(release_date, '1970-01-01')) AS min_date,
        MAX(COALESCE(release_date, CURRENT_DATE)) AS max_date
    FROM silver.imdb_movies
)
INSERT INTO gold.dim_date (
    date_key, full_date, year, quarter,
    month, day, day_of_week, year_month
)
SELECT
    TO_CHAR(d, 'YYYYMMDD')::INTEGER,
    d,
    EXTRACT(YEAR    FROM d)::INTEGER,
    EXTRACT(QUARTER FROM d)::INTEGER,
    EXTRACT(MONTH   FROM d)::INTEGER,
    EXTRACT(DAY     FROM d)::INTEGER,
    EXTRACT(DOW     FROM d)::INTEGER,
    TO_CHAR(d, 'YYYY-MM')
FROM min_max_dates,
     generate_series(min_date, max_date, '1 day'::INTERVAL) AS d;

-- --------------------------------------------------------------------------
-- 3.2. dim_movie
-- Âncora no IMDB. RT linkado por título normalizado (38.7% cobertura).
-- LB linkado por imdb_id (cobertura após correção dos vazios).
-- MIN() nos campos RT e LB para evitar duplicatas quando há múltiplos matches.
-- --------------------------------------------------------------------------
INSERT INTO gold.dim_movie (
    imdb_id, rt_id, lb_movie_id,
    title, director, mpaa_rating, runtime
)
SELECT
    i.id                                           AS imdb_id,
    MIN(r.id)                                      AS rt_id,
    MIN(l.movie_id)                                AS lb_movie_id,
    COALESCE(i.title, MIN(r.title), MIN(l.movie_title)) AS title,
    MIN(r.director)                                AS director,
    -- 'N/A' já vem tratado do Silver; NULL quando nenhum match RT
    COALESCE(MIN(NULLIF(r.rating, 'N/A')), 'N/A') AS mpaa_rating,
    MIN(l.runtime)                                 AS runtime
FROM silver.imdb_movies i
LEFT JOIN silver.rt_movies r
       ON LOWER(TRIM(i.title)) = LOWER(TRIM(r.title))
LEFT JOIN silver.lb_movie_data l
       ON i.id = NULLIF(TRIM(l.imdb_id), 'N/A')
GROUP BY i.id, i.title;

-- --------------------------------------------------------------------------
-- 3.3. dim_genre
-- Coleta gêneros únicos das 3 fontes (TEXT[] via UNNEST)
-- --------------------------------------------------------------------------
INSERT INTO gold.dim_genre (genre_name)
SELECT DISTINCT TRIM(g) AS genre_name
FROM (
    SELECT UNNEST(genres) AS g FROM silver.imdb_movies   WHERE genres IS NOT NULL
    UNION
    SELECT UNNEST(genre)  AS g FROM silver.rt_movies     WHERE genre  IS NOT NULL
    UNION
    SELECT UNNEST(genres) AS g FROM silver.lb_movie_data WHERE genres IS NOT NULL
) all_genres
WHERE TRIM(g) != ''
  AND LOWER(TRIM(g)) != 'null'
ON CONFLICT (genre_name) DO NOTHING;

-- --------------------------------------------------------------------------
-- 3.4. bridge_movie_genre
-- Explode TEXT[] de cada fonte e liga ao dim_genre
-- UNION elimina duplicatas quando o mesmo gênero vem de fontes diferentes
-- --------------------------------------------------------------------------
INSERT INTO gold.bridge_movie_genre (movie_key, genre_key)
SELECT DISTINCT m.movie_key, g.genre_key
FROM gold.dim_movie m
JOIN silver.imdb_movies i   ON i.id = m.imdb_id
JOIN UNNEST(i.genres) AS gn ON TRUE
JOIN gold.dim_genre g       ON LOWER(TRIM(g.genre_name)) = LOWER(TRIM(gn))
WHERE i.genres IS NOT NULL

UNION

SELECT DISTINCT m.movie_key, g.genre_key
FROM gold.dim_movie m
JOIN silver.rt_movies r     ON r.id = m.rt_id
JOIN UNNEST(r.genre) AS gn  ON TRUE
JOIN gold.dim_genre g       ON LOWER(TRIM(g.genre_name)) = LOWER(TRIM(gn))
WHERE r.genre IS NOT NULL

UNION

SELECT DISTINCT m.movie_key, g.genre_key
FROM gold.dim_movie m
JOIN silver.lb_movie_data l ON l.movie_id = m.lb_movie_id
JOIN UNNEST(l.genres) AS gn ON TRUE
JOIN gold.dim_genre g       ON LOWER(TRIM(g.genre_name)) = LOWER(TRIM(gn))
WHERE l.genres IS NOT NULL

ON CONFLICT (movie_key, genre_key) DO NOTHING;

-- ============================================================================
-- 4. POPULAÇÃO DA TABELA FATO
-- ============================================================================

INSERT INTO gold.fact_movie_metrics (
    movie_key, release_date_key,
    budget_currency, budget_usd, gross_worldwide_usd, profit_usd, roi,
    imdb_rating, imdb_votes, imdb_meta_score,
    rt_tomato_meter, rt_audience_score, rt_review_count,
    lb_vote_average, lb_vote_count,
    avg_user_rating, user_rating_count
)
SELECT
    m.movie_key,
    d.date_key,

    -- CORRIGIDO: budget_currency separado dos dados de avaliação
    -- Todos os filmes têm rating/votes/meta_score, independente da moeda
    i.budget_currency,
    i.budget,
    i.gross_worldwide,

    -- profit e roi: NULL quando moeda não é USD (não comparável)
    CASE
        WHEN i.budget_currency = 'USD'
         AND i.budget > 0
         AND i.gross_worldwide IS NOT NULL
        THEN ROUND(i.gross_worldwide - i.budget, 2)
        ELSE NULL
    END AS profit_usd,

    CASE
        WHEN i.budget_currency = 'USD'
         AND i.budget > 0
         AND i.gross_worldwide IS NOT NULL
        THEN ROUND(i.gross_worldwide / i.budget, 4)
        ELSE NULL
    END AS roi,

    -- CORRIGIDO: IMDB rating disponível para TODOS os filmes
    -- (JOIN sem filtro de moeda)
    i.rating,
    i.votes,
    i.meta_score,

    -- RT
    r.tomato_meter,
    r.audience_score,

    -- CORRIGIDO: rt_reviews.id = slug do filme (mesmo que rt_movies.id)
    -- JOIN corrigido: agrupa por id diretamente em rt_reviews
    rev.review_count,

    -- LB
    l.vote_average,
    l.vote_count,

    -- Usuários LB (silver.ratings)
    -- CORRIGIDO: join apenas por lb_movie_id (movie_id é slug LB, não IMDB ID)
    -- CORRIGIDO: NULL ao invés de 0 quando não há ratings
    ur.avg_rating,
    ur.rating_count

FROM gold.dim_movie m

-- JOIN principal IMDB: SEM filtro de moeda aqui
-- rating, votes e meta_score devem existir para todos os filmes
LEFT JOIN silver.imdb_movies i
       ON i.id = m.imdb_id

-- JOIN RT
LEFT JOIN silver.rt_movies r
       ON r.id = m.rt_id

-- CORRIGIDO: contagem de reviews por filme via rt_reviews.id (slug do filme)
LEFT JOIN (
    SELECT
        id,
        COUNT(*) AS review_count
    FROM silver.rt_reviews
    WHERE score_numeric IS NOT NULL
    GROUP BY id
) rev ON rev.id = r.id

-- JOIN LB
LEFT JOIN silver.lb_movie_data l
       ON l.movie_id = m.lb_movie_id

-- CORRIGIDO: silver.ratings.movie_id é slug LB ("feast-2014")
-- NUNCA é IMDB ID ("tt0086314") — m.imdb_id = ur.movie_id sempre seria NULL
LEFT JOIN (
    SELECT
        movie_id,
        ROUND(AVG(rating_val), 1) AS avg_rating,
        COUNT(*)                  AS rating_count
    FROM silver.ratings
    GROUP BY movie_id
) ur ON ur.movie_id = m.lb_movie_id

-- Join com dim_date via release_date do IMDB
LEFT JOIN gold.dim_date d
       ON d.full_date = i.release_date;

-- ============================================================================
-- 5. ÍNDICES
-- ============================================================================

-- Fato
CREATE INDEX IF NOT EXISTS idx_fact_date       ON gold.fact_movie_metrics(release_date_key);
CREATE INDEX IF NOT EXISTS idx_fact_currency   ON gold.fact_movie_metrics(budget_currency);

-- Dimensões
CREATE INDEX IF NOT EXISTS idx_dim_movie_title ON gold.dim_movie(title);
CREATE INDEX IF NOT EXISTS idx_dim_movie_imdb  ON gold.dim_movie(imdb_id);
CREATE INDEX IF NOT EXISTS idx_dim_movie_rt    ON gold.dim_movie(rt_id);
CREATE INDEX IF NOT EXISTS idx_dim_movie_lb    ON gold.dim_movie(lb_movie_id);
CREATE INDEX IF NOT EXISTS idx_dim_date_year   ON gold.dim_date(year);
CREATE INDEX IF NOT EXISTS idx_dim_genre_name  ON gold.dim_genre(genre_name);

-- Ponte
CREATE INDEX IF NOT EXISTS idx_bridge_genre    ON gold.bridge_movie_genre(genre_key);
CREATE INDEX IF NOT EXISTS idx_bridge_movie    ON gold.bridge_movie_genre(movie_key);

-- ============================================================================
-- 6. VALIDAÇÃO
-- ============================================================================

-- 6.1 Contagem por tabela
SELECT 'gold.dim_date'            AS tabela, COUNT(*) AS total FROM gold.dim_date
UNION ALL
SELECT 'gold.dim_movie',          COUNT(*) FROM gold.dim_movie
UNION ALL
SELECT 'gold.dim_genre',          COUNT(*) FROM gold.dim_genre
UNION ALL
SELECT 'gold.bridge_movie_genre', COUNT(*) FROM gold.bridge_movie_genre
UNION ALL
SELECT 'gold.fact_movie_metrics', COUNT(*) FROM gold.fact_movie_metrics;

-- 6.2 Cobertura das plataformas na fato
SELECT
    COUNT(*)                                               AS total_filmes,
    COUNT(imdb_rating)                                     AS com_nota_imdb,
    COUNT(rt_tomato_meter)                                 AS com_nota_rt,
    COUNT(lb_vote_average)                                 AS com_nota_lb,
    COUNT(profit_usd)                                      AS com_lucro_usd,
    COUNT(avg_user_rating)                                 AS com_rating_usuario,
    ROUND(COUNT(rt_tomato_meter)  * 100.0 / COUNT(*), 1)  AS pct_cobertura_rt,
    ROUND(COUNT(lb_vote_average)  * 100.0 / COUNT(*), 1)  AS pct_cobertura_lb,
    ROUND(COUNT(profit_usd)       * 100.0 / COUNT(*), 1)  AS pct_cobertura_financeiro
FROM gold.fact_movie_metrics;

-- 6.3 KPI: filmes mais lucrativos (USD confirmado)
SELECT
    m.title,
    d.year,
    f.gross_worldwide_usd,
    f.budget_usd,
    f.profit_usd,
    f.roi
FROM gold.fact_movie_metrics f
JOIN gold.dim_movie m ON m.movie_key       = f.movie_key
JOIN gold.dim_date  d ON d.date_key        = f.release_date_key
WHERE f.profit_usd IS NOT NULL
ORDER BY f.profit_usd DESC
LIMIT 10;

-- 6.4 KPI: gênero mais lucrativo (USD apenas)
SELECT
    g.genre_name,
    COUNT(DISTINCT f.movie_key)         AS total_filmes,
    ROUND(SUM(f.gross_worldwide_usd), 0) AS receita_total,
    ROUND(AVG(f.roi), 2)                AS roi_medio
FROM gold.fact_movie_metrics f
JOIN gold.bridge_movie_genre b ON b.movie_key = f.movie_key
JOIN gold.dim_genre          g ON g.genre_key = b.genre_key
WHERE f.budget_currency = 'USD'
  AND f.gross_worldwide_usd IS NOT NULL
GROUP BY g.genre_name
ORDER BY receita_total DESC
LIMIT 10;

-- 6.5 KPI: evolução das notas por ano (IMDB vs RT)
SELECT
    d.year,
    ROUND(AVG(f.imdb_rating), 2)      AS media_imdb,
    ROUND(AVG(f.imdb_meta_score), 1)  AS media_meta_score,
    ROUND(AVG(f.rt_tomato_meter), 1)  AS media_rt_critico,
    ROUND(AVG(f.rt_audience_score), 1) AS media_rt_publico,
    COUNT(*)                          AS total_filmes
FROM gold.fact_movie_metrics f
JOIN gold.dim_date d ON d.date_key = f.release_date_key
WHERE d.year BETWEEN 1990 AND 2025
GROUP BY d.year
ORDER BY d.year;

-- 6.6 KPI: melhores filmes cross-platform (IMDB + RT + LB)
SELECT
    m.title,
    d.year,
    f.imdb_rating,
    f.rt_tomato_meter,
    f.rt_audience_score,
    f.lb_vote_average,
    -- score consolidado: média normalizada das fontes disponíveis
    ROUND(
        (
            COALESCE(f.imdb_rating, 0)          * CASE WHEN f.imdb_rating      IS NOT NULL THEN 1 ELSE 0 END +
            COALESCE(f.rt_tomato_meter  / 10, 0) * CASE WHEN f.rt_tomato_meter  IS NOT NULL THEN 1 ELSE 0 END +
            COALESCE(f.lb_vote_average, 0)       * CASE WHEN f.lb_vote_average  IS NOT NULL THEN 1 ELSE 0 END
        ) / NULLIF(
            CASE WHEN f.imdb_rating     IS NOT NULL THEN 1 ELSE 0 END +
            CASE WHEN f.rt_tomato_meter IS NOT NULL THEN 1 ELSE 0 END +
            CASE WHEN f.lb_vote_average IS NOT NULL THEN 1 ELSE 0 END,
            0
        ),
    2) AS score_consolidado
FROM gold.fact_movie_metrics f
JOIN gold.dim_movie m ON m.movie_key  = f.movie_key
JOIN gold.dim_date  d ON d.date_key   = f.release_date_key
WHERE f.imdb_rating IS NOT NULL
ORDER BY score_consolidado DESC NULLS LAST
LIMIT 20;

