# SISVET Web — instalador para Windows

Sistema veterinário SISVET Web rodando no próprio computador (Windows 10/11 64 bits), sem Docker: tudo em `C:\sisvet`.
Este repositório só distribui o **instalador** e os **pacotes** de cada versão (aba *Releases*). Nenhum dado de cliente fica aqui.

## Instalar (ou atualizar)

Abra o **PowerShell como administrador** (menu Iniciar → *PowerShell* → botão direito → *Executar como administrador*) e cole:

```powershell
irm https://raw.githubusercontent.com/jefersonrte/sisvet-instalador/main/instalar.ps1 | iex
```

O instalador:
1. baixa daqui a última versão e confere cada arquivo pelo **SHA-256** publicado na release;
2. instala o Visual C++ da Microsoft se faltar (assinatura conferida);
3. monta PHP 8.4 + Apache 2.4 + MariaDB 11.4 em `C:\sisvet` como dois serviços que sobem com o Windows:
   **SISVET-Banco** e **SISVET-Web**, cada um na sua conta virtual (`NT SERVICE\...`), com acesso só às pastas que usa;
4. banco e site escutam **só em 127.0.0.1** (porta 3307 e 8090); a pasta `C:\sisvet` fica restrita a administradores;
5. cria o atalho **SISVET** na área de trabalho, backup diário às 12:30 em `C:\sisvet\backup` (últimos 30) e mostra a senha inicial do `admin` uma vez.

## Atualizar

```powershell
irm https://raw.githubusercontent.com/jefersonrte/sisvet-instalador/main/atualizar.ps1 | iex
```

Ou dê duplo clique em `C:\sisvet\ATUALIZAR.cmd`. O comando compara a versão instalada com a última publicada e só atualiza quando há uma nova. Antes, guarda uma cópia do banco e mantém os dados, a porta e a opção de rede. Com `$env:SISVET_FORCAR = '1'` ele reinstala na mesma versão.

## Levar um banco existente

Antes de instalar, crie `C:\sisvet\importar\` e coloque:
- o dump do banco (`*.sql` ou `*.sql.gz`, gerado com `mysqldump`/`mariadb-dump`);
- `APP_KEY.txt` com a linha `base64:...` do `.env` de origem (sem ela os CPF/RG criptografados não abrem).

O dump só é importado quando o banco ainda está vazio; depois vai para `C:\sisvet\backup` e a chave é apagada da pasta.

## Opções (antes do comando)

```powershell
$env:SISVET_PORTA = '8090'   # outra porta para o site
$env:SISVET_REDE  = '1'      # libera o site para outros PCs da rede privada (regra de firewall só para perfis Privado/Domínio); '0' fecha
```
As opções ficam gravadas em `C:\sisvet\config\opcoes.txt` e valem nas próximas atualizações.

## Recursos

~200 MB de memória com o sistema parado (Apache ~80 MB, MariaDB ~125 MB), ~500 MB em disco mais o banco.

## Desinstalar

```powershell
irm https://raw.githubusercontent.com/jefersonrte/sisvet-instalador/main/desinstalar.ps1 | iex
```
Faz um último backup e remove tudo, menos `C:\sisvet\backup`.
