CREATE SCHEMA IF NOT EXISTS silver;

-- RATINGS
CREATE TABLE IF NOT EXISTS silver.ratings (
    id         VARCHAR(50),
    movie_id   VARCHAR(200),
    rating_val DECIMAL(3,1),
    user_id    VARCHAR(50),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- USERS
CREATE TABLE IF NOT EXISTS silver.users (
    id                VARCHAR(50),
    username          VARCHAR(100),
    display_name      VARCHAR(200),
    num_ratings_pages INTEGER,
    num_reviews       INTEGER,
    created_at        TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- IMDB_MOVIES
CREATE TABLE IF NOT EXISTS silver.imdb_movies (
    id              VARCHAR(20),
    title           VARCHAR(500),
    rating          DECIMAL(3,1),
    votes           BIGINT,
    meta_score      DECIMAL(4,1),
    genres          TEXT,
    release_date    DATE,
    ano_lancamento  INTEGER,
    mes_lancamento  INTEGER,
    dia_lancamento  INTEGER,
    budget          DECIMAL(15,2),
    gross_worldwide DECIMAL(15,2),
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- RT_REVIEWS
CREATE TABLE IF NOT EXISTS silver.rt_reviews (
    id              VARCHAR(100),
    critic_name     VARCHAR(200),
    is_top_critic   BOOLEAN,
    original_score  VARCHAR(50),
    score_numeric   DECIMAL(5,2),
    score_sentiment VARCHAR(20),
    review_text     TEXT,
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

--RT_MOVIES
CREATE TABLE IF NOT EXISTS silver.rt_movies (
    id             VARCHAR(200),
    title          VARCHAR(500),
    audience_score DECIMAL(5,1),
    tomato_meter   DECIMAL(5,1),
    rating         VARCHAR(20),
    genre          TEXT,
    director       VARCHAR(500),
    box_office     DECIMAL(15,2),
    created_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

--LB_MOVIE_DATA
CREATE TABLE IF NOT EXISTS silver.lb_movie_data (
    id           VARCHAR(50),
    imdb_id      VARCHAR(20),
    movie_id     VARCHAR(200),
    movie_title  VARCHAR(500),
    genres       TEXT,
    vote_average DECIMAL(4,1),
    vote_count   BIGINT,
    release_date DATE,
    popularity   DECIMAL(10,2),
    runtime      INTEGER,
    created_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- APAGA TODOS OS DADOS
TRUNCATE TABLE
    silver.ratings,
    silver.users,
    silver.imdb_movies,
    silver.rt_reviews,
    silver.rt_movies,
    silver.lb_movie_data;

-- INSERE RATINGS
INSERT INTO silver.ratings (id, movie_id, rating_val, user_id)
SELECT
    _id,
    movie_id,
    CASE
        WHEN rating_val ~ '^[0-9]+(\.[0-9]+)?$' THEN rating_val::DECIMAL(3,1)
        ELSE NULL
    END,
    user_id
FROM bronze.lb_ratings_export
WHERE rating_val ~ '^[0-9]+(\.[0-9]+)?$'
  AND rating_val::DECIMAL(3,1) BETWEEN 1 AND 10;

-- INSERE USERS
INSERT INTO silver.users (id, username, display_name, num_ratings_pages, num_reviews)
SELECT DISTINCT ON (username)
    _id,
    username,
    display_name,
    CASE
        WHEN num_ratings_pages ~ '^[0-9]+$' THEN num_ratings_pages::INTEGER
        ELSE NULL
    END,
    CASE
        WHEN num_reviews ~ '^[0-9]+$' THEN num_reviews::INTEGER
        ELSE NULL
    END
FROM bronze.lb_users_export;

-- INSERE IMDB_MOVIES
INSERT INTO silver.imdb_movies (
    id, title, rating, votes, meta_score, genres,
    release_date, ano_lancamento, mes_lancamento, dia_lancamento,
    budget, gross_worldwide
)
SELECT
    id,
    title,

    rating::DECIMAL(3,1),

    CASE
        WHEN votes LIKE '%M' THEN (REPLACE(votes, 'M', '')::DECIMAL(10,2) * 1000000)::BIGINT
        WHEN votes LIKE '%K' THEN (REPLACE(votes, 'K', '')::DECIMAL(10,2) * 1000)::BIGINT
        WHEN votes ~ '^[0-9]+$'  THEN votes::BIGINT
        ELSE NULL
    END,

    "méta_score"::DECIMAL(4,1),

    genres,

    CASE WHEN release_date ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
         THEN release_date::DATE ELSE NULL END,
    CASE WHEN release_date ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
         THEN EXTRACT(YEAR  FROM release_date::DATE)::INTEGER ELSE NULL END,
    CASE WHEN release_date ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
         THEN EXTRACT(MONTH FROM release_date::DATE)::INTEGER ELSE NULL END,
    CASE WHEN release_date ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
         THEN EXTRACT(DAY   FROM release_date::DATE)::INTEGER ELSE NULL END,

    CASE
        WHEN budget IS NULL OR TRIM(budget) = '' THEN NULL
        ELSE NULLIF(
            TRIM(REGEXP_REPLACE(budget, '[^0-9.]', '', 'g')),
            ''
        )::DECIMAL(15,2)
    END,

    CASE
        WHEN gross_worldwide IS NULL OR TRIM(gross_worldwide) = '' THEN NULL
        ELSE NULLIF(
            TRIM(REGEXP_REPLACE(gross_worldwide, '[^0-9.]', '', 'g')),
            ''
        )::DECIMAL(15,2)
    END

FROM bronze.imdb_movies;

-- INSERE RT_REVIEWS
INSERT INTO silver.rt_reviews (
    id, critic_name, is_top_critic, original_score,
    score_numeric, score_sentiment, review_text
)
SELECT
    id,
    "criticName",
    CASE
        WHEN LOWER("isTopCritic"::TEXT) = 'true' THEN TRUE
        ELSE FALSE
    END,
    "originalScore",

    CASE
        WHEN cleaned_score LIKE '%/%' THEN
            ROUND(
                (SPLIT_PART(cleaned_score, '/', 1)::DECIMAL(6,3) /
                 NULLIF(SPLIT_PART(cleaned_score, '/', 2)::DECIMAL(6,3), 0)
                ) * 10,
            2)
        WHEN cleaned_score ~ '^[0-9]+(\.[0-9]+)?$' THEN
            cleaned_score::DECIMAL(5,2)
        ELSE NULL
    END,

    UPPER("scoreSentiment"),
    "reviewText"

FROM (
    SELECT
        *,
        NULLIF(
            TRIM(REGEXP_REPLACE("originalScore", '[^0-9./]', '', 'g')),
            ''
        ) AS cleaned_score
    FROM bronze.rt_movie_reviews
) sub;

-- INSERE RT_MOVIES
INSERT INTO silver.rt_movies (
    id, title, audience_score, tomato_meter,
    rating, genre, director, box_office
)
SELECT
    id,
    title,

    CASE WHEN "audienceScore"::TEXT ~ '^[0-9]+(\.[0-9]+)?$'
         THEN "audienceScore"::DECIMAL(5,1) ELSE NULL END,

    CASE WHEN "tomatoMeter"::TEXT ~ '^[0-9]+(\.[0-9]+)?$'
         THEN "tomatoMeter"::DECIMAL(5,1)  ELSE NULL END,

    rating,
    genre,
    director,

    CASE
        WHEN cleaned_box_office IS NULL
          OR cleaned_box_office = '' THEN NULL

        WHEN cleaned_box_office LIKE '%M' THEN
            NULLIF(
                TRIM(REGEXP_REPLACE(REPLACE(cleaned_box_office, 'M', ''), '[^0-9.]', '', 'g')),
                ''
            )::DECIMAL(15,2) * 1000000

        WHEN cleaned_box_office LIKE '%K' THEN
            NULLIF(
                TRIM(REGEXP_REPLACE(REPLACE(cleaned_box_office, 'K', ''), '[^0-9.]', '', 'g')),
                ''
            )::DECIMAL(15,2) * 1000

        ELSE
            NULLIF(
                TRIM(REGEXP_REPLACE(cleaned_box_office, '[^0-9.]', '', 'g')),
                ''
            )::DECIMAL(15,2)
    END

FROM (
    SELECT
        *,
        NULLIF(
            TRIM(REPLACE(REPLACE("boxOffice"::TEXT, '"', ''), ' ', '')),
            ''
        ) AS cleaned_box_office
    FROM bronze.rt_movies
) sub;

-- INSERE LB_MOVIES_DATA
INSERT INTO silver.lb_movie_data (
    id, imdb_id, movie_id, movie_title, genres,
    vote_average, vote_count, release_date, popularity, runtime
)
SELECT
    _id,
    imdb_id,
    movie_id,
    movie_title,
    genres,
    vote_average::DECIMAL(4,1),
    vote_count::BIGINT,
    release_date::DATE,
    popularity::DECIMAL(10,2),
    runtime::INTEGER

FROM bronze.lb_movie_data;

-- CRIAÇÃO DE ÍNDICES
CREATE INDEX IF NOT EXISTS idx_silver_ratings_movie     ON silver.ratings(movie_id);
CREATE INDEX IF NOT EXISTS idx_silver_ratings_user      ON silver.ratings(user_id);
CREATE INDEX IF NOT EXISTS idx_silver_imdb_id           ON silver.imdb_movies(id);
CREATE INDEX IF NOT EXISTS idx_silver_imdb_release      ON silver.imdb_movies(ano_lancamento);
CREATE INDEX IF NOT EXISTS idx_silver_rt_reviews_critic ON silver.rt_reviews(critic_name);
CREATE INDEX IF NOT EXISTS idx_silver_rt_movies_title   ON silver.rt_movies(title);
CREATE INDEX IF NOT EXISTS idx_silver_lb_imdb           ON silver.lb_movie_data(imdb_id);
CREATE INDEX IF NOT EXISTS idx_silver_lb_movie_id       ON silver.lb_movie_data(movie_id);

-- VALIDAÇÃO
SELECT 'silver.ratings'       AS tabela, COUNT(*) AS total FROM silver.ratings
UNION ALL
SELECT 'silver.users',        COUNT(*) FROM silver.users
UNION ALL
SELECT 'silver.imdb_movies',  COUNT(*) FROM silver.imdb_movies
UNION ALL
SELECT 'silver.rt_reviews',   COUNT(*) FROM silver.rt_reviews
UNION ALL
SELECT 'silver.rt_movies',    COUNT(*) FROM silver.rt_movies
UNION ALL
SELECT 'silver.lb_movie_data',COUNT(*) FROM silver.lb_movie_data;
