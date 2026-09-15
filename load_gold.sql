CREATE SCHEMA IF NOT EXISTS gold;

-- DIMENSÃO DATE
CREATE TABLE IF NOT EXISTS gold.dim_date (
    date_key    INTEGER PRIMARY KEY,
    full_date   DATE,
    year        INTEGER,
    quarter     INTEGER,
    month       INTEGER,
    day         INTEGER,
    day_of_week INTEGER,
    year_month  VARCHAR(7)
);

-- DIMENSÃO MOVIE
CREATE TABLE IF NOT EXISTS gold.dim_movie (
    movie_key   SERIAL PRIMARY KEY,
    imdb_id     VARCHAR(20),
    rt_id       VARCHAR(200),
    lb_movie_id VARCHAR(200),
    title       VARCHAR(500),
    director    VARCHAR(500),
    mpaa_rating VARCHAR(20),
    runtime     INTEGER
);

-- DIMENSÃO GENRE
CREATE TABLE IF NOT EXISTS gold.dim_genre (
    genre_key  SERIAL PRIMARY KEY,
    genre_name VARCHAR(100) UNIQUE
);

-- PONTE MOVIE <-> GENERE
CREATE TABLE IF NOT EXISTS gold.bridge_movie_genre (
    movie_key INTEGER REFERENCES gold.dim_movie(movie_key),
    genre_key INTEGER REFERENCES gold.dim_genre(genre_key),
    PRIMARY KEY (movie_key, genre_key)
);

-- FATO MOVIE_METRICS
CREATE TABLE IF NOT EXISTS gold.fact_movie_metrics (
    movie_key           INTEGER PRIMARY KEY REFERENCES gold.dim_movie(movie_key),
    release_date_key    INTEGER REFERENCES gold.dim_date(date_key),
    budget_currency     VARCHAR(10),
    budget_usd          DECIMAL(15,2),
    gross_worldwide_usd DECIMAL(15,2),
    profit_usd          DECIMAL(15,2),
    roi                 DECIMAL(10,4),
    imdb_rating         DECIMAL(3,1),
    imdb_votes          BIGINT,
    imdb_meta_score     DECIMAL(4,1),
    rt_tomato_meter     DECIMAL(5,1),
    rt_audience_score   DECIMAL(5,1),
    rt_review_count     INTEGER,
    lb_vote_average     DECIMAL(4,1),
    lb_vote_count       BIGINT,
    avg_user_rating     DECIMAL(3,1),
    user_rating_count   INTEGER
);

TRUNCATE TABLE
    gold.fact_movie_metrics,
    gold.bridge_movie_genre,
    gold.dim_movie,
    gold.dim_genre,
    gold.dim_date
RESTART IDENTITY CASCADE;

-- INSERE DIMENSÃO DATE
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

-- INSERE DIMENSÃO MOVIE
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

-- INSERE DIMENSÃO GENRE
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

-- INSERE PONTE MOVIE_GENRE
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

-- INSERE FATO MOVIE_METRICS
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
    i.budget_currency,
    i.budget,
    i.gross_worldwide,
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

    i.rating,
    i.votes,
    i.meta_score,
    r.tomato_meter,
    r.audience_score,
    rev.review_count,
    l.vote_average,
    l.vote_count,
    ur.avg_rating,
    ur.rating_count

FROM gold.dim_movie m

LEFT JOIN silver.imdb_movies i
       ON i.id = m.imdb_id

LEFT JOIN silver.rt_movies r
       ON r.id = m.rt_id

LEFT JOIN (
    SELECT
        id,
        COUNT(*) AS review_count
    FROM silver.rt_reviews
    WHERE score_numeric IS NOT NULL
    GROUP BY id
) rev ON rev.id = r.id

LEFT JOIN silver.lb_movie_data l
       ON l.movie_id = m.lb_movie_id

LEFT JOIN (
    SELECT
        movie_id,
        ROUND(AVG(rating_val), 1) AS avg_rating,
        COUNT(*)                  AS rating_count
    FROM silver.ratings
    GROUP BY movie_id
) ur ON ur.movie_id = m.lb_movie_id

LEFT JOIN gold.dim_date d
       ON d.full_date = i.release_date;

-- ÍNDICES
CREATE INDEX IF NOT EXISTS idx_fact_date       ON gold.fact_movie_metrics(release_date_key);
CREATE INDEX IF NOT EXISTS idx_fact_currency   ON gold.fact_movie_metrics(budget_currency);
CREATE INDEX IF NOT EXISTS idx_dim_movie_title ON gold.dim_movie(title);
CREATE INDEX IF NOT EXISTS idx_dim_movie_imdb  ON gold.dim_movie(imdb_id);
CREATE INDEX IF NOT EXISTS idx_dim_movie_rt    ON gold.dim_movie(rt_id);
CREATE INDEX IF NOT EXISTS idx_dim_movie_lb    ON gold.dim_movie(lb_movie_id);
CREATE INDEX IF NOT EXISTS idx_dim_date_year   ON gold.dim_date(year);
CREATE INDEX IF NOT EXISTS idx_dim_genre_name  ON gold.dim_genre(genre_name);
CREATE INDEX IF NOT EXISTS idx_bridge_genre    ON gold.bridge_movie_genre(genre_key);
CREATE INDEX IF NOT EXISTS idx_bridge_movie    ON gold.bridge_movie_genre(movie_key);