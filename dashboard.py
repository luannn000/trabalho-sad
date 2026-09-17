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
def run_query(query: str):
    return conn.query(query)

@st.cache_data(ttl=3600)
def get_filter_bounds():
    df = conn.query("""
        SELECT MIN(d.year) AS min_year, MAX(d.year) AS max_year
        FROM gold.fact_movie_metrics f
        JOIN gold.dim_date d ON f.release_date_sk = d.date_sk
        WHERE d.year IS NOT NULL
    """)
    min_year = int(df.iloc[0]['min_year']) if not df.empty and pd.notna(df.iloc[0]['min_year']) else 1920
    max_year = int(df.iloc[0]['max_year']) if not df.empty and pd.notna(df.iloc[0]['max_year']) else 2026
    return min_year, max_year

@st.cache_data(ttl=3600)
def get_available_genres():
    df = conn.query("""
        SELECT DISTINCT g.genre_name 
        FROM gold.dim_genre g
        JOIN gold.bridge_movie_genre bg ON g.genre_sk = bg.genre_sk
        WHERE g.genre_name IS NOT NULL AND g.genre_name != ''
        ORDER BY g.genre_name
    """)
    return df['genre_name'].tolist()

def sanitize_text(text: str) -> str:
    if not text:
        return ""
    return text.replace("'", "''").strip()

def build_genre_subquery(table_alias: str, generos: list) -> str:
    if not generos:
        return ""
    escaped_genres = ", ".join(f"'{g.replace(chr(39), chr(39)*2)}'" for g in generos)
    return (
        f"AND {table_alias}.movie_sk IN ("
        f"SELECT bg.movie_sk FROM gold.bridge_movie_genre bg "
        f"JOIN gold.dim_genre g ON bg.genre_sk = g.genre_sk "
        f"WHERE g.genre_name IN ({escaped_genres}))"
    )

def build_evolucao_notas_query(ano_inicio: int, ano_fim: int, generos: list = None) -> str:
    genre_cond = build_genre_subquery("f", generos)
    return f"""
        SELECT d.year,
               ROUND(AVG(f.imdb_rating)::numeric, 2) AS avg_imdb_rating,
               ROUND(AVG(f.rt_tomato_meter / 10.0)::numeric, 2) AS avg_rt_tomato_meter,
               COUNT(DISTINCT f.movie_sk) AS total_movies
        FROM gold.fact_movie_metrics f
        JOIN gold.dim_date d ON f.release_date_sk = d.date_sk
        WHERE (f.imdb_rating IS NOT NULL OR f.rt_tomato_meter IS NOT NULL)
          AND d.year BETWEEN {ano_inicio} AND {ano_fim}
          {genre_cond}
        GROUP BY d.year
        ORDER BY d.year
    """

def build_melhores_filmes_query(ano_inicio: int, ano_fim: int, generos: list = None, min_fontes: int = 1, busca: str = "", limit: int = 20) -> str:
    genre_cond = build_genre_subquery("f", generos)
    busca_cond = ""
    if busca:
        safe_b = sanitize_text(busca)
        busca_cond = f"AND (m.title ILIKE '%{safe_b}%' OR m.director ILIKE '%{safe_b}%')"

    return f"""
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
        WHERE (f.imdb_rating IS NOT NULL OR f.rt_tomato_meter IS NOT NULL OR f.lb_vote_average IS NOT NULL)
          AND d.year BETWEEN {ano_inicio} AND {ano_fim}
          AND (
              CASE WHEN f.imdb_rating IS NOT NULL THEN 1 ELSE 0 END +
              CASE WHEN f.rt_tomato_meter IS NOT NULL THEN 1 ELSE 0 END +
              CASE WHEN f.lb_vote_average IS NOT NULL THEN 1 ELSE 0 END
          ) >= {min_fontes}
          {genre_cond}
          {busca_cond}
        ORDER BY composite_score DESC, f.imdb_rating DESC NULLS LAST
        LIMIT {limit}
    """

