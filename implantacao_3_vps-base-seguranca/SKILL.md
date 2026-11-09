---
name: implantacao-vps-base-seguranca
description: Prepara e endurece a VPS HostGator (Ubuntu 22.04, São Paulo) para receber o 4clinics — atualizações automáticas, fuso, usuário administrador, SSH só por chave, fail2ban, firewall ufw com a 443 liberada só para o Cloudflare e 80/3306/8010 fechadas. Use na fase 3a da implantação. O administrador executa os comandos por SSH e cola as saídas; Claude orienta, confere as saídas e verifica as portas de fora. Não altera a VPS por conta própria.
---

# VPS: base e segurança (fase 3a)

Referência: `D:\git\4clinics\4clinics_backend\docs\checklist-implantacao.md` §2 e `deploy/ufw-cloudflare.sh`.
**Modo de trabalho:** um bloco por vez. O administrador roda, cola a saída; Claude confere contra o "esperado" e só então passa ao próximo bloco.
Claude **não** pede senha nem chave privada, e não roda nada na VPS.

## Cuidado que evita ficar trancado para fora
Mudanças de SSH e firewall podem cortar o acesso. **Mantenha uma segunda sessão SSH aberta** durante os blocos 3 e 4, e só feche depois de testar o login novo numa terceira janela.
O painel da HostGator costuma ter um **console de emergência** (acesso pelo navegador): confirmar onde fica **antes** de começar.

## Bloco 1 — sistema atualizado, fuso e atualizações automáticas
```bash
sudo apt update && sudo apt -y full-upgrade
sudo apt -y install unattended-upgrades fail2ban ufw curl gnupg ca-certificates git
sudo dpkg-reconfigure -plow unattended-upgrades          # responder "Sim"
sudo timedatectl set-timezone America/Sao_Paulo
timedatectl | grep -E "Time zone|synchronized"
lsb_release -ds
```
Esperado: `America/Sao_Paulo`, `System clock synchronized: yes`, `Ubuntu 22.04.x LTS`. Reiniciar se o `full-upgrade` pedir (`sudo reboot`).

## Bloco 2 — usuário administrador (se o acesso inicial for root)
```bash
sudo adduser <admin>                     # senha forte, guardada no cofre do responsável
sudo usermod -aG sudo <admin>
sudo install -d -m 700 -o <admin> -g <admin> /home/<admin>/.ssh
sudo nano /home/<admin>/.ssh/authorized_keys   # colar a CHAVE PÚBLICA (id_ed25519.pub) do administrador
sudo chown <admin>:<admin> /home/<admin>/.ssh/authorized_keys && sudo chmod 600 /home/<admin>/.ssh/authorized_keys
```
Testar em **outra janela**: `ssh <admin>@<IP>` e `sudo -v`. Só seguir se funcionar.

## Bloco 3 — SSH só por chave
Arquivo `/etc/ssh/sshd_config.d/10-4clinics.conf`:
```
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowUsers <admin>
```
```bash
sudo sshd -t && sudo systemctl reload ssh
sudo sshd -T | grep -E "permitrootlogin|passwordauthentication|allowusers"
```
Esperado: `permitrootlogin no`, `passwordauthentication no`, `allowusers <admin>`. Testar login numa **nova** janela antes de fechar as outras.

## Bloco 4 — firewall (ordem segura)
```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from <IP-do-administrador> to any port 22 proto tcp     # ou, se o IP muda: sudo ufw limit 22/tcp
sudo bash deploy/ufw-cloudflare.sh                                     # do repositório da API (fase 3c) — ou copie o script antes
sudo ufw enable
sudo ufw status verbose
systemctl is-enabled ufw        # esperado: enabled (senão o firewall NÃO volta sozinho depois de um reinício da VPS)
# se vier "disabled": sudo systemctl enable ufw   (não muda as regras em uso; visto na VPS em 06/11/2026: ufw ativo mas ufw.service disabled)
```
Esperado: 22 só do IP (ou `LIMIT`), 443 só para as faixas do Cloudflare (comentário `cloudflare`), **nada** em 80, 3306 e 8010. O script só acrescenta regras; rodar de novo todo mês.

## Bloco 5 — fail2ban e conferências finais
```bash
sudo systemctl enable --now fail2ban && sudo fail2ban-client status sshd
sudo aa-status | head -3
sudo ss -tlnp
```
Esperado: jail `sshd` ativa; AppArmor carregado; em `ss -tlnp` só `:22` em todas as interfaces (443 aparece depois do nginx; 3306 e 8010 só em `127.0.0.1`).

