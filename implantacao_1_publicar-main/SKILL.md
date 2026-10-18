---
name: implantacao-publicar-main
description: Atualiza a branch main a partir da develop nos repositórios 4clinics_backend e 4clinics_app do GitHub, com pull request, CI verde, merge sem squash e tag de versão igual nos dois. Use na fase 1 da implantação e em toda atualização (B3) antes de publicar. Pode ser executada pelo Claude Code (gh/git) ou pelo Claude no Chrome (GitHub aberto e logado); o merge e a tag só com o "sim" do responsável.
---

# Publicar a `main` (develop → main) nos dois repositórios

Repositórios: `D:\git\4clinics\4clinics_backend` e `D:\git\4clinics\4clinics_app` (GitHub: `gian-setta-gti/4clinics_backend` e `gian-setta-gti/4clinics_app`).
Em 16/10/2026: `develop` à frente da `main` por 33 (back) e 46 (app) commits; a `main` não tem nada que a `develop` não tenha → o merge não tem conflito.

## Pré-condições
- Fase 0 do plano fechada (ao menos: suítes verdes e ensaio do banco aprovado).
- Responsável com 2FA no GitHub; a **proteção da `main`** (exigir PR e CI verde) é configuração de segurança: quem liga é o responsável (Settings → Branches), e a skill só confere.

## Passos (por repositório; repetir nos dois)

1. **Conferir o estado** (Claude Code):
   ```bash
   git -C <repo> fetch --all --prune
   git -C <repo> status --short                       # vazio
   git -C <repo> rev-parse develop origin/develop      # iguais
   git -C <repo> rev-list --left-right --count origin/main...origin/develop   # esperado "0 N": main não tem nada a mais
   ```
   Se `main` tiver commit que a `develop` não tem (primeiro número > 0): **parar** e decidir com o responsável (integrar na `develop` primeiro).
2. **Testar local** (Claude Code): back `npx jest` + `npm run banco:ensaio`; front `CI=true npx react-scripts test --watchAll=false` e `REACT_APP_HOST_API=https://api.exemplo.com.br npm run build:pages` (o endereço é só para o teste do build).
3. **Abrir o PR** `develop` → `main` com o corpo do checklist (`gh pr create --base main --head develop --title "Release vAAAA.MM.DD-N" --body-file <arquivo>`), ou pelo GitHub (Chrome).
4. **Esperar o CI** (`gh pr checks <n> --watch`). Primeira execução real do CI: se falhar, **corrigir na `develop`** (não no PR da `main`), repetir. O CI do back audita produção e roda os testes sem banco; o do front audita (crítica), testa e faz o build.
5. **Pedir o "sim"** do responsável com o resumo: repositório, número do PR, commits, CI verde, o que muda em produção.
6. **Merge sem squash** (mantém o histórico): `gh pr merge <n> --merge`, ou botão "Create a merge commit".
7. **Tag** nos dois repositórios, **mesmo nome**: `vAAAA.MM.DD-N` (ex.: `v2026.10.16-1`).
   ```bash
   git -C <repo> fetch origin && git -C <repo> tag -a v2026.10.16-1 origin/main -m "Release v2026.10.16-1" && git -C <repo> push origin v2026.10.16-1
   ```
8. **Conferir:** `git rev-parse origin/main origin/develop` iguais (ou `main` à frente só pelo commit de merge), CI da `main` verde, tag listada em `git ls-remote --tags origin`.
9. **Registrar:** tag, hash de cada repositório, data, quem.

## Na trilha B (atualização): ordem do merge
O Cloudflare Pages publica a `main` do app **no momento do merge**. Na atualização, fazer o merge do **back** primeiro (passo B3 de `implantacao_0b_orq_atualizar`), atualizar a VPS (B4) e **só depois** o merge do **app** (B5). Na implantação inicial (trilha A) a ordem não importa: a API ainda não está no ar.
Sem o `gh` na máquina: PR, checks e merge pelo GitHub no Chrome (o merge e a tag com o "sim"); tag por `git tag -a` + `git push origin <tag>` no Claude Code.

## O que o Claude no Chrome faz e não faz
- Faz: abrir a página do PR, ler o estado dos checks, abrir os logs de falha e resumir, abrir a página de tags/releases para conferir, tirar captura.
- **Não** liga a proteção da branch (configuração de segurança) e **não clica em "Merge" nem cria a tag sem o "sim" do responsável no chat**, naquele momento. Não digita senha nem token; não autoriza aplicativos do GitHub por conta própria.

**Prompt para o Claude no Chrome:**
> Abra o repositório `gian-setta-gti/<REPO>` no GitHub (já estou logado). Abra a lista de pull requests e encontre o PR de `develop` para `main`. Leia e me diga: título, número de commits, se todos os checks estão verdes (liste cada check) e se há conflito. **Não clique em Merge.** Se algum check falhou, abra o log, resuma o motivo em 3 linhas e pare. Depois que eu disser "pode fazer o merge" no chat, use "Create a merge commit" (não squash) e me confirme o resultado.

## Rollback
- Merge errado: **PR de reversão** (`git revert -m 1 <merge>` na `main` via PR). Não reescrever a `main` (sem `push --force`).
- Tag publicada não se apaga: cria-se a seguinte (`...-2`) e registra-se o motivo.

## Relato
Por repositório: PR (link), commits incluídos, resultado do CI (cada check), hash da `main`, tag, e o que **não** foi conferido (ex.: proteção da `main` ligada pelo responsável: conferida/pendente).