def build_lucro_vs_orcamento_query(ano_inicio: int, ano_fim: int, generos: list = None) -> str:
    genre_cond = build_genre_subquery("f", generos)
    return f"""
        SELECT d.year,
               ROUND(SUM(f.budget_usd)::numeric, 2) AS total_budget_usd,
               ROUND(SUM(f.gross_worldwide_usd)::numeric, 2) AS total_gross_usd,
               ROUND(SUM(f.profit_usd)::numeric, 2) AS total_profit_usd
        FROM gold.fact_movie_metrics f
        JOIN gold.dim_date d ON f.release_date_sk = d.date_sk
        WHERE f.budget_currency = 'USD' AND f.budget_usd > 0 AND f.gross_worldwide_usd IS NOT NULL
          AND d.year BETWEEN {ano_inicio} AND {ano_fim}
          {genre_cond}
        GROUP BY d.year
        ORDER BY d.year
    """

def build_filmes_mais_lucrativos_query(ano_inicio: int, ano_fim: int, generos: list = None, busca: str = "", limit: int = 15) -> str:
    genre_cond = build_genre_subquery("f", generos)
    busca_cond = ""
    if busca:
        safe_b = sanitize_text(busca)
        busca_cond = f"AND m.title ILIKE '%{safe_b}%'"

    return f"""
        SELECT m.title, d.year,
               ROUND(f.budget_usd::numeric, 2) AS budget_usd,
               ROUND(f.gross_worldwide_usd::numeric, 2) AS gross_worldwide_usd,
               ROUND(f.profit_usd::numeric, 2) AS profit_usd,
               f.imdb_rating
        FROM gold.fact_movie_metrics f
        JOIN gold.dim_movie m ON f.movie_sk = m.movie_sk
        JOIN gold.dim_date d ON f.release_date_sk = d.date_sk
        WHERE f.budget_currency = 'USD' AND f.budget_usd > 0 AND f.profit_usd IS NOT NULL
          AND d.year BETWEEN {ano_inicio} AND {ano_fim}
          {genre_cond}
          {busca_cond}
        ORDER BY f.profit_usd DESC
        LIMIT {limit}
    """

def build_genero_mais_lucrativo_query(ano_inicio: int, ano_fim: int, generos: list = None, limit: int = 10) -> str:
    genre_filter_cond = ""
    if generos:
        escaped_genres = ", ".join(f"'{g.replace(chr(39), chr(39)*2)}'" for g in generos)
        genre_filter_cond = f"AND g.genre_name IN ({escaped_genres})"

    return f"""
        SELECT g.genre_name,
               COUNT(DISTINCT f.movie_sk) AS movie_count,
               ROUND(SUM(f.budget_usd)::numeric, 2) AS total_budget_usd,
               ROUND(SUM(f.gross_worldwide_usd)::numeric, 2) AS total_gross_usd,
               ROUND(SUM(f.profit_usd)::numeric, 2) AS total_profit_usd
        FROM gold.fact_movie_metrics f
        JOIN gold.dim_date d ON f.release_date_sk = d.date_sk
        JOIN gold.bridge_movie_genre bg ON f.movie_sk = bg.movie_sk
        JOIN gold.dim_genre g ON bg.genre_sk = g.genre_sk
        WHERE f.budget_currency = 'USD' AND f.budget_usd > 0 AND f.gross_worldwide_usd IS NOT NULL
          AND d.year BETWEEN {ano_inicio} AND {ano_fim}
          {genre_filter_cond}
        GROUP BY g.genre_name
        ORDER BY total_profit_usd DESC
        LIMIT {limit}
    """

