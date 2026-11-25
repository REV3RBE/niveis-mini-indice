# Coletor do site (roda no GitHub Actions, Linux, pwsh; tambem roda no Windows PowerShell 5.1).
# Busca S&P 500 futuro (Yahoo Finance, ES=F) e VIX futuro (CNBC, @VX.1) e grava dados.json.
# O Investing.com bloqueia coleta automatica (HTTP 403), por isso o site usa estas fontes.
# Saida com codigo 1 se nenhuma fonte responder (o dados.json anterior fica como estava).
$ErrorActionPreference = 'Stop'
$base = Split-Path -Parent $MyInvocation.MyCommand.Path
$ua   = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'
$inv  = [Globalization.CultureInfo]::InvariantCulture
$curl = if ($IsLinux -or $IsMacOS) { 'curl' } else { Join-Path $env:SystemRoot 'System32\curl.exe' }
$utf8 = New-Object Text.UTF8Encoding($false)
$fusoBR = $null
foreach ($id in 'America/Sao_Paulo', 'E. South America Standard Time') {
    try { $fusoBR = [TimeZoneInfo]::FindSystemTimeZoneById($id); break } catch {}
}

function Get-Json($url) {
    for ($i = 1; $i -le 3; $i++) {
        $tmp = [IO.Path]::GetTempFileName()
        $code = & $curl -s -L --compressed -m 30 -A $ua -o $tmp -w '%{http_code}' $url
        if ($code -eq '200') {
            $txt = [IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8)
            Remove-Item $tmp -ErrorAction SilentlyContinue
            return $txt | ConvertFrom-Json
        }
        Remove-Item $tmp -ErrorAction SilentlyContinue
        if ($i -eq 3) { throw "Falha ao abrir $url (HTTP $code)" }
        Start-Sleep -Seconds 10
    }
}

function ConvertTo-NumeroUS($s) {
    $limpo = [string]$s -replace '[^\d.+\-]', ''
    if (-not $limpo) { return 0.0 }
    return [double]::Parse($limpo, $inv)
}

function Get-HoraBR([long]$epoch) {
    $utc = [DateTimeOffset]::FromUnixTimeSeconds($epoch).UtcDateTime
    if ($fusoBR) { return [TimeZoneInfo]::ConvertTimeFromUtc($utc, $fusoBR) }
    return $utc.AddHours(-3)
}

function Get-SP {
    $j = $null
    foreach ($h in 'query1', 'query2') {
        try { $j = Get-Json "https://$h.finance.yahoo.com/v8/finance/chart/ES=F?interval=1d&range=5d"; break } catch { if ($h -eq 'query2') { throw } }
    }
    $m = $j.chart.result[0].meta
    if ($null -eq $m -or $null -eq $m.regularMarketPrice) { throw 'Resposta inesperada do Yahoo para ES=F' }
    $pct = $m.regularMarketChangePercent
    if ($null -eq $pct) { $pct = ($m.regularMarketPrice / $m.chartPreviousClose - 1) * 100 }
    return [ordered]@{
        fonte       = 'Yahoo Finance'
        titulo      = [string]$m.shortName
        url         = 'https://finance.yahoo.com/quote/ES=F'
        ultimo      = [double]$m.regularMarketPrice
        variacaoPct = [math]::Round([double]$pct, 2)
        horaSite    = (Get-HoraBR ([long]$m.regularMarketTime)).ToString('dd/MM HH:mm')
    }
}

function Get-VIX {
    $j = Get-Json 'https://quote.cnbc.com/quote-html-webservice/restQuote/symbolType/symbol?symbols=%40VX.1&requestMethod=itv&noform=1&partnerId=2&fund=1&exthrs=1&output=json&events=1'
    $q = @($j.FormattedQuoteResult.FormattedQuote)[0]
    if ($null -eq $q -or -not $q.last) { throw 'Resposta inesperada da CNBC para @VX.1' }
    $hora = [string]$q.last_timedate
    if ($q.EventData -and $q.EventData.is_halted -eq 'Y') { $hora = "ajuste de $($q.settleDate)" }
    $v = [ordered]@{
        fonte       = 'CNBC'
        titulo      = 'VIX Futuro ' + [string]$q.altSymbol + ' (venc. ' + [string]$q.expiration_date + ')'
        url         = 'https://www.cnbc.com/quotes/@VX.1'
        ultimo      = ConvertTo-NumeroUS $q.last
        variacaoPct = ConvertTo-NumeroUS $q.change_pct
        horaSite    = $hora
    }
    if ($v.ultimo -le 0) { throw 'VIX futuro veio zerado da CNBC' }
    return $v
}

