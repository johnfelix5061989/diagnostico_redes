# ================================
# DIAGNOSTICO N2 - REDE (v5 - Fail-Safe)
# ================================

Clear-Host

# -------- CONFIGURACAO DE LOG --------
$Hostname = $env:COMPUTERNAME
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$TimeStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile = "$ScriptDir\Log_Rede_${Hostname}_$TimeStamp.txt"

# Variaveis globais de estado
$global:ApipaGeral = $false
$global:WifiApipa = $false
$global:EthernetAtiva = $false

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

    $ipconfig = Get-NetIPConfiguration | Where-Object {
        $_.IPv4Address -ne $null -and 
        $_.InterfaceAlias -notmatch "Bluetooth|Virtual|VMware|Hyper-V|Loopback"
    }

    foreach ($i in $ipconfig) {
        Write-Log "`nInterface: $($i.InterfaceAlias)"
        Write-Log "IP: $($i.IPv4Address.IPAddress)"
        Write-Log "Gateway: $($i.IPv4DefaultGateway.NextHop)"
        Write-Log "DNS: $($i.DNSServer.ServerAddresses -join ', ')"

        # Verifica qual placa pegou APIPA ou qual esta saudavel
        if ($i.IPv4Address.IPAddress -like "169.254.*") {
            Write-Log "[!] APIPA detectado em: $($i.InterfaceAlias)"
            if ($i.InterfaceAlias -match "Wi-Fi|Wireless") {
                $global:WifiApipa = $true
            } else {
                $global:ApipaGeral = $true
            }
        } else {
            if ($i.InterfaceAlias -match "Ethernet|Conexao Local") {
                $global:EthernetAtiva = $true
            }
        }
    }
}

# -------- 2 - TESTE PING --------
function Test-Ping($Target) {
    if (-not $Target) { return $false }
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

    $pings = Test-Connection -ComputerName $InternetIP -Count 10 -ErrorAction SilentlyContinue
    $times = $pings.ResponseTime

    if ($times) {
        $avg = ($times | Measure-Object -Average).Average
        $max = ($times | Measure-Object -Maximum).Maximum
        $min = ($times | Measure-Object -Minimum).Minimum
        $jitter = $max - $min

        Write-Log "Latencia media: $([math]::Round($avg,2)) ms"
        Write-Log "Jitter: $jitter ms"

        if ($jitter -gt 50) {
            Write-Log "[!] Jitter elevado"
        }
    } else {
        Write-Log "Falha ao calcular Jitter. Sem resposta de ping externo."
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

# -------- 7 - CLASSIFICACAO FINAL --------
function Get-Classification($gw, $internet, $dns, $ad) {
    Update-Progress "Gerando laudo final"

    Write-Log "`n========================================="
    Write-Log " STATUS FINAL DA MAQUINA"
    Write-Log "========================================="

    # FAIL-SAFE: Cabeada, com internet, mas o Wi-Fi esta abandonado com APIPA
    if ($global:EthernetAtiva -and ($internet -or $dns) -and $global:WifiApipa) {
        Write-Log "[ESTADO]: ONLINE / CABEADO E TOTALMENTE FUNCIONAL"
        Write-Log "[FAIL-SAFE ATIVADO]: O adaptador Wi-Fi gerou um IP fantasma (APIPA), porem a maquina esta navegando pela rede Ethernet. Falso positivo ignorado."
    }
    # Regra de Ouro geral: Internet ou DNS funcionando
    elseif ($internet -or $dns) {
        Write-Log "[ESTADO]: CONECTADO E OPERACIONAL"
        Write-Log "[CAMADA]: L1 a L7 Operacionais"
        Write-Log "[CAUSA]: O trafego de rede esta fluindo normalmente."
        
        if ($global:ApipaGeral) {
            Write-Log "`n[ALERTA SECUNDARIO]: Outro adaptador da maquina falhou no DHCP, mas nao afetou a navegacao."
        }
    }
    # Falha real e critica de cabo/switch
    elseif ($global:ApipaGeral) {
        Write-Log "[ESTADO]: OFFLINE / SEM REDE"
        Write-Log "[CAMADA]: Camadas 1 e 2 (Fisica / Enlace)"
        Write-Log "[CAUSA]: Falha de DHCP na interface principal. Verifique cabo, porta do switch ou VLAN."
    }
    # Sem gateway e sem internet
    elseif (-not $gw) {
        Write-Log "[ESTADO]: COMUNICACAO LOCAL FALHA"
        Write-Log "[CAMADA]: Camadas 1, 2 ou 3 (Fisica / Enlace / Rede)"
        Write-Log "[CAUSA]: Gateway local inacessivel e maquina sem internet."
    }
    # Com gateway, mas sem internet
    elseif ($gw -and (-not $internet -or -not $dns)) {
        Write-Log "[ESTADO]: SEM ACESSO EXTERNO OU RESOLUCAO"
        Write-Log "[CAMADA]: Camada 3 (Roteamento) ou Camada 7 (Aplicacao)"
        Write-Log "[CAUSA]: O pacote chega ao Switch/Gateway, mas roteamento externo ou DNS estao falhando."
    }
    else {
        Write-Log "[ESTADO]: INDETERMINADO"
        Write-Log "[CAUSA]: Comportamento atipico. Analise o log detalhado acima."
    }

    if ($internet -and -not $ad) {
        Write-Log "`n[INFO]: Servidor AD ($ADServer) inacessivel. Ignore se estiver fora da rede corporativa."
    }

    Write-Log "========================================="
}

# ================= EXECUCAO =================

Get-NetworkState

Update-Progress "Testando conectividade estrutural"
$gwNextHop = (Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue).NextHop

$gwTest = $false
if ($gwNextHop) {
    Test-Connection -ComputerName $gwNextHop -Count 1 -Quiet | Out-Null
    $arpCheck = arp -a | Select-String $gwNextHop
    $pingCheck = Test-Ping $gwNextHop
    if ($arpCheck -or $pingCheck) { $gwTest = $true }
}

$adTest = Test-Ping $ADServer
$internetTest = Test-Ping $InternetIP

$dnsTest = Test-DNS
Test-Ports
Test-Jitter
Test-MTU

Get-Classification $gwTest $internetTest $dnsTest $adTest

Write-Progress -Activity "Diagnostico N2 em execucao..." -Completed

Write-Log "`nDiagnostico concluido."
Write-Log "Log salvo em: $LogFile"

Write-Host "`nPressione ENTER para sair..."
Read-Host