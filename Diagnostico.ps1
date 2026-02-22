$Hostname = $env:COMPUTERNAME
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$TimeStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile = "$ScriptDir\Log_Rede_${Hostname}_$TimeStamp.txt"

function Write-Log {
    param ([string]$Texto, [string]$Cor = "White")
    Write-Host $Texto -ForegroundColor $Cor
    $Texto | Out-File -FilePath $LogFile -Append -Encoding UTF8
}

function Get-NetworkInfo {
    param ($IP, $Prefix)
    if ($Prefix -lt 0 -or $Prefix -gt 32) { return @{ Mask = "Indefinida"; Network = "Indefinida"; Broadcast = "Indefinido" } }
    $maskBinary = ("1" * $Prefix).PadRight(32, "0")
    $maskBytes = @()
    for ($i = 0; $i -lt 4; $i++) { $octet = $maskBinary.Substring($i*8,8); $maskBytes += [Convert]::ToInt32($octet,2) }
    $ipBytes = [System.Net.IPAddress]::Parse($IP).GetAddressBytes()
    $network = @(); $broadcast = @()
    for ($i=0; $i -lt 4; $i++) {
        $network += ($ipBytes[$i] -band $maskBytes[$i])
        $broadcast += ($network[$i] -bor (255 -bxor $maskBytes[$i]))
    }
    return @{ Mask = ($maskBytes -join "."); Network = ($network -join "."); Broadcast = ($broadcast -join ".") }
}

Write-Log "==================================================" "Cyan"
Write-Log "        DIAGNOSTICO PROFUNDO DE REDE"
Write-Log "        Host: $Hostname | Data: $(Get-Date)"
Write-Log "==================================================" "Cyan"

$Adapter = Get-NetIPConfiguration | Where-Object { $_.IPv4Address -ne $null -and $_.NetProfile.IPv4Connectivity -ne "Disconnected" } | Select-Object -First 1

if (-not $Adapter) {
    Write-Log "ERRO: Nenhum adaptador IPv4 ativo encontrado. O cabo esta conectado?" "Red"
    Read-Host "`nPressione Enter para sair..."
    exit
}

$IP = $Adapter.IPv4Address.IPAddress
$Prefix = $Adapter.IPv4Address.PrefixLength
$Gateway = $Adapter.IPv4DefaultGateway.NextHop
$DNS = ($Adapter.DnsServer.ServerAddresses) -join ", "
$NetInfo = Get-NetworkInfo -IP $IP -Prefix $Prefix

Write-Log "[+] IP Local: $IP / $Prefix"
Write-Log "[+] Gateway: $Gateway"
Write-Log "[+] DNS: $DNS"
Write-Log "[+] Rede/Broadcast: $($NetInfo.Network) / $($NetInfo.Broadcast)"

Write-Log "`n--- INICIANDO TESTES (Isso pode demorar alguns minutos) ---" "Yellow"

Write-Log "[1/6] Coletando Tabela ARP..."
arp -a | Select-String $Gateway | ForEach-Object { Write-Log "    ARP Entry: $_" }

Write-Log "[2/6] Testando Latencia com Gateway..." -NoNewline
$gwPing = Test-Connection $Gateway -Count 2 -ErrorAction SilentlyContinue
if ($gwPing) { Write-Log " OK" "Green" } else { Write-Log " SEM RESPOSTA (Normal em algumas redes corporativas)" "Yellow" }

Write-Log "[3/6] Testando Conexao Externa (8.8.8.8)..." -NoNewline
$netPing = Test-Connection 8.8.8.8 -Count 2 -ErrorAction SilentlyContinue
if ($netPing) { Write-Log " OK" "Green" } else { Write-Log " FALHA" "Red" }

$AD_Server = "172.23.100.1"
Write-Log "[4/6] Testando Servidor AD ($AD_Server)..." -NoNewline
$adTest = Test-NetConnection $AD_Server -Port 389 -WarningAction SilentlyContinue
if ($adTest.TcpTestSucceeded) { Write-Log " CONECTADO" "Green" } else { Write-Log " INACESSIVEL" "Yellow" }

Write-Log "[5/6] Executando Tracert para Internet (Aguarde)..."
tracert -d -h 10 8.8.8.8 | Select-Object -First 10 | ForEach-Object { Write-Log "    $_" }

Write-Log "[6/6] Verificando portas comuns no Gateway..."
$Ports = 80, 443, 445
foreach ($Port in $Ports) {
    $t = Test-NetConnection -ComputerName $Gateway -Port $Port -WarningAction SilentlyContinue
    # Correção aplicada na linha abaixo: ${Port}
    if ($t.TcpTestSucceeded) { Write-Log "    Porta ${Port}: ABERTA" "Green" }
}

Write-Log "`n================ RESUMO TECNICO =================" "Cyan"
$ArpCheck = arp -a | Select-String $Gateway
if (-not $ArpCheck) {
    Write-Log ">> FALHA FISICA: Gateway nao aparece no ARP. Cabo ou Porta Switch ruins." "Red"
} elseif ($adTest.TcpTestSucceeded) {
    Write-Log ">> TUDO OK: Comunicacao com o AD estabelecida." "Green"
} else {
    Write-Log ">> ALERTA: Sem acesso ao AD. Verifique se esta na rede corporativa." "Yellow"
}

Write-Log "`nLog completo salvo em: $LogFile" "Cyan"
Write-Log "=================================================="

Write-Host "`nPressione ENTER para encerrar este diagnostico..." -ForegroundColor White
Read-Host