# B3: fechamento do ultimo pregao do WIN vigente (vencimento mais proximo depois de hoje).
# Fechamento = closPric do ultimo candle de 1 minuto do pregao (leilao de fechamento),
# igual ao candle diario do grafico. NAO usar o ajuste nem o curPrc.
function Get-WIN($hojeISO) {
    $j = Get-Json 'https://cotacao.b3.com.br/mds/api/v1/DerivativeQuotation/WIN'
    $c = @($j.Scty) | Where-Object { $_.asset.AsstSummry.mtrtyCode -gt $hojeISO -and $_.SctyQtn.prvsDayAdjstmntPric } |
        Sort-Object { $_.asset.AsstSummry.mtrtyCode } | Select-Object -First 1
    if ($null -eq $c) { throw 'Nenhum contrato WIN vigente na resposta da B3' }
    $simb = [string]$c.symb
    $h = Get-Json "https://cotacao.b3.com.br/mds/api/v1/DailyFluctuationHistory/$simb"
    $barras = @($h.TradgFlr.scty.lstQtn)
    if ($barras.Count -eq 0 -or -not $barras[-1].closPric) { throw "A B3 ainda nao tem os candles do pregao de $simb" }
    # Coleta atrasada (depois das 9:00): o pregao de hoje ja abriu e o ultimo candle e preco ao vivo,
    # nao fechamento. O pregao fecha ~18:30; antes disso mantem o fechamento confirmado da coleta anterior.
    if ([string]$h.TradgFlr.date -eq $hojeISO -and [string]$barras[-1].dtTm -lt '18:20') {
        throw "O pregao de hoje ja esta aberto (ultimo candle $($barras[-1].dtTm)); o ultimo candle nao e fechamento"
    }
    return [ordered]@{
        fonte      = 'B3'
        simbolo    = $simb
        vencimento = [string]$c.asset.AsstSummry.mtrtyCode
        fechamento = [double]$barras[-1].closPric
        dataPregao = [string]$h.TradgFlr.date
        horaUltimoCandle = [string]$barras[-1].dtTm
        ajuste     = [double]$c.SctyQtn.prvsDayAdjstmntPric
        url        = 'https://www.b3.com.br/pt_br/market-data-e-indices/servicos-de-dados/market-data/cotacoes/'
    }
}

# Fechamento da coleta anterior (dados.json do repositorio), se a B3 estiver sem candles agora.
function Get-WINAnterior {
    $arq = Join-Path $base 'dados.json'
    if (-not (Test-Path $arq)) { return $null }
    try { $w = ([IO.File]::ReadAllText($arq, [Text.Encoding]::UTF8) | ConvertFrom-Json).win; if ($w -and $w.dataPregao) { return $w } } catch {}
    return $null
}

$agoraUtc = [DateTime]::UtcNow
$agoraBR = if ($fusoBR) { [TimeZoneInfo]::ConvertTimeFromUtc($agoraUtc, $fusoBR) } else { $agoraUtc.AddHours(-3) }

try {
    $sp  = Get-SP
    $vix = Get-VIX
} catch {
    Write-Host "ERRO: $($_.Exception.Message)"
    exit 1
}
$win = $null
try { $win = Get-WIN $agoraBR.ToString('yyyy-MM-dd') } catch {
    Write-Host "AVISO B3: $($_.Exception.Message)"
    $win = Get-WINAnterior
    if ($win) { Write-Host "AVISO B3: mantido o fechamento da coleta anterior (pregao de $($win.dataPregao))" }
}

$dados = [ordered]@{
    coletadoEm = $agoraBR.ToString('yyyy-MM-ddTHH:mm:ss')
    win = $win
    sp  = $sp
    vix = $vix
}
[IO.File]::WriteAllText((Join-Path $base 'dados.json'), ($dados | ConvertTo-Json -Depth 4), $utf8)

$hist = Join-Path $base 'historico.csv'
$cab = 'data;hora;sp_contrato;sp_variacao_pct;vix_contrato;vix_cotacao;win_contrato;win_fechamento'
if (-not (Test-Path $hist)) { [IO.File]::WriteAllText($hist, "$cab`n", $utf8) }
else {
    $linhas = [IO.File]::ReadAllLines($hist, $utf8)
    if ($linhas.Count -gt 0 -and $linhas[0] -notmatch 'win_') { $linhas[0] = $cab; [IO.File]::WriteAllText($hist, (($linhas -join "`n") + "`n"), $utf8) }
}
$linha = '{0};{1};{2};{3};{4};{5};{6};{7}' -f $agoraBR.ToString('dd/MM/yyyy'), $agoraBR.ToString('HH:mm'), $sp.titulo,
    $sp.variacaoPct.ToString('0.00', $inv).Replace('.', ','), $vix.titulo, $vix.ultimo.ToString('0.00', $inv).Replace('.', ','),
    $(if ($win) { $win.simbolo } else { '' }), $(if ($win) { $win.fechamento.ToString('0', $inv) } else { '' })
[IO.File]::AppendAllText($hist, "$linha`n", $utf8)

Write-Host ("OK  S&P var {0}%  VIX {1}  WIN {2}" -f $sp.variacaoPct, $vix.ultimo, $(if ($win) { "$($win.simbolo) $($win.fechamento)" } else { 'sem dado da B3' }))
