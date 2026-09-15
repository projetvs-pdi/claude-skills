#!/usr/bin/env python3
"""
dns_manager.py — lista, cria, atualiza e remove registros DNS de uma zona.

Autenticação: por padrão usa a variável de ambiente CLOUDFLARE_ZONE_TOKEN —
ou seja, o token JÁ ESCOPADO àquela zona específica, criado antes com
token_manager.py (permissão "DNS Write"/"DNS Read"). Propositalmente NÃO usa
o token de bootstrap aqui: o de bootstrap só deveria conseguir gerenciar
outros tokens, não editar DNS diretamente — separar os dois limita o estrago
possível se um dos dois vazar.

Se preferir usar outro nome de variável de ambiente (por exemplo, quando um
projeto tem vários domínios, cada um com seu próprio token), passe
--var-ambiente NOME_DA_VARIAVEL.

Exemplos:

  python dns_manager.py listar --dominio projetvs.com.br

  python dns_manager.py criar --dominio projetvs.com.br --tipo CNAME \
      --nome app.projetvs.com.br --conteudo meuapp.pages.dev --proxied

  python dns_manager.py atualizar --dominio projetvs.com.br --id <record_id> \
      --conteudo novo-destino.pages.dev

  python dns_manager.py remover --dominio projetvs.com.br --id <record_id>
"""

import argparse
import sys

from cf_api import CredencialAusente, chamar_api, imprimir_resultado

BOOTSTRAP_VAR = "CLOUDFLARE_BOOTSTRAP_TOKEN"  # usado só para resolver o zone_id por nome


def _buscar_zona_id(dominio: str) -> str:
    resp = chamar_api("GET", "/zones", BOOTSTRAP_VAR, query={"name": dominio},
                       dry_run_label=f"Buscar id da zona '{dominio}'")
    if resp["dry_run"]:
        return "<resolver-em-runtime:zone_id>"
    zonas = resp["result"]
    if not zonas:
        raise RuntimeError(f"Nenhuma zona chamada '{dominio}' encontrada.")
    return zonas[0]["id"]


def listar(args):
    zona_id = _buscar_zona_id(args.dominio)
    query = {}
    if args.tipo:
        query["type"] = args.tipo
    if args.nome:
        query["name"] = args.nome
    resp = chamar_api("GET", f"/zones/{zona_id}/dns_records", args.var_ambiente, query=query or None,
                       dry_run_label=f"Listar registros DNS de {args.dominio}")
    imprimir_resultado(resp, f"Registros DNS — {args.dominio}")


def criar(args):
    zona_id = _buscar_zona_id(args.dominio)
    body = {
        "type": args.tipo,
        "name": args.nome,
        "content": args.conteudo,
        "ttl": args.ttl,
        "proxied": args.proxied,
    }
    if args.comentario:
        body["comment"] = args.comentario
    resp = chamar_api("POST", f"/zones/{zona_id}/dns_records", args.var_ambiente, body=body,
                       dry_run_label=f"Criar registro {args.tipo} '{args.nome}' -> {args.conteudo}")
    imprimir_resultado(resp, f"Registro criado — {args.dominio}")


def atualizar(args):
    zona_id = _buscar_zona_id(args.dominio)
    body = {}
    if args.tipo:
        body["type"] = args.tipo
    if args.nome:
        body["name"] = args.nome
    if args.conteudo:
        body["content"] = args.conteudo
    if args.ttl:
        body["ttl"] = args.ttl
    if args.proxied is not None:
        body["proxied"] = args.proxied
    resp = chamar_api("PATCH", f"/zones/{zona_id}/dns_records/{args.id}", args.var_ambiente, body=body,
                       dry_run_label=f"Atualizar registro {args.id}")
    imprimir_resultado(resp, f"Registro atualizado — {args.dominio}")


def remover(args):
    zona_id = _buscar_zona_id(args.dominio)
    resp = chamar_api("DELETE", f"/zones/{zona_id}/dns_records/{args.id}", args.var_ambiente,
                       dry_run_label=f"Remover registro {args.id}")
    imprimir_resultado(resp, f"Registro removido — {args.dominio}")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--var-ambiente", default="CLOUDFLARE_ZONE_TOKEN",
                    help="Nome da variável de ambiente com o token escopado a esta zona (padrão: CLOUDFLARE_ZONE_TOKEN)")
    sub = p.add_subparsers(dest="comando", required=True)

    pl = sub.add_parser("listar")
    pl.add_argument("--dominio", required=True)
    pl.add_argument("--tipo", default=None)
    pl.add_argument("--nome", default=None)
    pl.set_defaults(func=listar)

    pc = sub.add_parser("criar")
    pc.add_argument("--dominio", required=True)
    pc.add_argument("--tipo", required=True, help="A, AAAA, CNAME, TXT, MX, etc.")
    pc.add_argument("--nome", required=True, help="Nome completo do registro, ex. app.projetvs.com.br")
    pc.add_argument("--conteudo", required=True, help="Valor do registro (IP, hostname de destino, texto...)")
    pc.add_argument("--ttl", type=int, default=1, help="1 = automático (padrão)")
    pc.add_argument("--proxied", action="store_true", help="Ativa o proxy/CDN da Cloudflare (nuvem laranja)")
    pc.add_argument("--comentario", default=None)
    pc.set_defaults(func=criar)

    pa = sub.add_parser("atualizar")
    pa.add_argument("--dominio", required=True)
    pa.add_argument("--id", required=True, help="ID do registro (obtido via 'listar')")
    pa.add_argument("--tipo", default=None)
    pa.add_argument("--nome", default=None)
    pa.add_argument("--conteudo", default=None)
    pa.add_argument("--ttl", type=int, default=None)
    pa.add_argument("--proxied", action=argparse.BooleanOptionalAction, default=None)
    pa.set_defaults(func=atualizar)

    pr = sub.add_parser("remover")
    pr.add_argument("--dominio", required=True)
    pr.add_argument("--id", required=True)
    pr.set_defaults(func=remover)

    args = p.parse_args()
    try:
        args.func(args)
    except CredencialAusente as e:
        print(
            f"\nVariável de ambiente '{e}' não está definida. Se ainda não "
            "existe um token escopado para esta zona, crie um primeiro com "
            "token_manager.py (veja SKILL.md)."
        )
        sys.exit(1)
    except RuntimeError as e:
        print(f"\nErro: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
