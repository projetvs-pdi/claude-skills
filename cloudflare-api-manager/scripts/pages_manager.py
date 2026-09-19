#!/usr/bin/env python3
"""
pages_manager.py — cria projetos do Cloudflare Pages conectados a um
repositório Git (GitHub ou GitLab), lista projetos existentes e consulta o
status da implantação (build) mais recente.

Equivalente automatizado do fluxo manual pelo painel: Workers e Pages >
Criar aplicativo > "Importar um repositório Git existente" > selecionar o
repositório > configurar build > "Salvar e implantar".

## Pré-requisito que NÃO dá para automatizar: conectar o GitHub/GitLab

Antes deste script funcionar, a CONTA Cloudflare precisa ter o GitHub (ou
GitLab) conectado como integração pelo menos uma vez. Isso é uma tela de
autorização OAuth do GitHub/GitLab — não existe endpoint de API para
"aceitar" esse consentimento por você, então é o único passo desta skill que
continua sendo manual, uma única vez por conta:

  1. Acesse https://dash.cloudflare.com/<ACCOUNT_ID>/workers-and-pages/create/pages
  2. "Importar um repositório Git existente" > aba GitHub (ou GitLab) >
     botão "Conectar o GitHub" (ou "Conectar o GitLab").
  3. Autorize o app "Cloudflare Pages" a acessar a organização/conta dona do
     repositório (dá pra restringir a repositórios específicos).

Depois desse passo único, criar quantos projetos quiser vira 100%
automatizável por este script — a Cloudflare já "lembra" da conexão para
qualquer repositório autorizado, e criar/listar/checar status são chamadas
de API normais.

## Sobre o comando de build e o diretório de saída

Cada framework tem um comando de build e uma pasta de saída diferentes (ex.
Vite gera em `dist/`, Create React App em `build/`, Hugo em `public/`).
`FRAMEWORK_PRESETS` abaixo cobre os casos mais comuns como atalho — mas
SEMPRE confirme com quem mantém o repositório antes de assumir um preset,
porque configurações customizadas (ex. `vite.config.js` com `outDir`
diferente) quebram esse valor padrão. Quando não tiver certeza, prefira
perguntar a adivinhar.

Autenticação: por padrão usa CLOUDFLARE_ZONE_TOKEN — o token de projeto
criado com `token_manager.py criar` (preset "dns-pages" já inclui
"Cloudflare Pages Write" no nível de conta). Pages é um recurso de CONTA, não
de zona, mas reaproveitamos o mesmo token do projeto em vez de exigir mais um
token separado só para isso. Use --var-ambiente para apontar para outra
variável, se preferir.

Exemplos:

  # Criar um projeto conectado a um repositório GitHub, com preset de framework:
  python pages_manager.py criar --projeto amazonasterapia-com-br \\
      --owner projetvs-pdi --repo amazonasterapia.com.br --branch main \\
      --framework react-vite

  # Informando build/diretório manualmente (quando nenhum preset serve):
  python pages_manager.py criar --projeto meu-site --owner minha-org --repo meu-repo \\
      --comando-build "npm run build" --diretorio-saida dist

  # Listar projetos existentes:
  python pages_manager.py listar

  # Ver a implantação mais recente (status do build/deploy):
  python pages_manager.py status --projeto amazonasterapia-com-br
"""

import argparse
import sys

from cf_api import CredencialAusente, chamar_api, imprimir_resultado

ZONE_VAR = "CLOUDFLARE_ZONE_TOKEN"
ACCOUNT_VAR = "CLOUDFLARE_ACCOUNT_ID"

# Atalhos (comando de build, diretório de saída) para os frameworks mais
# comuns — espelha o dropdown "Predefinição da estrutura" do próprio painel
# da Cloudflare. Sempre confirme com o dono do projeto antes de usar às
# cegas; --comando-build/--diretorio-saida sempre têm prioridade sobre isto.
FRAMEWORK_PRESETS = {
    "nenhum": ("", ""),
    "react-vite": ("npm run build", "dist"),
    "react-cra": ("npm run build", "build"),
    "vue": ("npm run build", "dist"),
    "next-static": ("npm run build", "out"),
    "nuxt": ("npm run generate", "dist"),
    "sveltekit": ("npm run build", "build"),
    "angular": ("npm run build", "dist"),
    "hugo": ("hugo", "public"),
    "jekyll": ("jekyll build", "_site"),
    "gatsby": ("npm run build", "public"),
    "astro": ("npm run build", "dist"),
}


def _projeto_nao_encontrado(mensagem: str) -> bool:
    m = mensagem.lower()
    return "not_found" in m or "not found" in m


def _projeto_existe(nome: str, account_id: str, var_ambiente: str):
    """True/False, ou None quando não dá para saber (modo dry-run)."""
    try:
        resp = chamar_api(
            "GET", f"/accounts/{account_id}/pages/projects/{nome}", var_ambiente,
            dry_run_label=f"Checar se o projeto Pages '{nome}' já existe",
        )
    except RuntimeError as e:
        if _projeto_nao_encontrado(str(e)):
            return False
        raise
    if resp["dry_run"]:
        return None
    return True


