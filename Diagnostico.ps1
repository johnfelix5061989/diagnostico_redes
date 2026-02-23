# ================================
# DIAGNOSTICO N2 - REDE LEGADA (v6)
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
Write-Log " DIAGNOSTICO N2 - INFRAESTRUTURA LEGADA"
Write-Log " Host: $Hostname | Data: $(Get-Date)"
Write-Log "========================================="

# -------- VARIAVEIS --------
$ADServer = "172.23.100.1"
$InternetIP = "8.8.8.8"
$TestDomain = "google.com"
$PortsToTest = @(53,443,389,445)

$TotalSteps = 8
$CurrentStep = 0

function Update-Progress($StepName) {
    $script:CurrentStep++
    $percent = [int](($script:CurrentStep / $script:TotalSteps) * 100)
    Write-Progress -Activity "Diagnostico N2 em execucao..." `
                   -Status "$StepName ($percent%)" `
                   -PercentComplete $percent
}

# -------- 1 - ESTADO DA INTERFACE E FISICO --------
function Get-NetworkState {
    Update-Progress "Analisando hardware e interfaces"

    # Pega placas fisicas reais, ignorando virtuais e bluetooth
    $adapters = Get-NetAdapter | Where-Object {
        $_.Status -eq 'Up' -and 
        $_.InterfaceDescription -notmatch "Bluetooth|Virtual|VMware|Hyper-V|Loopback"
    }

    if (-not $adapters) {
        Write-Log "`n[!] NENHUM CABO OU REDE CONECTADA."
        return
    }

    foreach ($adapter in $adapters) {
        Write-Log "`n--- Adaptador: $($adapter.InterfaceAlias) ---"
        Write-Log "Descricao: $($adapter.InterfaceDescription)"
        Write-Log "MAC Address: $($adapter.MacAddress)  <-- (Use para rastrear no Switch)"
        Write-Log "Velocidade Negociada: $($adapter.LinkSpeed)"

        # ALERTA DE CABEAMENTO LEGADO
        if ($adapter.LinkSpeed -match "10 Mbps|100 Mbps" -and $adapter.InterfaceAlias -match "Ethernet|Conexao Local") {
            Write-Log "[!] ATENCAO FISICA: Placa operando a 100Mbps ou menos. Se o switch for Gigabit, ha degradacao no patch cord, tomada ou porta do rack."
        }

        # Perfil de Firewall (Dominio vs Publico)
        $profile = Get-NetConnectionProfile -InterfaceAlias $adapter.InterfaceAlias -ErrorAction SilentlyContinue
        if ($profile) {
            Write-Log "Perfil de Firewall: $($profile.NetworkCategory)"
            if ($profile.NetworkCategory -eq "Public") {
                Write-Log "[!] ALERTA SO: Rede classificada como PUBLICA. O Windows pode bloquear pastas de rede e AD."
            }
        }

        # Informacoes de IP
        $ipconfig = Get-NetIPConfiguration -InterfaceAlias $adapter.InterfaceAlias -ErrorAction SilentlyContinue
        if ($ipconfig.IPv4Address) {
            Write-Log "IP: $($ipconfig.IPv4Address.IPAddress)"
            Write-Log "Gateway: $($ipconfig.IPv4DefaultGateway.NextHop)"
            Write-Log "DNS: $($ipconfig.DNSServer.ServerAddresses -join ', ')"

            # Controle APIPA e Fail-Safe
            if ($ipconfig.IPv4Address.IPAddress -like "169.254.*") {
                Write-Log "[!] APIPA detectado em: $($adapter.InterfaceAlias)"
                if ($adapter.InterfaceAlias -match "Wi-Fi|Wireless") {
                    $global:WifiApipa = $true
                } else {
                    $global:ApipaGeral = $true
                }
            } else {
                if ($adapter.InterfaceAlias -match "Ethernet|Conexao Local") {
                    $global:EthernetAtiva = $true
                }
            }
        } else {
            Write-Log "[!] Sem configuracao de IPv4."
        }
    }

    # VERIFICACAO DE PROXY (O vilao invisivel)
    $proxy = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    if ($proxy.ProxyEnable -eq 1) {
        Write-Log "`n[!] ALERTA PROXY: Proxy manual ativado no Windows: $($proxy.ProxyServer)"
    }
    if ($proxy.AutoConfigURL) {
        Write-Log "`n[!] ALERTA PROXY: Script PAC configurado: $($proxy.AutoConfigURL)"
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
            Write-Log "[!] Jitter elevado (Comum em cabos degradados ou switch saturado)"
        }
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
    Write-Log " LAUDO TECNICO DE CONECTIVIDADE"
    Write-Log "========================================="

    if ($global:EthernetAtiva -and ($internet -or $dns) -and $global:WifiApipa) {
        Write-Log "[ESTADO]: ONLINE / CABEADO FUNCIONAL"
        Write-Log "[FAIL-SAFE ATIVADO]: Wi-Fi abandonado com IP APIPA ignorado. Navegacao fluindo pela porta Ethernet."
    }
    elseif ($internet -or $dns) {
        Write-Log "[ESTADO]: CONECTADO E OPERACIONAL"
        Write-Log "[CAMADA]: L1 a L7 Operacionais"
        Write-Log "[CAUSA]: Roteamento principal funcional. Se o usuario reclama de lentidao, analise a Velocidade Negociada (Link Speed) e o Jitter no log acima."
    }
    elseif ($global:ApipaGeral) {
        Write-Log "[ESTADO]: OFFLINE / SEM COMUNICACAO L2"
        Write-Log "[CAMADA]: Camadas 1 e 2 (Fisica / Enlace)"
        Write-Log "[CAUSA]: Falha de DHCP. Encaminhe o MAC Address acima para o N3 rastrear a porta no Switch/VLAN. Verifique cabeamento."
    }
    elseif (-not $gw) {
        Write-Log "[ESTADO]: ISOLAMENTO LOCAL"
        Write-Log "[CAMADA]: Camadas 1, 2 ou 3"
        Write-Log "[CAUSA]: Falha de comunicacao com o Gateway. Porta bloqueada no switch, IP duplicado ou cabeamento severamente danificado."
    }
    elseif ($gw -and (-not $internet -or -not $dns)) {
        Write-Log "[ESTADO]: BLOQUEIO DE ROTA EXTERNA OU DNS"
        Write-Log "[CAMADA]: Camada 3 (Roteamento) ou Camada 7 (Aplicacao/Proxy)"
        Write-Log "[CAUSA]: Chega no rack local, mas nao sai para web. Verifique Proxy no Windows (log acima), link MikroTik ou regras de Firewall."
    }
    else {
        Write-Log "[ESTADO]: INDETERMINADO"
        Write-Log "[CAUSA]: Analise o log detalhado."
    }

    if ($internet -and -not $ad) {
        Write-Log "`n[INFO]: O Controlador de Dominio ($ADServer) nao respondeu. Verifique roteamento interno/VLANs."
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
Write-Log "Log salvo com sucesso em: $LogFile"

Write-Host "`nPressione ENTER para fechar..."
Read-Host