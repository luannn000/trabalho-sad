import streamlit as st
import pandas as pd
import plotly.express as px

st.set_page_config(
    page_title="Dashboard de Filmes - Gold Layer",
    layout="wide",
    initial_sidebar_state="expanded"
)

@st.cache_resource
def init_connection():
    return st.connection("postgres", type="sql")

conn = init_connection()

@st.cache_data(ttl=3600)
def run_query(query):
    return conn.query(query)

QUERIES = {
    "evolucao_notas": """
        SELECT d.year,
               ROUND(AVG(f.imdb_rating)::numeric, 2) AS avg_imdb_rating,
               ROUND(AVG(f.rt_tomato_meter / 10.0)::numeric, 2) AS avg_rt_tomato_meter,
               COUNT(f.movie_sk) AS total_movies
        FROM gold.fact_movie_metrics f
        JOIN gold.dim_date d ON f.release_date_sk = d.date_sk
        WHERE f.imdb_rating IS NOT NULL OR f.rt_tomato_meter IS NOT NULL
        GROUP BY d.year
        ORDER BY d.year
    """,
    "melhores_filmes": """
        SELECT m.title, m.director, d.year,
               f.imdb_rating, f.rt_tomato_meter, f.lb_vote_average,
               (
                   CASE WHEN f.imdb_rating IS NOT NULL THEN 1 ELSE 0 END +
                   CASE WHEN f.rt_tomato_meter IS NOT NULL THEN 1 ELSE 0 END +
                   CASE WHEN f.lb_vote_average IS NOT NULL THEN 1 ELSE 0 END
               ) AS sources_count,
               ROUND(
                   (COALESCE(f.imdb_rating, 0) + COALESCE((f.rt_tomato_meter / 10.0), 0) + COALESCE(f.lb_vote_average, 0)) 
                   / NULLIF((CASE WHEN f.imdb_rating IS NOT NULL THEN 1 ELSE 0 END + CASE WHEN f.rt_tomato_meter IS NOT NULL THEN 1 ELSE 0 END + CASE WHEN f.lb_vote_average IS NOT NULL THEN 1 ELSE 0 END), 0)::numeric, 2
               ) AS composite_score
        FROM gold.fact_movie_metrics f
        JOIN gold.dim_movie m ON f.movie_sk = m.movie_sk
        JOIN gold.dim_date d ON f.release_date_sk = d.date_sk
        WHERE f.imdb_rating IS NOT NULL OR f.rt_tomato_meter IS NOT NULL OR f.lb_vote_average IS NOT NULL
        ORDER BY composite_score DESC
        LIMIT 20
    """,
    "lucro_vs_orcamento": """
        SELECT d.year,
               ROUND(SUM(f.budget_usd)::numeric, 2) AS total_budget_usd,
               ROUND(SUM(f.gross_worldwide_usd)::numeric, 2) AS total_gross_usd,
               ROUND(SUM(f.profit_usd)::numeric, 2) AS total_profit_usd
        FROM gold.fact_movie_metrics f
        JOIN gold.dim_date d ON f.release_date_sk = d.date_sk
        WHERE f.budget_currency = 'USD' AND f.budget_usd > 0 AND f.gross_worldwide_usd IS NOT NULL
        GROUP BY d.year
        ORDER BY d.year
    """,
    "filmes_mais_lucrativos": """
        SELECT m.title, d.year,
               ROUND(f.budget_usd::numeric, 2) AS budget_usd,
               ROUND(f.gross_worldwide_usd::numeric, 2) AS gross_worldwide_usd,
               ROUND(f.profit_usd::numeric, 2) AS profit_usd,
               f.imdb_rating
        FROM gold.fact_movie_metrics f
        JOIN gold.dim_movie m ON f.movie_sk = m.movie_sk
        JOIN gold.dim_date d ON f.release_date_sk = d.date_sk
        WHERE f.budget_currency = 'USD' AND f.budget_usd > 0 AND f.profit_usd IS NOT NULL
        ORDER BY f.profit_usd DESC
        LIMIT 15
    """,
    "genero_mais_lucrativo": """
        SELECT g.genre_name,
               COUNT(DISTINCT f.movie_sk) AS movie_count,
               ROUND(SUM(f.budget_usd)::numeric, 2) AS total_budget_usd,
               ROUND(SUM(f.gross_worldwide_usd)::numeric, 2) AS total_gross_usd,
               ROUND(SUM(f.profit_usd)::numeric, 2) AS total_profit_usd
        FROM gold.fact_movie_metrics f
        JOIN gold.bridge_movie_genre bg ON f.movie_sk = bg.movie_sk
        JOIN gold.dim_genre g ON bg.genre_sk = g.genre_sk
        WHERE f.budget_currency = 'USD' AND f.budget_usd > 0 AND f.gross_worldwide_usd IS NOT NULL
        GROUP BY g.genre_name
        ORDER BY total_profit_usd DESC
    """,
    "lucro_medio_genero": """
        SELECT g.genre_name,
               COUNT(DISTINCT f.movie_sk) AS movie_count,
               ROUND(AVG(f.budget_usd)::numeric, 2) AS avg_budget_usd,
               ROUND(AVG(f.gross_worldwide_usd)::numeric, 2) AS avg_gross_usd,
               ROUND(AVG(f.profit_usd)::numeric, 2) AS avg_profit_usd,
               ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY f.profit_usd)::numeric, 2) AS median_profit_usd
        FROM gold.fact_movie_metrics f
        JOIN gold.bridge_movie_genre bg ON f.movie_sk = bg.movie_sk
        JOIN gold.dim_genre g ON bg.genre_sk = g.genre_sk
        WHERE f.budget_currency = 'USD' AND f.budget_usd > 0 AND f.gross_worldwide_usd IS NOT NULL
        GROUP BY g.genre_name
        ORDER BY avg_profit_usd DESC
    """
}

