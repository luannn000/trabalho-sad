-- bronze.imdb_movies definição
CREATE TABLE bronze.imdb_movies (
	id text NULL,
	title text NULL,
	duration text NULL,
	mpa text NULL,
	rating float4 NULL,
	votes text NULL,
	méta_score int4 NULL,
	description text NULL,
	movie_link text NULL,
	writers text NULL,
	directors text NULL,
	stars text NULL,
	budget text NULL,
	opening_weekend_gross text NULL,
	gross_worldwide text NULL,
	gross_us_canada text NULL,
	release_date text NULL,
	countries_origin text NULL,
	filming_locations text NULL,
	production_companies text NULL,
	awards_content text NULL,
	genres text NULL,
	languages text NULL
);

-- bronze.lb_movie_data definição
CREATE TABLE bronze.lb_movie_data (
	_id text NULL,
	genres _text NULL,
	image_url text NULL,
	imdb_id text NULL,
	imdb_link text NULL,
	movie_id text NULL,
	movie_title text NULL,
	original_language text NULL,
	overview text NULL,
	popularity float8 NULL,
	production_countries _text NULL,
	release_date date NULL,
	runtime int4 NULL,
	spoken_languages _text NULL,
	tmdb_id int4 NULL,
	tmdb_link text NULL,
	vote_average float8 NULL,
	vote_count int4 NULL,
	year_released int4 NULL
);

-- bronze.lb_ratings_export definição
CREATE TABLE bronze.lb_ratings_export (
	_id text NULL,
	movie_id text NULL,
	rating_val text NULL,
	user_id text NULL
);

-- bronze.lb_users_export definição
CREATE TABLE bronze.lb_users_export (
	_id text NULL,
	display_name text NULL,
	num_ratings_pages text NULL,
	num_reviews text NULL,
	username text NULL
);

-- bronze.rt_movie_reviews definição
CREATE TABLE bronze.rt_movie_reviews (
	id text NULL,
	"reviewId" int4 NULL,
	"creationDate" text NULL,
	"criticName" text NULL,
	"isTopCritic" bool NULL,
	"originalScore" text NULL,
	"reviewState" text NULL,
	"publicatioName" text NULL,
	"reviewText" text NULL,
	"scoreSentiment" text NULL,
	"reviewUrl" text NULL
);

-- bronze.rt_movies definição
CREATE TABLE bronze.rt_movies (
	id text NULL,
	title text NULL,
	"audienceScore" text NULL,
	"tomatoMeter" text NULL,
	rating text NULL,
	"ratingContents" text NULL,
	"releaseDateTheaters" text NULL,
	"releaseDateStreaming" text NULL,
	"runtimeMinutes" text NULL,
	genre text NULL,
	"originalLanguage" text NULL,
	director text NULL,
	writer text NULL,
	"boxOffice" text NULL,
	distributor text NULL,
	"soundMix" text NULL
);