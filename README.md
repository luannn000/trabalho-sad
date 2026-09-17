# Como Executar o Dashboard

Guia rápido para configurar o ambiente e rodar o projeto.

---

### 1. Acessar o Ambiente Virtual (`venv`)

No terminal (PowerShell ou Prompt de Comando), dentro da pasta do projeto, ative o ambiente virtual:

```powershell
.\.venv\Scripts\activate
```

> *(Opcional) Se ainda não tiver o ambiente virtual criado, execute antes:*
> ```powershell
> python -m venv .venv
> ```

---

### 2. Instalar as Dependências

Com a `venv` ativada, instale os pacotes necessários listados no `requirements.txt`:

```powershell
pip install -r requirements.txt
```

---

### 3. Executar o Dashboard

Inicie a aplicação Streamlit:

```powershell
streamlit.exe run .\dashboard.py
```

*(Ou simplesmente `streamlit run dashboard.py` se o executável estiver no PATH).*

O painel será aberto automaticamente no seu navegador no endereço:
`http://localhost:8501`