def format_currency(val):
    if pd.isna(val):
        return "N/A"
    return f"${val:,.2f}"

def format_decimal(val):
    if pd.isna(val):
        return "N/A"
    return f"{val:.1f}"

def format_score(val):
    if pd.isna(val):
        return "N/A"
    return f"{val:.2f}"

st.sidebar.title("Menu de Navegação")

categorias = {
    "Visão Geral": "Visão Geral",
    "Críticas": "Críticas",
    "Dinheiro": "Dinheiro",
    "Gênero": "Gênero"
}

categoria = st.sidebar.radio(
    "Selecione uma categoria:",
    list(categorias.keys())
)

st.title("Dashboard de Análise de Filmes")
st.markdown("---")

if categoria == "Visão Geral":
    st.header("Resumo do Banco de Dados")
    col1, col2, col3 = st.columns(3)
    
    total_filmes = conn.query("SELECT COUNT(*) FROM gold.dim_movie").iloc[0, 0]
    total_generos = conn.query("SELECT COUNT(*) FROM gold.dim_genre").iloc[0, 0]
    anos_cobertos = conn.query("SELECT COUNT(DISTINCT year) FROM gold.dim_date").iloc[0, 0]
    
    col1.metric("Total de Filmes", f"{total_filmes:,}")
    col2.metric("Gêneros Mapeados", total_generos)
    col3.metric("Anos de Dados", anos_cobertos)

elif categoria == "Críticas":
    st.header("Análise de Críticas e Avaliações")
    
    st.subheader("1. Evolução das Notas de Críticos (IMDB vs RT)")
    st.caption("Ambas as notas normalizadas para escala 0-10 para comparação justa.")
    df_evolucao = run_query(QUERIES["evolucao_notas"])
    
    df_evolucao_renamed = df_evolucao.rename(columns={
        "avg_imdb_rating": "IMDB (0-10)",
        "avg_rt_tomato_meter": "Rotten Tomatoes (0-10)"
    })
    
    fig_evolucao = px.line(df_evolucao_renamed, x="year", y=["IMDB (0-10)", "Rotten Tomatoes (0-10)"], 
                           labels={"value": "Nota (0-10)", "year": "Ano de Lançamento", "variable": "Fonte"},
                           markers=True, color_discrete_sequence=["#FF9900", "#FA3219"])
    
    fig_evolucao.update_yaxes(range=[0, 10], dtick=1)
    
    st.plotly_chart(fig_evolucao, use_container_width=True)
    
    st.markdown("---")
    
    st.subheader("2. Melhores Filmes Avaliados (Score Composto)")
    st.info("O Score Composto normaliza o RT para 0-10 e calcula a média apenas das fontes que possuem dados.")
    df_melhores = run_query(QUERIES["melhores_filmes"])
    
    df_melhores['imdb_rating'] = df_melhores['imdb_rating'].apply(format_decimal)
    df_melhores['rt_tomato_meter'] = df_melhores['rt_tomato_meter'].apply(format_decimal)
    df_melhores['lb_vote_average'] = df_melhores['lb_vote_average'].apply(format_decimal)
    df_melhores['composite_score'] = df_melhores['composite_score'].apply(format_score)
    
    st.dataframe(df_melhores, use_container_width=True, hide_index=True)

