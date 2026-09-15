#!/usr/bin/env python3
"""
zone_manager.py — lista e cria zonas (domínios) na conta Cloudflare.

Autenticação: usa CLOUDFLARE_BOOTSTRAP_TOKEN, que para a ação "criar" precisa
ter a permissão extra "Account > Zone > Edit" em TODAS as zonas da conta
(veja SKILL.md, seção "Permissão extra para criar zonas novas") — isso é
diferente da permissão mínima de gerenciar tokens, então essa ação só
funciona se o usuário explicitamente adicionou essa permissão ao token de
bootstrap.

IMPORTANTE — o que este script NÃO faz: criar uma zona no Cloudflare não
ativa o domínio sozinho. A Cloudflare devolve uma lista de nameservers que
precisam ser configurados manualmente no registrador do domínio (Registro.br,
GoDaddy, etc.) — isso é uma etapa fora da API do Cloudflare e fora do que
qualquer script pode automatizar. Sempre mostre os nameservers ao usuário e
avise sobre esse passo manual.

Exemplos:

  python zone_manager.py listar --dominio projetvs.com.br
  python zone_manager.py criar --dominio novosite.com.br
"""

import argparse
import sys

from cf_api import CredencialAusente, chamar_api, imprimir_resultado

BOOTSTRAP_VAR = "CLOUDFLARE_BOOTSTRAP_TOKEN"
ACCOUNT_VAR = "CLOUDFLARE_ACCOUNT_ID"


def listar(args):
    query = {"name": args.dominio} if args.dominio else None
    resp = chamar_api("GET", "/zones", BOOTSTRAP_VAR, query=query,
                       dry_run_label="Listar zonas da conta" + (f" filtrando por {args.dominio}" if args.dominio else ""))
    imprimir_resultado(resp, "Zonas")


def criar(args):
    account_id = args.account_id
    body = {"account": {"id": account_id}, "name": args.dominio, "type": "full"}
    resp = chamar_api("POST", "/zones", BOOTSTRAP_VAR, body=body,
                       dry_run_label=f"Criar a zona '{args.dominio}' na conta")
    imprimir_resultado(resp, f"Zona criada: {args.dominio}")
    if not resp["dry_run"]:
        ns = resp["result"].get("name_servers", [])
        print(
            "\n📋 Próximo passo (fora da Cloudflare, manual): configure estes "
            f"nameservers no painel do registrador de '{args.dominio}':\n"
        )
        for n in ns:
            print(f"  - {n}")
        print(
            "\nA zona só fica 'Ativa' depois que o registrador propagar essa "
            "mudança (pode levar de minutos a até 24h). Depois disso, use "
            "token_manager.py para gerar o token escopado a esta zona."
        )


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="comando", required=True)

    pl = sub.add_parser("listar", help="Lista zonas existentes (opcionalmente filtrando por domínio)")
    pl.add_argument("--dominio", default=None)
    pl.set_defaults(func=listar)

    pc = sub.add_parser("criar", help="Cria (adiciona) uma zona nova na conta")
    pc.add_argument("--dominio", required=True)
    pc.add_argument("--account-id", default=None, help=f"Se omitido, lê de {ACCOUNT_VAR}")
    pc.set_defaults(func=criar)

    args = p.parse_args()
    if args.comando == "criar" and not args.account_id:
        import os
        args.account_id = os.environ.get(ACCOUNT_VAR, "<resolver-em-runtime:account_id>")

    try:
        args.func(args)
    except CredencialAusente as e:
        print(
            f"\nVariável de ambiente '{e}' não está definida. Veja o SKILL.md, "
            "seção 'Pré-requisitos'."
        )
        sys.exit(1)
    except RuntimeError as e:
        print(f"\nErro: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