def build_lucro_medio_genero_query(ano_inicio: int, ano_fim: int, generos: list = None, limit: int = 10) -> str:
    genre_filter_cond = ""
    if generos:
        escaped_genres = ", ".join(f"'{g.replace(chr(39), chr(39)*2)}'" for g in generos)
        genre_filter_cond = f"AND g.genre_name IN ({escaped_genres})"

    return f"""
        SELECT g.genre_name,
               COUNT(DISTINCT f.movie_sk) AS movie_count,
               ROUND(AVG(f.budget_usd)::numeric, 2) AS avg_budget_usd,
               ROUND(AVG(f.gross_worldwide_usd)::numeric, 2) AS avg_gross_usd,
               ROUND(AVG(f.profit_usd)::numeric, 2) AS avg_profit_usd,
               ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY f.profit_usd)::numeric, 2) AS median_profit_usd
        FROM gold.fact_movie_metrics f
        JOIN gold.dim_date d ON f.release_date_sk = d.date_sk
        JOIN gold.bridge_movie_genre bg ON f.movie_sk = bg.movie_sk
        JOIN gold.dim_genre g ON bg.genre_sk = g.genre_sk
        WHERE f.budget_currency = 'USD' AND f.budget_usd > 0 AND f.gross_worldwide_usd IS NOT NULL
          AND d.year BETWEEN {ano_inicio} AND {ano_fim}
          {genre_filter_cond}
        GROUP BY g.genre_name
        ORDER BY avg_profit_usd DESC
        LIMIT {limit}
    """

def build_resumo_filtrado_query(ano_inicio: int, ano_fim: int, generos: list = None) -> str:
    genre_cond = build_genre_subquery("f", generos)
    return f"""
        SELECT COUNT(DISTINCT f.movie_sk) AS total_filmes_filtrados,
               ROUND(AVG(f.imdb_rating)::numeric, 2) AS media_imdb,
               ROUND(SUM(f.gross_worldwide_usd)::numeric, 2) AS bilheteria_total_usd,
               ROUND(SUM(f.profit_usd)::numeric, 2) AS lucro_total_usd
        FROM gold.fact_movie_metrics f
        JOIN gold.dim_date d ON f.release_date_sk = d.date_sk
        WHERE d.year BETWEEN {ano_inicio} AND {ano_fim}
          {genre_cond}
    """

def format_currency(val):
    if pd.isna(val) or val is None:
        return "N/A"
    return f"${val:,.2f}"

def format_decimal(val):
    if pd.isna(val) or val is None:
        return "N/A"
    return f"{val:.1f}"

def format_score(val):
    if pd.isna(val) or val is None:
        return "N/A"
    return f"{val:.2f}"

# ==================== BARRA LATERAL (NAVEGAÇÃO E FILTROS) ====================
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

st.sidebar.markdown("---")
st.sidebar.subheader("Filtros Globais")

# Obter limites dinâmicos de anos e lista de gêneros
min_ano_db, max_ano_db = get_filter_bounds()
lista_generos = get_available_genres()

ano_range = st.sidebar.slider(
    "Período de Lançamento (Anos):",
    min_value=min_ano_db,
    max_value=max_ano_db,
    value=(min_ano_db, max_ano_db),
    step=1,
    key="filter_ano"
)
ano_inicio, ano_fim = ano_range

generos_selecionados = st.sidebar.multiselect(
    "Gênero(s):",
    options=lista_generos,
    default=[],
    placeholder="Todos os gêneros (padrão)",
    key="filter_genero"
)

top_n = st.sidebar.slider(
    "Quantidade nos Rankings (Top N):",
    min_value=5,
    max_value=50,
    value=15,
    step=5,
    key="filter_top_n"
)

# Filtros Contextuais conforme a aba selecionada
min_fontes = 1
busca_criticas = ""
busca_dinheiro = ""
top_n_generos = 10

if categoria == "Críticas":
    st.sidebar.markdown("---")
    st.sidebar.subheader("Filtros de Críticas")
    min_fontes = st.sidebar.slider(
        "Mínimo de Fontes de Avaliação:",
        min_value=1,
        max_value=3,
        value=1,
        step=1,
        help="Exige que o filme tenha avaliação em pelo menos 1, 2 ou 3 bases (IMDB, RT, Letterboxd)",
        key="filter_min_fontes"
    )
    busca_criticas = st.sidebar.text_input(
        "Buscar por Filme ou Diretor:",
        placeholder="Ex: Nolan, Godfather, Matrix...",
        key="filter_busca_criticas"
    ).strip()

