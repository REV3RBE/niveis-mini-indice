# Níveis do Mini Índice

Site que calcula, antes da abertura da B3, o preço justo de abertura, a máxima e a mínima prováveis do Mini Índice (WIN). Quem usa digita só o fechamento do índice futuro do dia anterior.

## Fórmulas

- Taxa VIX (%) = VIX futuro ÷ √(pregões da B3 no ano vigente)
- Preço justo = Fechamento × (1 + variação % do S&P 500 futuro)
- Máxima = Preço justo × (1 + Taxa VIX)
- Mínima = Preço justo × (1 − Taxa VIX)

Os pregões do ano são calculados na própria página: segunda a sexta, menos os feriados em que a B3 não abre (2026 = 247).

## Coleta automática

O GitHub Actions (`.github/workflows/coletar.yml`) roda `coletar-site.ps1` uma vez por dia, todos os dias, às 8:50 de Brasília. Ele busca:

- Fechamento do WIN vigente: B3, último candle do pregão

- S&P 500 futuro: Yahoo Finance (ES=F), variação %
- VIX futuro: CNBC (@VX.1), cotação

Grava `dados.json` e acrescenta uma linha em `historico.csv`, depois publica o site no GitHub Pages. O Investing.com bloqueia coleta automática, por isso não é usado aqui.

Para coletar na hora: aba **Actions** → **Coleta e publicação** → **Run workflow**.

O GitHub pode atrasar execuções agendadas em alguns minutos.

Uso como referência, não como recomendação de investimento.
