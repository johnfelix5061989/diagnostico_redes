# ================================
# DIAGNOSTICO N2 - REDE
# ================================

Clear-Host
Write-Host "========================================="
Write-Host " DIAGNOSTICO N2 - ANALISE DE REDE "
Write-Host "========================================="

# -------- VARIAVEIS PADRAO --------
$ADServer = "172.23.100.1"
$InternetIP = "8.8.8.8"
$TestDomain = "google.com"
$PortsToTest = @(53,443,389,445)

# -------- FUNCAO 1 - ESTADO IP --------
function Get-NetworkState {
    Write-Host "`n[1] ESTADO DA INTERFACE"

    $ipconfig = Get-NetIPConfiguration | Where-Object {$_.IPv4Address -ne $null}

    foreach ($i in $ipconfig) {
        Write-Host "Interface: $($i.InterfaceAlias)"
        Write-Host "IP: $($i.IPv4Address.IPAddress)"
        Write-Host "Gateway: $($i.IPv4DefaultGateway.NextHop)"
        Write-Host "DNS: $($i.DNSServer.ServerAddresses -join ', ')"

        if ($i.IPv4Address.IPAddress -like "169.*") {
            Write-Host "⚠ APIPA detectado - Problema DHCP ou VLAN"
        }
    }
}

# -------- FUNCAO 2 - TESTE PING --------
function Test-Ping($Target) {
    $result = Test-Connection -ComputerName $Target -Count 4 -ErrorAction SilentlyContinue
    if ($result) {
        Write-Host "Ping OK -> $Target"
        return $true
    } else {
        Write-Host "Falha Ping -> $Target"
        return $false
    }
}

# -------- FUNCAO 3 - TESTE DNS --------
function Test-DNS {
    Write-Host "`n[2] TESTE DNS"
    try {
        Resolve-DnsName $TestDomain -ErrorAction Stop | Out-Null
        Write-Host "DNS OK"
        return $true
    }
    catch {
        Write-Host "Falha DNS"
        return $false
    }
}

# -------- FUNCAO 4 - TESTE PORTAS --------
function Test-Ports {
    Write-Host "`n[3] TESTE DE PORTAS"
    foreach ($port in $PortsToTest) {
        $test = Test-NetConnection -ComputerName $InternetIP -Port $port -WarningAction SilentlyContinue
        if ($test.TcpTestSucceeded) {
            Write-Host "Porta $port OK"
        } else {
            Write-Host "Porta $port BLOQUEADA"
        }
    }
}

# -------- FUNCAO 5 - JITTER --------
function Test-Jitter {
    Write-Host "`n[4] TESTE JITTER"

    $pings = Test-Connection -ComputerName $InternetIP -Count 10
    $times = $pings.ResponseTime

    $avg = ($times | Measure-Object -Average).Average
    $max = ($times | Measure-Object -Maximum).Maximum
    $min = ($times | Measure-Object -Minimum).Minimum

    $jitter = $max - $min

    Write-Host "Latência Média: $avg ms"
    Write-Host "Jitter: $jitter ms"

    if ($jitter -gt 50) {
        Write-Host "⚠ Jitter elevado - possível congestionamento"
    }
}

# -------- FUNCAO 6 - MTU --------
function Test-MTU {
    Write-Host "`n[5] TESTE MTU"

    $size = 1472
    $success = $false

    while ($size -gt 1300 -and -not $success) {
        $ping = ping $InternetIP -f -l $size -n 1
        if ($ping -notmatch "fragmentado") {
            $success = $true
        } else {
            $size -= 10
        }
    }

    $mtu = $size + 28
    Write-Host "MTU detectado: $mtu"
}

# -------- FUNCAO 7 - CLASSIFICACAO --------
function Get-Classification($gw,$ad,$dns) {
    Write-Host "`n[6] CLASSIFICACAO FINAL"

    if (-not $gw) {
        Write-Host "Provável Camada 1/2 - Gateway inacessível"
    }
    elseif (-not $ad) {
        Write-Host "Provável VLAN/ACL interna"
    }
    elseif (-not $dns) {
        Write-Host "Problema provável DNS"
    }
    else {
        Write-Host "Infraestrutura saudável - verificar aplicação ou firewall específico"
    }
}

# ================= EXECUCAO =================

Get-NetworkState

Write-Host "`n[TESTES DE CONECTIVIDADE]"
$gwTest = Test-Ping ((Get-NetRoute -DestinationPrefix "0.0.0.0/0").NextHop)
$adTest = Test-Ping $ADServer
$internetTest = Test-Ping $InternetIP

$dnsTest = Test-DNS

Test-Ports
Test-Jitter
Test-MTU

Get-Classification $gwTest $adTest $dnsTest

Write-Host "`nDiagnóstico concluído."