elif categoria == "Dinheiro":
    st.sidebar.markdown("---")
    st.sidebar.subheader("Filtros Financeiros")
    busca_dinheiro = st.sidebar.text_input(
        "Buscar Filme por Título:",
        placeholder="Ex: Titanic, Avatar, Avengers...",
        key="filter_busca_dinheiro"
    ).strip()

elif categoria == "Gênero":
    st.sidebar.markdown("---")
    st.sidebar.subheader("Filtros de Gênero")
    top_n_generos = st.sidebar.slider(
        "Gêneros nos Gráficos (Top N):",
        min_value=5,
        max_value=30,
        value=10,
        step=5,
        key="filter_top_generos"
    )

st.sidebar.markdown("---")

# Botão para Redefinir Filtros
if st.sidebar.button("Redefinir Filtros", use_container_width=True):
    for k in ["filter_ano", "filter_genero", "filter_top_n", "filter_min_fontes", "filter_busca_criticas", "filter_busca_dinheiro", "filter_top_generos"]:
        if k in st.session_state:
            del st.session_state[k]
    st.rerun()

# Resumo dos filtros ativos na barra lateral
filtros_ativos = []
if ano_inicio != min_ano_db or ano_fim != max_ano_db:
    filtros_ativos.append(f"Anos: {ano_inicio} - {ano_fim}")
if generos_selecionados:
    if len(generos_selecionados) <= 3:
        filtros_ativos.append(f"Gêneros: {', '.join(generos_selecionados)}")
    else:
        filtros_ativos.append(f"Gêneros: {len(generos_selecionados)} selecionados")
if categoria == "Críticas":
    if min_fontes > 1:
        filtros_ativos.append(f"Fontes mínimas: {min_fontes}")
    if busca_criticas:
        filtros_ativos.append(f"Busca: '{busca_criticas}'")
elif categoria == "Dinheiro" and busca_dinheiro:
    filtros_ativos.append(f"Busca: '{busca_dinheiro}'")

if filtros_ativos:
    st.sidebar.info("\nFiltros em Ação:\n\n" + "\n\n".join(filtros_ativos))

# ==================== CABEÇALHO DA PÁGINA ====================
st.title("Dashboard de Análise de Filmes")
st.markdown("---")

# ==================== CONTEÚDO DAS ABAS ====================
if categoria == "Visão Geral":
    st.header("Resumo do Data Warehouse")
    
    st.markdown("##### Totais Globais da Camada Gold")
    col1, col2, col3 = st.columns(3)
    
    total_filmes = conn.query("SELECT COUNT(*) FROM gold.dim_movie").iloc[0, 0]
    total_generos = conn.query("SELECT COUNT(*) FROM gold.dim_genre").iloc[0, 0]
    anos_cobertos = conn.query("SELECT COUNT(DISTINCT year) FROM gold.dim_date").iloc[0, 0]
    
    col1.metric("Total de Filmes", f"{total_filmes:,}")
    col2.metric("Gêneros Mapeados", total_generos)
    col3.metric("Anos com Registros", anos_cobertos)
    
    st.markdown("---")
    st.markdown(f"##### Indicadores do Recorte Filtrado ({ano_inicio} a {ano_fim})")
    
    query_resumo = build_resumo_filtrado_query(ano_inicio, ano_fim, generos_selecionados)
    df_resumo = run_query(query_resumo)
    
    if not df_resumo.empty:
        r_filmes = df_resumo.iloc[0]['total_filmes_filtrados'] or 0
        r_media_imdb = df_resumo.iloc[0]['media_imdb']
        r_bilheteria = df_resumo.iloc[0]['bilheteria_total_usd']
        r_lucro = df_resumo.iloc[0]['lucro_total_usd']
        
        c1, c2, c3, c4 = st.columns(4)
        c1.metric("Filmes no Recorte", f"{r_filmes:,}")
        c2.metric("Nota Média (IMDB)", f"{r_media_imdb:.2f}" if pd.notna(r_media_imdb) else "N/A")
        c3.metric("Bilheteria Acumulada", format_currency(r_bilheteria))
        c4.metric("Lucro Acumulado", format_currency(r_lucro))
    else:
        st.info("Nenhum dado encontrado para os filtros atuais.")

