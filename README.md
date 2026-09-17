# Como Executar o Dashboard

Guia rápido para configurar o ambiente e rodar o projeto.

---

### 0. Configurar Conexão com o Banco

O arquivo `.streamlit/secrets.toml` **não é versionado** (contém senha). Copie o exemplo e edite com as credenciais reais:

```bash
cp .streamlit/secrets.toml.example .streamlit/secrets.toml
```

Depois abra `.streamlit/secrets.toml` e substitua `SUA_SENHA_AQUI` pela senha real do banco.

---

## Opção A: Manual (Windows/PowerShell)

### 1. Criar e Acessar o Ambiente Virtual (`venv`)

No terminal (PowerShell ou Prompt de Comando), dentro da pasta do projeto:

```powershell
python -m venv .venv
.\.venv\Scripts\activate
```

### 2. Instalar as Dependências

Com a `venv` ativada, instale os pacotes necessários listados no `requirements.txt`:

```powershell
pip install -r requirements.txt
```

### 3. Executar o Dashboard

```powershell
streamlit.exe run .\dashboard.py
```

*(Ou simplesmente `streamlit run dashboard.py` se o executável estiver no PATH).*

---

## Opção B: Makefile (Linux/Mac)

```bash
make venv     # cria o ambiente virtual (.venv)
make install  # instala as dependências do requirements.txt
make run      # roda o dashboard
```

---

Em ambas as opções, o painel será aberto automaticamente no seu navegador no endereço:
`http://localhost:8501`