def criar(args):
    account_id = args.account_id

    if args.framework:
        comando_padrao, diretorio_padrao = FRAMEWORK_PRESETS[args.framework]
    else:
        comando_padrao, diretorio_padrao = "", ""
    comando = args.comando_build if args.comando_build is not None else comando_padrao
    diretorio = args.diretorio_saida if args.diretorio_saida is not None else diretorio_padrao

    existe = _projeto_existe(args.projeto, account_id, args.var_ambiente)
    if existe:
        print(
            f"\nProjeto '{args.projeto}' já existe — nada a fazer (idempotente). "
            f"Use 'python pages_manager.py status --projeto {args.projeto}' para ver "
            "a última implantação, ou provisionar_dominio.py para conectar um domínio."
        )
        return
    if existe is None:
        print(f"[DRY-RUN] não dá para checar se '{args.projeto}' já existe sem credencial — simulando a criação.")

    body = {
        "name": args.projeto,
        "production_branch": args.branch,
        "build_config": {
            "build_command": comando,
            "destination_dir": diretorio,
            "root_dir": args.diretorio_raiz or "",
        },
        "source": {
            "type": args.provider,
            "config": {
                "owner": args.owner,
                "repo_name": args.repo,
                "production_branch": args.branch,
                "pr_comments_enabled": True,
                "deployments_enabled": True,
                "production_deployment_enabled": True,
            },
        },
    }
    resp = chamar_api(
        "POST", f"/accounts/{account_id}/pages/projects", args.var_ambiente, body=body,
        dry_run_label=f"Criar projeto Pages '{args.projeto}' a partir de {args.provider}:{args.owner}/{args.repo}",
    )
    imprimir_resultado(resp, f"Projeto Pages criado — {args.projeto}")
    if not resp["dry_run"]:
        print(f"\nSite publicado em: https://{args.projeto}.pages.dev")
        print(
            "Próximo passo, se houver domínio próprio: "
            f"python provisionar_dominio.py verificar-e-aplicar --dominio <seu-dominio> "
            f"--projeto-pages {args.projeto}"
        )
    else:
        print(
            "\nLembrete: isto só funciona de verdade se o GitHub/GitLab já estiver "
            "conectado à conta (ver docstring deste script, seção 'Pré-requisito')."
        )


def listar(args):
    resp = chamar_api(
        "GET", f"/accounts/{args.account_id}/pages/projects", args.var_ambiente,
        dry_run_label="Listar projetos do Cloudflare Pages",
    )
    imprimir_resultado(resp, "Projetos Cloudflare Pages")


def status(args):
    resp = chamar_api(
        "GET", f"/accounts/{args.account_id}/pages/projects/{args.projeto}/deployments",
        args.var_ambiente, query={"per_page": 1},
        dry_run_label=f"Ver a implantação mais recente de '{args.projeto}'",
    )
    imprimir_resultado(resp, f"Implantações — {args.projeto}")
    if not resp["dry_run"] and resp["result"]:
        ultima = resp["result"][0]
        estagio = ultima.get("latest_stage") or {}
        print(f"\nÚltima implantação: {ultima.get('id')}")
        print(f"  Etapa: {estagio.get('name')} — status: {estagio.get('status')}")
        print(f"  URL: {ultima.get('url')}")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--var-ambiente", dest="var_ambiente", default=ZONE_VAR,
                    help=f"Nome da variável de ambiente com o token a usar (padrão: {ZONE_VAR})")
    p.add_argument("--account-id", default=None, help=f"Se omitido, lê de {ACCOUNT_VAR}")
    sub = p.add_subparsers(dest="comando", required=True)

    pc = sub.add_parser("criar", help="Cria um projeto Pages conectado a um repositório Git")
    pc.add_argument("--projeto", required=True, help="Nome do projeto (vira <nome>.pages.dev)")
    pc.add_argument("--owner", required=True, help="Dono/organização do repositório no GitHub/GitLab")
    pc.add_argument("--repo", required=True, help="Nome do repositório")
    pc.add_argument("--branch", default="main", help="Branch de produção (padrão: main)")
    pc.add_argument("--provider", choices=["github", "gitlab"], default="github")
    pc.add_argument("--framework", choices=sorted(FRAMEWORK_PRESETS.keys()), default=None,
                     help="Atalho para comando de build + diretório de saída mais comuns (confirme com o dono do projeto)")
    pc.add_argument("--comando-build", dest="comando_build", default=None,
                     help="Sobrescreve (ou substitui, sem --framework) o comando de build")
    pc.add_argument("--diretorio-saida", dest="diretorio_saida", default=None,
                     help="Sobrescreve (ou substitui, sem --framework) o diretório de saída da build")
    pc.add_argument("--diretorio-raiz", dest="diretorio_raiz", default=None,
                     help="Subpasta do repositório onde o projeto vive, se não for a raiz (monorepo)")
    pc.set_defaults(func=criar)

    pl = sub.add_parser("listar", help="Lista todos os projetos Cloudflare Pages da conta")
    pl.set_defaults(func=listar)

    ps = sub.add_parser("status", help="Mostra a implantação mais recente de um projeto")
    ps.add_argument("--projeto", required=True)
    ps.set_defaults(func=status)

    args = p.parse_args()
    if not args.account_id:
        import os
        args.account_id = os.environ.get(ACCOUNT_VAR, "<resolver-em-runtime:account_id>")

    try:
        args.func(args)
    except CredencialAusente as e:
        print(
            f"\nVariável de ambiente '{e}' não está definida. Veja o SKILL.md, "
            "seção 'Pré-requisitos', para o passo a passo de como criar/exportar o token."
        )
        sys.exit(1)
    except RuntimeError as e:
        print(f"\nErro: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