elif categoria == "Críticas":
    st.header("Análise de Críticas e Avaliações")
    
    st.subheader("1. Evolução das Notas de Críticos (IMDB vs RT)")
    st.caption("Ambas as notas normalizadas para escala 0-10 para comparação justa.")
    
    query_evolucao = build_evolucao_notas_query(ano_inicio, ano_fim, generos_selecionados)
    df_evolucao = run_query(query_evolucao)
    
    if df_evolucao.empty:
        st.warning("Nenhum dado encontrado para o período e gêneros selecionados.")
    else:
        df_evolucao_renamed = df_evolucao.rename(columns={
            "avg_imdb_rating": "IMDB (0-10)",
            "avg_rt_tomato_meter": "Rotten Tomatoes (0-10)"
        })
        
        fig_evolucao = px.line(
            df_evolucao_renamed, 
            x="year", 
            y=["IMDB (0-10)", "Rotten Tomatoes (0-10)"], 
            labels={"value": "Nota (0-10)", "year": "Ano de Lançamento", "variable": "Fonte"},
            markers=True, 
            color_discrete_sequence=["#FF9900", "#FA3219"]
        )
        fig_evolucao.update_yaxes(range=[0, 10], dtick=1)
        st.plotly_chart(fig_evolucao, use_container_width=True)
    
    st.markdown("---")
    
    st.subheader(f"2. Melhores Filmes Avaliados - Score Composto (Top {top_n})")
    st.info("O Score Composto normaliza o RT para 0-10 e calcula a média apenas das fontes que possuem dados.")
    
    query_melhores = build_melhores_filmes_query(
        ano_inicio=ano_inicio,
        ano_fim=ano_fim,
        generos=generos_selecionados,
        min_fontes=min_fontes,
        busca=busca_criticas,
        limit=top_n
    )
    df_melhores = run_query(query_melhores)
    
    if df_melhores.empty:
        st.warning("Nenhum filme encontrado com os critérios de busca e filtros selecionados.")
    else:
        df_melhores_display = df_melhores.copy()
        df_melhores_display['imdb_rating'] = df_melhores_display['imdb_rating'].apply(format_decimal)
        df_melhores_display['rt_tomato_meter'] = df_melhores_display['rt_tomato_meter'].apply(format_decimal)
        df_melhores_display['lb_vote_average'] = df_melhores_display['lb_vote_average'].apply(format_decimal)
        df_melhores_display['composite_score'] = df_melhores_display['composite_score'].apply(format_score)
        
        df_melhores_display = df_melhores_display.rename(columns={
            "title": "Título",
            "director": "Diretor",
            "year": "Ano",
            "imdb_rating": "IMDB",
            "rt_tomato_meter": "Rotten Tomatoes",
            "lb_vote_average": "Letterboxd",
            "sources_count": "Qtd Fontes",
            "composite_score": "Score Composto"
        })
        
        st.dataframe(df_melhores_display, use_container_width=True, hide_index=True)