## Bloco 6 — swap comprimido em memória (zram), sem disco
Por quê: a VPS tem ~4 GB de RAM e **nenhum swap**; sem ele, uma falta de memória faz o Linux encerrar à força o MySQL ou a API. Por que **zram** e não arquivo de swap: o zram fica só na RAM; um swap em disco gravaria páginas de memória em claro (dados de paciente e a chave mestra do MySQL), enfraquecendo a criptografia em repouso. Só roda em VM completa (KVM) com o módulo `zram` no kernel: conferir antes (`systemd-detect-virt` = `kvm`; `modinfo zram`). Medido na VPS em 06/11/2026: KVM, kernel 6.8.0-138, módulo presente, 0 encerramentos por falta de memória em 30 dias.
```bash
sudo apt -y install systemd-zram-generator
D=/opt/4clinics/api/deploy
sudo install -m 644 -o root -g root $D/zram-generator.conf /etc/systemd/zram-generator.conf
sudo install -m 644 -o root -g root $D/sysctl-zram.conf /etc/sysctl.d/99-zram.conf
sudo systemctl daemon-reload && sudo systemctl start systemd-zram-setup@zram0.service && sudo sysctl --system >/dev/null
swapon --show; zramctl; free -m; sysctl vm.swappiness vm.page-cluster
```
**Atenção:** o pacote do Ubuntu 22.04 (0.3.2) não conhece `zram-size`, só `zram-fraction` (sem ela o padrão é metade da RAM: 1,9 GB na VPS); o arquivo do repositório já usa `zram-fraction = 0.25`. Para trocar o tamanho depois: `sudo systemctl stop dev-zram0.swap systemd-zram-setup@zram0.service`, editar o arquivo, `sudo systemctl daemon-reload && sudo systemctl start dev-zram0.swap`. O `sysctl --system` pode avisar `Invalid argument` em chaves `net.ipv4.conf.all.*` de outros arquivos: é de antes e não afeta o zram.
Esperado: `swapon --show` lista `/dev/zram0` (~980M, prioridade 100); `zramctl` mostra `zstd`; `Swap:` do `free -m` com ~980; swappiness 30 e page-cluster 0. Depois de **reiniciar a VPS** (só quando o responsável decidir), `swapon --show` deve listar o zram sozinho.
**Volta atrás:** `sudo swapoff /dev/zram0 && sudo apt -y remove systemd-zram-generator && sudo rm -f /etc/systemd/zram-generator.conf /etc/sysctl.d/99-zram.conf && sudo sysctl vm.swappiness=60 vm.page-cluster=3`.
**Acompanhar:** `zramctl` (coluna `DATA` vs `COMPR`) e `free -m`. Uso constante de swap (> ~300 MB) = a RAM ficou pequena: avaliar mais memória no plano, não mais swap.

## Conferência de fora (Claude Code, da máquina do responsável)
```bash
nc -zv -w 5 <IP> 22        # aberto só se o IP de quem testa estiver liberado
nc -zv -w 5 <IP> 3306      # deve FALHAR
nc -zv -w 5 <IP> 8010      # deve FALHAR
nc -zv -w 5 <IP> 80        # deve FALHAR
```

## Volta atrás
Trancado para fora: console de emergência do painel → `sudo ufw disable` ou corrigir `/etc/ssh/sshd_config.d/10-4clinics.conf` e `sudo systemctl reload ssh`.

## Ajustes do primeiro uso (17/10/2026, VPS HostGator, Ubuntu 22.04.5)
- **O SSH da HostGator já vem na porta 22022**, entrando como `root`. Conferir com `sudo ss -tlnp` antes do bloco 4 e usar `ufw limit 22022/tcp` (não a 22). O `fail2ban` precisa do `port = 22022` em `/etc/fail2ban/jail.d/4clinics-sshd.conf` (`backend = systemd`).
- IP do administrador dinâmico: `ufw limit 22022/tcp` (acesso só por chave + fail2ban); o console de emergência do painel é o plano B (testar o login nele **antes** de começar).
- Usuário `admin4clinics` criado com `adduser --disabled-password`, chave pública própria para a VPS (`id_ed25519_4clinics_vps`) e `NOPASSWD` em `/etc/sudoers.d/90-admin4clinics`.
- Testar o sudo com `sudo whoami`, **não** `sudo -v` (o `-v` ignora o NOPASSWD e pede senha).
- Incluir `127.0.1.1 <hostname>` no `/etc/hosts` se o sudo avisar `unable to resolve host`.
- Atualizações automáticas sem menu: gravar `/etc/apt/apt.conf.d/20auto-upgrades` direto.
- O `scp` usa `-P` maiúsculo para a porta; o script `deploy/ufw-cloudflare.sh` foi enviado por `scp` (o repositório só é clonado na fase 3c).
- Cuidado de quem usa Windows: os comandos de chave e `scp` rodam no CMD do Windows, não na sessão SSH da VPS.

## Relato
Saídas coladas de cada bloco (sem segredos), o que bateu com o esperado, o resultado do `nc` de fora, e pendências (ex.: IP do administrador muda → decidir `ufw limit`).
