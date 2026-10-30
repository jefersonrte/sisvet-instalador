# SISVET Web - instalador para Windows 10/11 (tudo em C:\sisvet, sem Docker).
# PowerShell como administrador:
#   irm https://raw.githubusercontent.com/jefersonrte/sisvet-instalador/main/instalar.ps1 | iex
# Rodar de novo = atualizar (faz backup do banco antes e mantem os dados).
# Opcoes (antes do comando):  $env:SISVET_PORTA = '8090'   $env:SISVET_REDE = '1' (libera para outros PCs da rede privada)
#   Banco existente: coloque o dump em C:\sisvet\importar\ (*.sql ou *.sql.gz) e a chave do app em C:\sisvet\importar\APP_KEY.txt
#   (sem a chave os CPF/RG criptografados do dump nao abrem). So e importado quando o banco ainda esta vazio.
# Mensagens sem acento de proposito: o script roda em PowerShell 5.1 com qualquer codificacao.
& {
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Raiz = 'C:\sisvet'
$Repo = if ($env:SISVET_REPO) { $env:SISVET_REPO } else { 'jefersonrte/sisvet-instalador' }
$Origem = if ($env:SISVET_ORIGEM) { $env:SISVET_ORIGEM.TrimEnd('/') } else { "https://github.com/$Repo/releases/latest/download" }
$Porta = if ($env:SISVET_PORTA) { [int]$env:SISVET_PORTA } else { 8090 }
$Rede = $env:SISVET_REDE -eq '1'
$PortaBanco = 3307
$SvcBanco = 'SISVET-Banco'; $SvcWeb = 'SISVET-Web'
$Admins = '*S-1-5-32-544'; $Sistema = '*S-1-5-18'   # por SID: funciona em Windows de qualquer idioma

function Passo($t) { Write-Host "`n>> $t" -ForegroundColor Cyan }
function Falha($t) { Write-Host "`nERRO: $t" -ForegroundColor Red; throw $t }
function Senha([int]$n = 24) {
  $c = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'; $b = New-Object byte[] $n
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); -join ($b | ForEach-Object { $c[$_ % $c.Length] })
}
# programa externo: no PowerShell 5.1, stderr redirecionado vira erro fatal com Stop; aqui so vale o codigo de saida
function Exe($exe) { $e = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $o = & $exe @args 2>&1; $script:Codigo = $LASTEXITCODE } finally { $ErrorActionPreference = $e }
  $script:Erro = ($o | Where-Object { $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join ' '
  $o | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" } }   # devolve so a saida normal
function Icacls { & icacls.exe @args | Out-Null; if ($LASTEXITCODE) { Falha "icacls $($args -join ' ')" } }
function Gz2Sql($gz, $sql) {
  $i = [IO.File]::OpenRead($gz); $z = New-Object IO.Compression.GZipStream($i, [IO.Compression.CompressionMode]::Decompress)
  $o = [IO.File]::Create($sql); $z.CopyTo($o); $o.Close(); $z.Close(); $i.Close()
}
function Sql2Gz($sql, $gz) {
  $i = [IO.File]::OpenRead($sql); $o = [IO.File]::Create($gz); $z = New-Object IO.Compression.GZipStream($o, [IO.Compression.CompressionLevel]::Optimal)
  $i.CopyTo($z); $z.Close(); $o.Close(); $i.Close()
}
function Banco([string]$sql, [string]$base = '') {
  $env:MYSQL_PWD = $script:RootSenha
  $a = @('-uroot', '--host=127.0.0.1', "-P$PortaBanco", '--default-character-set=utf8mb4', '-N', '-e', $sql); if ($base) { $a += $base }
  $r = Exe "$Raiz\mariadb\bin\mariadb.exe" @a; $ok = $script:Codigo; Remove-Item Env:MYSQL_PWD
  if ($ok) { Falha "banco: $($script:Erro) $r" }; $r
}
function Artisan { Push-Location "$Raiz\app"; try { & "$Raiz\php\php.exe" artisan @args --no-interaction; if ($LASTEXITCODE) { Falha "artisan $($args -join ' ')" } } finally { Pop-Location } }
function ParaServico($n) { $s = Get-Service $n -ErrorAction SilentlyContinue; if ($s -and $s.Status -ne 'Stopped') { Stop-Service $n -Force; $s.WaitForStatus('Stopped', '00:01:00') } }
# servicos rodam em conta virtual (NT SERVICE\nome): sem senha, sem acesso a nada alem do que as permissoes abaixo liberam
function ContaServico($n) {
  & sc.exe config $n obj= "NT SERVICE\$n" | Out-Null; if ($LASTEXITCODE) { Falha "sc config $n" }
  & sc.exe failure $n reset= 86400 actions= restart/5000/restart/30000/restart/60000 | Out-Null }

# --- 0. conferencias ---------------------------------------------------------------------------------------------------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Falha 'abra o PowerShell como administrador (botao direito > Executar como administrador) e rode o comando de novo.' }
if (-not [Environment]::Is64BitOperatingSystem -or [Environment]::OSVersion.Version.Build -lt 17763) { Falha 'precisa de Windows 10/11 de 64 bits.' }
if ((Get-PSDrive C).Free -lt 2GB) { Falha 'precisa de pelo menos 2 GB livres no disco C:.' }
$Atualizando = Test-Path "$Raiz\app\.env"
foreach ($p in @($Porta, $PortaBanco)) {
  $uso = Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($uso) { $dono = (Get-Process -Id $uso.OwningProcess -ErrorAction SilentlyContinue).Path
    if ($dono -notlike "$Raiz\*") { Falha "a porta $p ja esta em uso por $dono. Escolha outra com `$env:SISVET_PORTA." } }
}
Write-Host "SISVET Web - $(if ($Atualizando) { 'atualizacao' } else { 'instalacao' }) em $Raiz (porta $Porta, $(if ($Rede) { 'rede privada' } else { 'so este computador' }))"

# --- 1. pastas (so administradores; os servicos ganham acesso so ao que precisam) ---------------------------------------
Passo 'Preparando C:\sisvet'
foreach ($d in 'config', 'dados', 'backup', 'importar', 'logs\web', 'logs\banco', 'tmp\web', 'tmp\banco', 'baixados') { New-Item -ItemType Directory -Force "$Raiz\$d" | Out-Null }
# sem /T: as subpastas herdam; icacls propaga as permissoes herdaveis sozinho
Icacls $Raiz /inheritance:r /grant:r "${Admins}:(OI)(CI)F" "${Sistema}:(OI)(CI)F"

# --- 2. downloads conferidos pelo SHA-256 -------------------------------------------------------------------------------
Passo "Baixando de $Origem"
$B = "$Raiz\baixados"
Invoke-WebRequest "$Origem/SHA256SUMS.txt" -OutFile "$B\SHA256SUMS.txt" -UseBasicParsing
Invoke-WebRequest "$Origem/VERSAO.txt" -OutFile "$B\VERSAO.txt" -UseBasicParsing
$Versao = (Get-Content "$B\VERSAO.txt" -Raw).Trim()
$Hash = @{}; Get-Content "$B\SHA256SUMS.txt" | ForEach-Object { $h, $n = $_ -split '\s+\*?', 2; if ($n) { $Hash[$n.Trim()] = $h.ToLower() } }
function Baixa($n) {
  $f = "$B\$n"
  if (-not ((Test-Path $f) -and (Get-FileHash $f -Algorithm SHA256).Hash.ToLower() -eq $Hash[$n])) {
    Write-Host "   $n"; Invoke-WebRequest "$Origem/$n" -OutFile $f -UseBasicParsing }
  if ((Get-FileHash $f -Algorithm SHA256).Hash.ToLower() -ne $Hash[$n]) { Remove-Item $f; Falha "o arquivo $n veio diferente do publicado (SHA-256). Nada foi alterado." }
  $f
}
$ZipApp = Baixa 'sisvet-app.zip'; $ZipRt = Baixa 'sisvet-runtime.zip'
Add-Type -AssemblyName System.IO.Compression.FileSystem

# --- 3. Visual C++ (exigido por PHP, Apache e MariaDB) ------------------------------------------------------------------
$vc = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64' -ErrorAction SilentlyContinue
if (-not $vc -or $vc.Installed -ne 1 -or $vc.Bld -lt 33810) {
  Passo 'Instalando o Visual C++ da Microsoft'
  $vce = Baixa 'vc_redist.x64.exe'; $sig = Get-AuthenticodeSignature $vce
  if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { Falha 'assinatura do vc_redist invalida.' }
  $p = Start-Process $vce '/install /quiet /norestart' -Wait -PassThru; if ($p.ExitCode -notin 0, 1638, 3010) { Falha "vc_redist saiu com $($p.ExitCode)" }
}

# --- 4. backup antes de mexer (atualizacao) -----------------------------------------------------------------------------
$RootArq = "$Raiz\config\banco-root.txt"
if (Test-Path $RootArq) { $script:RootSenha = (Get-Content $RootArq -Raw).Trim() }
if ($Atualizando -and (Get-Service $SvcBanco -ErrorAction SilentlyContinue)) {
  Passo 'Guardando uma copia do banco antes de atualizar'
  Start-Service $SvcBanco; Start-Sleep 3
  $sql = "$Raiz\tmp\antes-atualizar.sql"; $env:MYSQL_PWD = $script:RootSenha
  & "$Raiz\mariadb\bin\mariadb-dump.exe" -uroot --host=127.0.0.1 "-P$PortaBanco" --single-transaction --routines --triggers --default-character-set=utf8mb4 "--result-file=$sql" sisvet
  $ok = $LASTEXITCODE; Remove-Item Env:MYSQL_PWD; if ($ok) { Falha 'o backup do banco falhou; nada foi alterado.' }
  Sql2Gz $sql "$Raiz\backup\sisvet-antes-$Versao-$(Get-Date -f yyyyMMdd-HHmmss).sql.gz"; Remove-Item $sql
}

# --- 5. PHP, Apache e MariaDB --------------------------------------------------------------------------------------------
$RtNovo = ([IO.Compression.ZipFile]::OpenRead($ZipRt)).Entries | Where-Object FullName -eq 'RUNTIME.txt' | ForEach-Object { (New-Object IO.StreamReader($_.Open())).ReadToEnd() }
$RtAtual = if (Test-Path "$Raiz\RUNTIME.txt") { (Get-Content "$Raiz\RUNTIME.txt" -Raw).Trim() }
ParaServico $SvcWeb
if ($RtNovo -ne $RtAtual) {
  Passo 'Instalando PHP, Apache e MariaDB'
  ParaServico $SvcBanco
  $t = "$Raiz\tmp\runtime"; if (Test-Path $t) { Remove-Item $t -Recurse -Force }
  [IO.Compression.ZipFile]::ExtractToDirectory($ZipRt, $t)
  foreach ($d in 'php', 'apache', 'mariadb') { if (Test-Path "$Raiz\$d") { Remove-Item "$Raiz\$d" -Recurse -Force }; Move-Item "$t\$d" "$Raiz\$d" }
  Move-Item "$t\RUNTIME.txt" "$Raiz\RUNTIME.txt" -Force; Remove-Item $t -Recurse -Force
}

# configuracoes enxutas (regravadas a cada execucao)
$R = $Raiz -replace '\\', '/'
@"
[mysqld]
datadir=$R/dados
port=$PortaBanco
bind-address=127.0.0.1
skip-name-resolve
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
log-error=$R/logs/banco/erro.log
secure_file_priv=$R/tmp/banco
local_infile=0
performance_schema=OFF
max_connections=40
innodb_buffer_pool_size=128M
key_buffer_size=8M
table_open_cache=400
tmp_table_size=16M
max_heap_table_size=16M
[client]
port=$PortaBanco
"@ | Set-Content "$Raiz\config\my.ini" -Encoding ASCII

$exts = 'curl', 'fileinfo', 'mbstring', 'openssl', 'pdo_mysql', 'sodium', 'zip', 'intl', 'gd', 'exif'
@"
[PHP]
engine=On
expose_php=Off
display_errors=Off
display_startup_errors=Off
log_errors=On
error_log="$R/logs/web/php.log"
error_reporting=E_ALL & ~E_DEPRECATED
memory_limit=256M
max_execution_time=120
post_max_size=25M
upload_max_filesize=20M
max_file_uploads=20
allow_url_include=Off
enable_dl=Off
file_uploads=On
sys_temp_dir="$R/tmp/web"
upload_tmp_dir="$R/tmp/web"
session.save_path="$R/tmp/web"
session.cookie_httponly=1
session.use_strict_mode=1
date.timezone=America/Sao_Paulo
extension_dir="$R/php/ext"
$(($exts | ForEach-Object { "extension=$_" }) -join "`r`n")
zend_extension=opcache
opcache.enable=1
opcache.enable_cli=0
opcache.memory_consumption=96
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=20000
opcache.validate_timestamps=0
realpath_cache_size=4096K
realpath_cache_ttl=600
"@ | Set-Content "$Raiz\php\php.ini" -Encoding ASCII

$Ouvir = if ($Rede) { "0.0.0.0:$Porta" } else { "127.0.0.1:$Porta" }
@"
Define RAIZ "$R"
ServerRoot "`${RAIZ}/apache"
Listen $Ouvir
ServerName localhost
PidFile "`${RAIZ}/logs/web/httpd.pid"
LoadModule authz_core_module modules/mod_authz_core.so
LoadModule authz_host_module modules/mod_authz_host.so
LoadModule dir_module modules/mod_dir.so
LoadModule mime_module modules/mod_mime.so
LoadModule rewrite_module modules/mod_rewrite.so
LoadModule headers_module modules/mod_headers.so
LoadModule log_config_module modules/mod_log_config.so
LoadModule setenvif_module modules/mod_setenvif.so
LoadModule filter_module modules/mod_filter.so
LoadModule deflate_module modules/mod_deflate.so
LoadModule expires_module modules/mod_expires.so
LoadModule php_module "`${RAIZ}/php/php8apache2_4.dll"
PHPIniDir "`${RAIZ}/php"
AddHandler application/x-httpd-php .php
TypesConfig conf/mime.types

ThreadsPerChild 32
MaxConnectionsPerChild 0
KeepAlive On
KeepAliveTimeout 5
Timeout 120
ServerTokens Prod
ServerSignature Off
TraceEnable Off
FileETag None
LimitRequestBody 26214400
AcceptFilter http none
AcceptFilter https none
EnableSendfile Off
EnableMMAP Off

ErrorLog "`${RAIZ}/logs/web/erro.log"
LogLevel warn
LogFormat "%h %t \"%r\" %>s %b %D" curto
CustomLog "`${RAIZ}/logs/web/acesso.log" curto

<Directory />
  AllowOverride None
  Require all denied
</Directory>
DocumentRoot "`${RAIZ}/app/public"
<Directory "`${RAIZ}/app/public">
  Options -Indexes +FollowSymLinks
  AllowOverride None
  Require all granted
  DirectoryIndex index.php
  RewriteEngine On
  RewriteCond %{HTTP:Authorization} .
  RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
  RewriteCond %{REQUEST_FILENAME} !-d
  RewriteCond %{REQUEST_FILENAME} !-f
  RewriteRule ^ index.php [L]
</Directory>
<FilesMatch "^\.">
  Require all denied
</FilesMatch>
<IfModule mod_deflate.c>
  AddOutputFilterByType DEFLATE text/html text/css text/plain application/javascript application/json image/svg+xml
</IfModule>
<IfModule mod_expires.c>
  ExpiresActive On
  ExpiresByType text/css "access plus 7 days"
  ExpiresByType application/javascript "access plus 7 days"
  ExpiresByType image/png "access plus 30 days"
  ExpiresByType image/svg+xml "access plus 30 days"
</IfModule>
"@ | Set-Content "$Raiz\config\httpd.conf" -Encoding ASCII

# --- 6. servico do banco (conta virtual, so 127.0.0.1) -------------------------------------------------------------------
$NovoBanco = -not (Test-Path "$Raiz\dados\mysql")
if ($NovoBanco) {
  Passo 'Criando o banco de dados'
  $script:RootSenha = Senha 28; Set-Content $RootArq $script:RootSenha -Encoding ASCII -NoNewline
  Get-ChildItem "$Raiz\dados" -Force | Remove-Item -Recurse -Force
  $o = Exe "$Raiz\mariadb\bin\mariadb-install-db.exe" "--datadir=$Raiz\dados" "--password=$($script:RootSenha)" "--port=$PortaBanco"
  if ($script:Codigo) { Falha "mariadb-install-db falhou: $($script:Erro) $o" }
  Remove-Item "$Raiz\dados\my.ini" -ErrorAction SilentlyContinue
}
if (-not (Get-Service $SvcBanco -ErrorAction SilentlyContinue)) {
  New-Service $SvcBanco -BinaryPathName "`"$Raiz\mariadb\bin\mariadbd.exe`" --defaults-file=`"$Raiz\config\my.ini`" $SvcBanco" `
    -DisplayName 'SISVET - Banco de dados' -Description 'MariaDB do SISVET Web (somente 127.0.0.1)' -StartupType Automatic | Out-Null
}
ContaServico $SvcBanco
$SB = "NT SERVICE\$SvcBanco"
Icacls "$Raiz\dados" /grant "${SB}:(OI)(CI)M"
Icacls "$Raiz\logs\banco" /grant "${SB}:(OI)(CI)M"; Icacls "$Raiz\tmp\banco" /grant "${SB}:(OI)(CI)M"
Icacls "$Raiz\mariadb" /grant "${SB}:(OI)(CI)RX"; Icacls "$Raiz\config\my.ini" /grant "${SB}:R"
Start-Service $SvcBanco
$ok = $false; foreach ($i in 1..30) { $env:MYSQL_PWD = $script:RootSenha
  Exe "$Raiz\mariadb\bin\mariadb-admin.exe" -uroot --host=127.0.0.1 "-P$PortaBanco" ping | Out-Null; $ok = $script:Codigo -eq 0; Remove-Item Env:MYSQL_PWD
  if ($ok) { break }; Start-Sleep 1 }
if (-not $ok) { Falha "o banco nao respondeu; veja $Raiz\logs\banco\erro.log" }
if (-not $NovoBanco -and $RtNovo -ne $RtAtual) { $env:MYSQL_PWD = $script:RootSenha
  Exe "$Raiz\mariadb\bin\mariadb-upgrade.exe" -uroot --host=127.0.0.1 "-P$PortaBanco" | Out-Null; Remove-Item Env:MYSQL_PWD }

# --- 7. aplicacao --------------------------------------------------------------------------------------------------------
Passo "Instalando o SISVET $Versao"
$t = "$Raiz\tmp\app-nova"; if (Test-Path $t) { Remove-Item $t -Recurse -Force }
[IO.Compression.ZipFile]::ExtractToDirectory($ZipApp, $t)
if (Test-Path "$Raiz\app") {
  Copy-Item "$Raiz\app\.env" "$t\.env" -Force -ErrorAction SilentlyContinue
  if (Test-Path "$Raiz\app\storage\app") { Remove-Item "$t\storage\app" -Recurse -Force -ErrorAction SilentlyContinue; Copy-Item "$Raiz\app\storage\app" "$t\storage\app" -Recurse }
  if (Test-Path "$Raiz\backup\app-anterior") { Remove-Item "$Raiz\backup\app-anterior" -Recurse -Force }
  Move-Item "$Raiz\app" "$Raiz\backup\app-anterior"
}
Move-Item $t "$Raiz\app"

$NovaSenhaAdmin = $null
if (-not (Test-Path "$Raiz\app\.env")) {
  $chaveArq = "$Raiz\importar\APP_KEY.txt"
  $chave = if (Test-Path $chaveArq) { (Get-Content $chaveArq -Raw).Trim() } else { $k = New-Object byte[] 32; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($k); 'base64:' + [Convert]::ToBase64String($k) }
  if ($chave -notmatch '^base64:') { Falha 'APP_KEY.txt deve conter a linha base64:... do .env de origem.' }
  $SenhaApp = Senha 28
  Banco "CREATE DATABASE IF NOT EXISTS sisvet CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    CREATE USER IF NOT EXISTS 'sisvet'@'127.0.0.1' IDENTIFIED BY '$SenhaApp'; ALTER USER 'sisvet'@'127.0.0.1' IDENTIFIED BY '$SenhaApp';
    GRANT ALL PRIVILEGES ON sisvet.* TO 'sisvet'@'127.0.0.1'; FLUSH PRIVILEGES;" | Out-Null
  $v = [ordered]@{ APP_ENV = 'production'; APP_DEBUG = 'false'; APP_KEY = $chave; APP_URL = "http://127.0.0.1:$Porta"; LOG_LEVEL = 'warning'
    DB_HOST = '127.0.0.1'; DB_PORT = "$PortaBanco"; DB_DATABASE = 'sisvet'; DB_USERNAME = 'sisvet'; DB_PASSWORD = $SenhaApp
    SESSION_SECURE_COOKIE = 'false'; SISVET_ADMIN_PASSWORD = '' }
  $linhas = Get-Content "$Raiz\app\.env.example" -Encoding UTF8 | ForEach-Object { $k = ($_ -split '=', 2)[0]; if ($v.Contains($k)) { "$k=$($v[$k])"; $v.Remove($k) } else { $_ } }
  $linhas += $v.Keys | ForEach-Object { "$_=$($v[$_])" }
  [IO.File]::WriteAllLines("$Raiz\app\.env", [string[]]$linhas, (New-Object Text.UTF8Encoding $false))   # sem BOM
}
$SW = "NT SERVICE\$SvcWeb"

# banco vazio: importa o dump de C:\sisvet\importar ou cria do zero
$tabelas = [int](Banco "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='sisvet'")
if ($tabelas -eq 0) {
  $dump = Get-ChildItem "$Raiz\importar" -File | Where-Object { $_.Name -match '\.sql(\.gz)?$' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($dump) {
    Passo "Importando o banco $($dump.Name)"
    $sql = "$Raiz\tmp\importar.sql"
    if ($dump.Extension -eq '.gz') { Gz2Sql $dump.FullName $sql } else { Copy-Item $dump.FullName $sql }
    $env:MYSQL_PWD = $script:RootSenha
    & cmd.exe /c "`"$Raiz\mariadb\bin\mariadb.exe`" -uroot --host=127.0.0.1 -P$PortaBanco --default-character-set=utf8mb4 sisvet < `"$sql`""
    $ok = $LASTEXITCODE; Remove-Item Env:MYSQL_PWD; Remove-Item $sql
    if ($ok) { Falha 'a importacao do banco falhou.' }
    Move-Item $dump.FullName "$Raiz\backup\importado-$(Get-Date -f yyyyMMdd-HHmmss)-$($dump.Name)"
    Remove-Item "$Raiz\importar\APP_KEY.txt" -ErrorAction SilentlyContinue   # ja esta no .env
  } else { Passo 'Criando as tabelas (banco novo, sem dados)' }
  $NovaSenhaAdmin = Senha 14
}
Artisan migrate --force
if ($NovaSenhaAdmin) {
  # admin com senha aleatoria (mostrada uma vez); demais usuarios ficam como vieram
  @'
<?php
require __DIR__.'/../app/vendor/autoload.php';
$app = require __DIR__.'/../app/bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
App\Models\User::updateOrCreate(['login' => 'admin'], ['name' => 'Administrador', 'email' => 'admin@sisvet.local',
    'password' => getenv('SISVET_SENHA_ADMIN'), 'perfil' => 'admin', 'ativo' => true]);
'@ | Set-Content "$Raiz\tmp\admin.php" -Encoding ASCII
  $env:SISVET_SENHA_ADMIN = $NovaSenhaAdmin; & "$Raiz\php\php.exe" "$Raiz\tmp\admin.php"; $ok = $LASTEXITCODE
  Remove-Item Env:SISVET_SENHA_ADMIN; Remove-Item "$Raiz\tmp\admin.php"; if ($ok) { Falha 'nao foi possivel definir a senha do admin.' }
  @"
SISVET Web - acesso inicial ($(Get-Date -f 'dd/MM/yyyy HH:mm'))
Endereco: http://127.0.0.1:$Porta
Usuario:  admin
Senha:    $NovaSenhaAdmin
Troque a senha em Administracao > Usuarios e apague este arquivo.
"@ | Set-Content "$Raiz\config\ACESSO.txt" -Encoding ASCII
}
Artisan config:cache; Artisan route:cache; Artisan view:cache

# --- 8. servico web (Apache + PHP, conta virtual) -----------------------------------------------------------------------
Passo 'Configurando o servidor web'
if (-not (Get-Service $SvcWeb -ErrorAction SilentlyContinue)) {
  Exe "$Raiz\apache\bin\httpd.exe" -k install -n $SvcWeb -f "$Raiz\config\httpd.conf" | Out-Null
  if (-not (Get-Service $SvcWeb -ErrorAction SilentlyContinue)) { Falha 'nao foi possivel criar o servico web.' }
  & sc.exe config $SvcWeb DisplayName= 'SISVET - Servidor web' start= auto | Out-Null
  & sc.exe description $SvcWeb 'Apache + PHP do SISVET Web' | Out-Null
}
ContaServico $SvcWeb
Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$SvcWeb\Parameters" -Name ConfigArgs -Type MultiString `
  -Value @('-f', "$Raiz\config\httpd.conf", '-E', "$Raiz\logs\web\inicio.log")   # -E: erros de partida do Apache
# o Apache so acha as DLLs do PHP (libcrypto, nghttp2...) com a pasta do PHP no PATH: ambiente proprio do servico, sem mexer no PATH do Windows
New-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$SvcWeb" -Name Environment -PropertyType MultiString -Force `
  -Value @("PATH=$Raiz\php;$env:SystemRoot\System32;$env:SystemRoot", "TEMP=$Raiz\tmp\web", "TMP=$Raiz\tmp\web") | Out-Null
foreach ($d in 'app', 'php', 'apache') { Icacls "$Raiz\$d" /grant "${SW}:(OI)(CI)RX" }
foreach ($d in 'app\storage', 'app\bootstrap\cache', 'logs\web', 'tmp\web') { Icacls "$Raiz\$d" /grant "${SW}:(OI)(CI)M" }
Icacls "$Raiz\config\httpd.conf" /grant "${SW}:R"
# o Apache resolve o nome real de cada caminho e precisa listar as pastas-pai (so a pasta, sem herdar para o conteudo)
foreach ($d in '', '\config', '\logs', '\tmp') { Icacls "$Raiz$d" /grant "${SW}:(RX)" }
$t = Exe "$Raiz\apache\bin\httpd.exe" -t -f "$Raiz\config\httpd.conf"; if ($script:Codigo) { Falha "configuracao do Apache: $($script:Erro) $t" }
Start-Service $SvcWeb

# firewall: so abre na rede privada quando pedido
Get-NetFirewallRule -DisplayName 'SISVET Web' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
if ($Rede) { New-NetFirewallRule -DisplayName 'SISVET Web' -Direction Inbound -Protocol TCP -LocalPort $Porta -Action Allow -Profile Private, Domain `
  -Program "$Raiz\apache\bin\httpd.exe" | Out-Null }

# --- 9. backup diario, atalhos ---------------------------------------------------------------------------------------------
@'
# Backup diario do SISVET (tarefa agendada "SISVET - Backup"); guarda os ultimos 30 em C:\sisvet\backup
$ErrorActionPreference = 'Stop'; $R = 'C:\sisvet'
$env:MYSQL_PWD = (Get-Content "$R\config\banco-root.txt" -Raw).Trim()
$sql = "$R\tmp\backup.sql"; $gz = "$R\backup\sisvet-$(Get-Date -f yyyyMMdd-HHmmss).sql.gz"
& "$R\mariadb\bin\mariadb-dump.exe" -uroot --host=127.0.0.1 -P3307 --single-transaction --routines --triggers --default-character-set=utf8mb4 "--result-file=$sql" sisvet
if ($LASTEXITCODE) { throw 'mariadb-dump falhou' }
$i = [IO.File]::OpenRead($sql); $o = [IO.File]::Create($gz); $z = New-Object IO.Compression.GZipStream($o, [IO.Compression.CompressionLevel]::Optimal)
$i.CopyTo($z); $z.Close(); $o.Close(); $i.Close(); Remove-Item $sql
Get-ChildItem "$R\backup\sisvet-2*.sql.gz" | Sort-Object Name -Descending | Select-Object -Skip 30 | Remove-Item
'@ | Set-Content "$Raiz\backup.ps1" -Encoding ASCII
$acao = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$Raiz\backup.ps1`""
Register-ScheduledTask -TaskName 'SISVET - Backup' -Action $acao -Trigger (New-ScheduledTaskTrigger -Daily -At '12:30') `
  -Principal (New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest) `
  -Settings (New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit '01:00:00') -Force | Out-Null

$cmdAtual = "irm https://raw.githubusercontent.com/$Repo/main/instalar.ps1 | iex"
"@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -Command `"Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -NoExit -Command $cmdAtual'`"" |
  Set-Content "$Raiz\ATUALIZAR.cmd" -Encoding ASCII
"@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -Command `"Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -NoExit -File $Raiz\backup.ps1'`"" |
  Set-Content "$Raiz\BACKUP-AGORA.cmd" -Encoding ASCII
"[InternetShortcut]`r`nURL=http://127.0.0.1:$Porta/`r`n" | Set-Content "$env:PUBLIC\Desktop\SISVET.url" -Encoding ASCII

# --- 10. conferencia final ---------------------------------------------------------------------------------------------
$ok = $false; foreach ($i in 1..20) { try { $r = Invoke-WebRequest "http://127.0.0.1:$Porta/login" -UseBasicParsing -TimeoutSec 10; $ok = $r.StatusCode -eq 200; if ($ok) { break } } catch { Start-Sleep 1 } }
if (-not $ok) { Falha "o SISVET nao respondeu em http://127.0.0.1:$Porta (veja $Raiz\logs\web\erro.log e $Raiz\app\storage\logs)" }
Remove-Item "$Raiz\tmp\runtime", "$Raiz\tmp\app-nova" -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`nSISVET $Versao funcionando em http://127.0.0.1:$Porta" -ForegroundColor Green
if ($Rede) { Write-Host "Outros computadores da rede: http://$($env:COMPUTERNAME):$Porta" }
if ($NovaSenhaAdmin) {
  Write-Host "`nUsuario: admin    Senha: $NovaSenhaAdmin" -ForegroundColor Yellow
  Write-Host "Anote e troque a senha no primeiro acesso (copia em $Raiz\config\ACESSO.txt, so administradores leem)."
}
Write-Host "Servicos: $SvcBanco e $SvcWeb (iniciam com o Windows). Backup diario 12:30 em $Raiz\backup. Atualizar: $Raiz\ATUALIZAR.cmd"
}