elif categoria == "Dinheiro":
    st.header("Análise Financeira (USD)")
    
    st.subheader("3. Comparação: Lucro Total x Orçamento Total por Ano")
    query_fin = build_lucro_vs_orcamento_query(ano_inicio, ano_fim, generos_selecionados)
    df_fin_ano = run_query(query_fin)
    
    if df_fin_ano.empty:
        st.warning("Nenhum dado financeiro encontrado para o período e gêneros selecionados.")
    else:
        df_fin_melt = df_fin_ano.melt(
            id_vars=["year"], 
            value_vars=["total_budget_usd", "total_gross_usd", "total_profit_usd"],
            var_name="Métrica", 
            value_name="Valor"
        )
        
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
        
        fig_fin = px.bar(
            df_fin_melt, 
            x="year", 
            y="Valor", 
            color="Métrica", 
            barmode="group", 
            labels={"year": "Ano", "Valor": "USD"},
            color_discrete_map=color_map
        )
        st.plotly_chart(fig_fin, use_container_width=True)
    
    st.markdown("---")
    
    st.subheader(f"4. Top {top_n} Filmes Mais Lucrativos")
    query_top_lucro = build_filmes_mais_lucrativos_query(
        ano_inicio=ano_inicio,
        ano_fim=ano_fim,
        generos=generos_selecionados,
        busca=busca_dinheiro,
        limit=top_n
    )
    df_top_lucro = run_query(query_top_lucro)
    
    if df_top_lucro.empty:
        st.warning("Nenhum filme encontrado com os critérios de busca e filtros selecionados.")
    else:
        df_top_lucro_display = df_top_lucro.copy()
        for col in ['budget_usd', 'gross_worldwide_usd', 'profit_usd']:
            df_top_lucro_display[col] = df_top_lucro_display[col].apply(format_currency)
        
        df_top_lucro_display['imdb_rating'] = df_top_lucro_display['imdb_rating'].apply(format_decimal)
        
        df_top_lucro_display = df_top_lucro_display.rename(columns={
            "title": "Título",
            "year": "Ano",
            "budget_usd": "Orçamento (USD)",
            "gross_worldwide_usd": "Receita Global (USD)",
            "profit_usd": "Lucro (USD)",
            "imdb_rating": "IMDB"
        })
            
        def color_profit(val):
            if isinstance(val, str):
                if val.startswith('$-'): 
                    return 'color: #D32F2F; font-weight: bold'
                elif val != 'N/A': 
                    return 'color: #388E3C; font-weight: bold'
            return ''

        styled_df = df_top_lucro_display.style.map(color_profit, subset=['Lucro (USD)'])
        st.dataframe(styled_df, use_container_width=True, hide_index=True)

elif categoria == "Gênero":
    st.header("Análise por Gênero")
    
    col1, col2 = st.columns(2)
    
    with col1:
        st.subheader(f"5. Lucro Total por Gênero (Top {top_n_generos})")
        query_gen_total = build_genero_mais_lucrativo_query(ano_inicio, ano_fim, generos_selecionados, limit=top_n_generos)
        df_gen_total = run_query(query_gen_total)
        
        if df_gen_total.empty:
            st.warning("Nenhum dado de gênero encontrado para o período e filtros atuais.")
        else:
            fig_gen_total = px.bar(
                df_gen_total, 
                x="total_profit_usd", 
                y="genre_name", 
                orientation='h',
                labels={"total_profit_usd": "Lucro Total (USD)", "genre_name": "Gênero"},
                color="total_profit_usd", 
                color_continuous_scale="Viridis"
            )
            fig_gen_total.update_layout(yaxis={'categoryorder': 'total ascending'})
            st.plotly_chart(fig_gen_total, use_container_width=True)
    
    with col2:
        st.subheader(f"6. Lucro Médio vs Mediano por Gênero (Top {top_n_generos})")
        st.caption("A mediana é mais representativa que a média, pois não é distorcida por blockbusters.")
        query_gen_medio = build_lucro_medio_genero_query(ano_inicio, ano_fim, generos_selecionados, limit=top_n_generos)
        df_gen_medio = run_query(query_gen_medio)
        
        if df_gen_medio.empty:
            st.warning("Nenhum dado de gênero encontrado para o período e filtros atuais.")
        else:
            df_gen_medio_renamed = df_gen_medio.rename(columns={
                "avg_profit_usd": "Lucro Médio",
                "median_profit_usd": "Lucro Mediano"
            })
            
            fig_gen_medio = px.bar(
                df_gen_medio_renamed, 
                x="genre_name", 
                y=["Lucro Médio", "Lucro Mediano"],
                labels={"value": "USD", "genre_name": "Gênero", "variable": "Tipo de Lucro"},
                barmode="group", 
                color_discrete_sequence=["#FF9900", "#2962FF"]
            )
            st.plotly_chart(fig_gen_medio, use_container_width=True)

st.markdown("---")
st.caption("Dados provenientes da Camada Gold (Star Schema) | Desenvolvido com Streamlit & Plotly")