elif categoria == "Dinheiro":
    st.header("Análise Financeira (USD)")
    
    st.subheader("3. Comparação: Lucro Total x Orçamento Total por Ano")
    df_fin_ano = run_query(QUERIES["lucro_vs_orcamento"])
    
    df_fin_melt = df_fin_ano.melt(id_vars=["year"], 
                                  value_vars=["total_budget_usd", "total_gross_usd", "total_profit_usd"],
                                  var_name="Métrica", value_name="Valor")
    
    label_map = {
        "total_budget_usd": "Orçamento Total",
        "total_gross_usd": "Receita Total",
        "total_profit_usd": "Lucro Total"
    }
    df_fin_melt["Métrica"] = df_fin_melt["Métrica"].map(label_map)
    
    color_map = {
        "Orçamento Total": "#FF9900",
        "Receita Total": "#00C853",
        "Lucro Total": "#2962FF"
    }
    
    fig_fin = px.bar(df_fin_melt, x="year", y="Valor", color="Métrica", 
                     barmode="group", labels={"year": "Ano", "Valor": "USD"},
                     color_discrete_map=color_map)
    st.plotly_chart(fig_fin, use_container_width=True)
    
    st.markdown("---")
    
    st.subheader("4. Top 15 Filmes Mais Lucrativos")
    df_top_lucro = run_query(QUERIES["filmes_mais_lucrativos"])
    
    for col in ['budget_usd', 'gross_worldwide_usd', 'profit_usd']:
        df_top_lucro[col] = df_top_lucro[col].apply(format_currency)
        
    def color_profit(val):
        if isinstance(val, str):
            if val.startswith('-'): 
                return 'color: red; font-weight: bold'
            elif val != 'N/A': 
                return 'color: green; font-weight: bold'
        return ''

    styled_df = df_top_lucro.style.map(color_profit, subset=['profit_usd'])
    st.dataframe(styled_df, use_container_width=True, hide_index=True)

elif categoria == "Gênero":
    st.header("Análise por Gênero")
    
    col1, col2 = st.columns(2)
    
    with col1:
        st.subheader("5. Lucro Total por Gênero (Top 10)")
        df_gen_total = run_query(QUERIES["genero_mais_lucrativo"])
        fig_gen_total = px.bar(df_gen_total.head(10), x="total_profit_usd", y="genre_name", orientation='h',
                               labels={"total_profit_usd": "Lucro Total (USD)", "genre_name": "Gênero"},
                               color="total_profit_usd", color_continuous_scale="Viridis")
        st.plotly_chart(fig_gen_total, use_container_width=True)
    
    with col2:
        st.subheader("6. Lucro Médio vs Mediano por Gênero (Top 10)")
        st.caption("A mediana é mais representativa que a média, pois não é distorcida por blockbusters.")
        df_gen_medio = run_query(QUERIES["lucro_medio_genero"])
        
        df_gen_medio_renamed = df_gen_medio.rename(columns={
            "avg_profit_usd": "Lucro Médio",
            "median_profit_usd": "Lucro Mediano"
        })
        
        fig_gen_medio = px.bar(df_gen_medio_renamed.head(10), x="genre_name", y=["Lucro Médio", "Lucro Mediano"],
                               labels={"value": "USD", "genre_name": "Gênero", "variable": "Tipo de Lucro"},
                               barmode="group", color_discrete_sequence=["#FF9900", "#2962FF"])
        st.plotly_chart(fig_gen_medio, use_container_width=True)

st.markdown("---")
st.caption("Dados provenientes da Camada Gold (Star Schema) | Desenvolvido com Streamlit & Plotly")