# ================================
# DIAGNOSTICO N2 - REDE (v2)
# ================================

Clear-Host

# -------- CONFIGURACAO DE LOG --------
$Hostname = $env:COMPUTERNAME
# Pega automaticamente a pasta exata onde este script esta localizado
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$TimeStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile = "$ScriptDir\Log_Rede_${Hostname}_$TimeStamp.txt"

function Write-Log {
    param([string]$Texto)
    Write-Host $Texto
    $Texto | Out-File -FilePath $LogFile -Append -Encoding UTF8
}

Write-Log "========================================="
Write-Log " DIAGNOSTICO N2 - ANALISE DE REDE "
Write-Log " Data: $(Get-Date)"
Write-Log "========================================="

# -------- VARIAVEIS --------
$ADServer = "172.23.100.1"
$InternetIP = "8.8.8.8"
$TestDomain = "google.com"
$PortsToTest = @(53,443,389,445)

$TotalSteps = 7
$CurrentStep = 0

function Update-Progress($StepName) {
    $script:CurrentStep++
    $percent = [int](($script:CurrentStep / $script:TotalSteps) * 100)
    Write-Progress -Activity "Diagnostico N2 em execucao..." `
                   -Status "$StepName ($percent%)" `
                   -PercentComplete $percent
}

# -------- 1 - ESTADO DA INTERFACE --------
function Get-NetworkState {
    Update-Progress "Analisando interface de rede"

    $ipconfig = Get-NetIPConfiguration | Where-Object {$_.IPv4Address -ne $null}

    foreach ($i in $ipconfig) {
        Write-Log "`nInterface: $($i.InterfaceAlias)"
        Write-Log "IP: $($i.IPv4Address.IPAddress)"
        Write-Log "Gateway: $($i.IPv4DefaultGateway.NextHop)"
        Write-Log "DNS: $($i.DNSServer.ServerAddresses -join ', ')"

        if ($i.IPv4Address.IPAddress -like "169.*") {
            Write-Log "[!] APIPA detectado"
        }
    }
}

# -------- 2 - TESTE PING --------
function Test-Ping($Target) {
    $result = Test-Connection -ComputerName $Target -Count 4 -ErrorAction SilentlyContinue
    return $result -ne $null
}

# -------- 3 - TESTE DNS --------
function Test-DNS {
    Update-Progress "Testando resolucao DNS"

    try {
        Resolve-DnsName $TestDomain -ErrorAction Stop | Out-Null
        Write-Log "DNS OK"
        return $true
    }
    catch {
        Write-Log "Falha DNS"
        return $false
    }
}

# -------- 4 - TESTE PORTAS --------
function Test-Ports {
    Update-Progress "Testando portas criticas"

    foreach ($port in $PortsToTest) {
        $test = Test-NetConnection -ComputerName $InternetIP -Port $port -WarningAction SilentlyContinue
        if ($test.TcpTestSucceeded) {
            Write-Log "Porta $port OK"
        } else {
            Write-Log "Porta $port BLOQUEADA"
        }
    }
}

# -------- 5 - JITTER --------
function Test-Jitter {
    Update-Progress "Calculando jitter"

    $pings = Test-Connection -ComputerName $InternetIP -Count 10
    $times = $pings.ResponseTime

    if ($times) {
        $avg = ($times | Measure-Object -Average).Average
        $max = ($times | Measure-Object -Maximum).Maximum
        $min = ($times | Measure-Object -Minimum).Minimum
        $jitter = $max - $min

        Write-Log "Latencia media: $avg ms"
        Write-Log "Jitter: $jitter ms"

        if ($jitter -gt 50) {
            Write-Log "[!] Jitter elevado"
        }
    } else {
        Write-Log "Falha ao calcular Jitter. Sem resposta de ping."
    }
}

# -------- 6 - MTU --------
function Test-MTU {
    Update-Progress "Detectando MTU"

    $size = 1472
    $success = $false

    while ($size -gt 1300 -and -not $success) {
        $ping = ping $InternetIP -f -l $size -n 1
        if ($ping -notmatch "fragmentado" -and $ping -match "TTL=") {
            $success = $true
        } else {
            $size -= 10
        }
    }

    $mtu = $size + 28
    Write-Log "MTU detectado: $mtu"
}

# -------- 7 - CLASSIFICACAO --------
function Get-Classification($gw,$ad,$dns) {
    Update-Progress "Gerando classificacao final"

    Write-Log "`n===== CLASSIFICACAO ====="

    if (-not $gw) {
        Write-Log "Camada provavel: 1/2 (Gateway inacessivel)"
    }
    elseif (-not $ad) {
        Write-Log "Provavel bloqueio VLAN/ACL interna"
    }
    elseif (-not $dns) {
        Write-Log "Falha provavel DNS"
    }
    else {
        Write-Log "Infraestrutura saudavel"
    }
}

# ================= EXECUCAO =================

Get-NetworkState

Update-Progress "Testando conectividade estrutural"
$gwNextHop = (Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue).NextHop
if ($gwNextHop) {
    $gwTest = Test-Ping $gwNextHop
} else {
    $gwTest = $false
}
$adTest = Test-Ping $ADServer
$internetTest = Test-Ping $InternetIP

$dnsTest = Test-DNS
Test-Ports
Test-Jitter
Test-MTU
Get-Classification $gwTest $adTest $dnsTest

Write-Progress -Activity "Diagnostico N2 em execucao..." -Completed

Write-Log "`nDiagnostico concluido."
Write-Log "Log salvo com sucesso em: $LogFile"

Write-Host "`nPressione ENTER para sair..."
Read-Host