#!/usr/bin/env python3
"""
token_manager.py — cria, lista, rola (revoga+gera novo) e revoga tokens de
API da Cloudflare escopados a uma zona/conta, usando o token de bootstrap.

Equivalente automatizado do fluxo manual pelo painel: Perfil > Tokens de API
> Create Custom Token > permissões DNS/Zone/Pages > Zona específica > Criar.

Autenticação: usa SEMPRE a variável de ambiente CLOUDFLARE_BOOTSTRAP_TOKEN
(o "token mestre" com permissão apenas de gerenciar outros tokens — ver
SKILL.md, seção "Pré-requisitos"). Nunca use o token de um projeto para
gerenciar outros tokens.

Exemplos:

  # Criar um token para um domínio com o preset padrão (DNS Edit + Zone Edit
  # + Cloudflare Pages Edit), igual ao que fizemos manualmente para
  # projetvs.com.br:
  python token_manager.py criar --dominio projetvs.com.br --nome projetvs.com.br

  # Criar um token só de leitura de DNS (útil para scripts de monitoramento):
  python token_manager.py criar --dominio projetvs.com.br --nome projetvs-dns-readonly \
      --permissoes "DNS Read"

  # Rolar (revogar + gerar novo, mesmas permissões) um token existente:
  python token_manager.py rolar --nome projetvs.com.br

  # Revogar definitivamente um token:
  python token_manager.py revogar --nome projetvs.com.br

  # Listar tokens existentes:
  python token_manager.py listar
"""

import argparse
import sys

from cf_api import CredencialAusente, chamar_api, imprimir_resultado, resolver_grupo_permissao

BOOTSTRAP_VAR = "CLOUDFLARE_BOOTSTRAP_TOKEN"
ACCOUNT_VAR = "CLOUDFLARE_ACCOUNT_ID"

# Presets espelhando os casos de uso mais comuns. "dns-pages" é exatamente o
# que criamos manualmente para projetvs.com.br (DNS Edit + Zone Edit no nível
# da zona, Cloudflare Pages Edit no nível da conta).
PRESETS = {
    "dns-pages": {
        "zona": ["DNS Write", "Zone Write"],
        "conta": ["Cloudflare Pages Write"],
    },
    "dns-somente": {
        "zona": ["DNS Write", "Zone Write"],
        "conta": [],
    },
    "dns-leitura": {
        "zona": ["DNS Read"],
        "conta": [],
    },
}


def _buscar_zona_id(dominio: str) -> str:
    resp = chamar_api(
        "GET", "/zones", BOOTSTRAP_VAR, query={"name": dominio},
        dry_run_label=f"Buscar id da zona '{dominio}'",
    )
    if resp["dry_run"]:
        return "<resolver-em-runtime:zone_id>"
    zonas = resp["result"]
    if not zonas:
        raise RuntimeError(
            f"Nenhuma zona chamada '{dominio}' encontrada na conta. Se o domínio "
            "ainda não foi adicionado ao Cloudflare, use zone_manager.py criar primeiro."
        )
    return zonas[0]["id"]


def _montar_policies(permissoes_zona, permissoes_conta, zona_id, account_id):
    grupos_desejados = list(dict.fromkeys(permissoes_zona + permissoes_conta))  # preserva ordem, remove dup
    ids = resolver_grupo_permissao(grupos_desejados, BOOTSTRAP_VAR)

    policies = []
    if permissoes_zona:
        policies.append({
            "effect": "allow",
            "resources": {f"com.cloudflare.api.account.zone.{zona_id}": "*"},
            "permission_groups": [{"id": ids[n], "name": n} for n in permissoes_zona],
        })
    if permissoes_conta:
        policies.append({
            "effect": "allow",
            "resources": {f"com.cloudflare.api.account.{account_id}": "*"},
            "permission_groups": [{"id": ids[n], "name": n} for n in permissoes_conta],
        })
    return policies


def criar(args):
    account_id = args.account_id
    zona_id = _buscar_zona_id(args.dominio)

    if args.permissoes:
        # Lista customizada: tudo escopado à zona por padrão. Use --permissoes-conta
        # para permissões de nível de conta (ex. Cloudflare Pages Write).
        permissoes_zona = args.permissoes
        permissoes_conta = args.permissoes_conta or []
    else:
        preset = PRESETS[args.preset]
        permissoes_zona = preset["zona"]
        permissoes_conta = preset["conta"]

    policies = _montar_policies(permissoes_zona, permissoes_conta, zona_id, account_id)

    body = {"name": args.nome, "policies": policies}
    if args.ttl_dias:
        # expires_on é calculado pelo chamador; aqui só documentamos a intenção
        # via corpo — cálculo de data fica fora do dry-run para simplicidade.
        import datetime
        expira = (datetime.datetime.utcnow() + datetime.timedelta(days=args.ttl_dias)).isoformat() + "Z"
        body["expires_on"] = expira

    resp = chamar_api("POST", "/user/tokens", BOOTSTRAP_VAR, body=body,
                       dry_run_label=f"Criar token '{args.nome}' para {args.dominio}")
    imprimir_resultado(resp, f"Token criado: {args.nome}")
    if not resp["dry_run"]:
        valor = resp["result"].get("value")
        print(
            "\n⚠️  Copie o valor do token AGORA — a Cloudflare não mostra de novo.\n"
            "Não cole esse valor de volta nesta conversa/terminal compartilhado; "
            "guarde num cofre de segredos ou exporte como variável de ambiente "
            "no ambiente onde ele será usado.\n"
        )
        print(f"token: {valor}")


def _localizar_por_nome(nome: str) -> str:
    resp = chamar_api("GET", "/user/tokens", BOOTSTRAP_VAR, dry_run_label=f"Localizar token '{nome}'")
    if resp["dry_run"]:
        return "<resolver-em-runtime:token_id>"
    for t in resp["result"]:
        if t["name"] == nome:
            return t["id"]
    raise RuntimeError(f"Nenhum token chamado '{nome}' encontrado.")


def rolar(args):
    token_id = _localizar_por_nome(args.nome)
    resp = chamar_api("PUT", f"/user/tokens/{token_id}/value", BOOTSTRAP_VAR,
                       dry_run_label=f"Rolar token '{args.nome}' (revoga o valor atual e gera um novo)")
    if resp["dry_run"]:
        imprimir_resultado(resp, f"Rolar token: {args.nome}")
        return
    novo_valor = resp["result"]
    print(f"\n=== Token '{args.nome}' rolado com sucesso ===")
    print(
        "⚠️  O valor anterior foi revogado. Copie o novo valor AGORA — a "
        "Cloudflare não mostra de novo, e ele não será reproduzido de volta "
        "nesta conversa por segurança.\n"
    )
    print(f"token: {novo_valor}")


def revogar(args):
    token_id = _localizar_por_nome(args.nome)
    resp = chamar_api("DELETE", f"/user/tokens/{token_id}", BOOTSTRAP_VAR,
                       dry_run_label=f"Revogar (excluir) token '{args.nome}'")
    imprimir_resultado(resp, f"Token revogado: {args.nome}")


def listar(args):
    resp = chamar_api("GET", "/user/tokens", BOOTSTRAP_VAR, dry_run_label="Listar todos os tokens de API")
    imprimir_resultado(resp, "Tokens de API existentes")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="comando", required=True)

    pc = sub.add_parser("criar", help="Cria um novo token escopado")
    pc.add_argument("--dominio", required=True, help="Domínio/zona ao qual o token será restrito, ex. projetvs.com.br")
    pc.add_argument("--nome", required=True, help="Nome do token (aparece no painel do Cloudflare)")
    pc.add_argument("--preset", choices=PRESETS.keys(), default="dns-pages",
                     help="Conjunto de permissões pronto (padrão: dns-pages, igual ao que usamos para projetvs.com.br)")
    pc.add_argument("--permissoes", nargs="*", help="Lista customizada de permission groups escopados à ZONA (substitui --preset)")
    pc.add_argument("--permissoes-conta", nargs="*", help="Permission groups escopados à CONTA (ex. 'Cloudflare Pages Write')")
    pc.add_argument("--ttl-dias", type=int, default=None, help="Se definido, o token expira automaticamente após N dias")
    pc.add_argument("--account-id", default=None, help=f"Se omitido, lê de {ACCOUNT_VAR}")
    pc.set_defaults(func=criar)

    pr = sub.add_parser("rolar", help="Revoga o valor atual e gera um novo, mantendo as mesmas permissões")
    pr.add_argument("--nome", required=True)
    pr.set_defaults(func=rolar)

    pv = sub.add_parser("revogar", help="Revoga (exclui) um token permanentemente")
    pv.add_argument("--nome", required=True)
    pv.set_defaults(func=revogar)

    pl = sub.add_parser("listar", help="Lista todos os tokens de API do usuário")
    pl.set_defaults(func=listar)

    args = p.parse_args()

    if args.comando == "criar" and not args.account_id:
        import os
        args.account_id = os.environ.get(ACCOUNT_VAR, "<resolver-em-runtime:account_id>")

    try:
        args.func(args)
    except CredencialAusente as e:
        print(
            f"\nVariável de ambiente '{e}' não está definida. Veja o SKILL.md, "
            "seção 'Pré-requisitos', para o passo a passo de como criar o "
            "token de bootstrap e exportá-lo com segurança."
        )
        sys.exit(1)
    except RuntimeError as e:
        print(f"\nErro: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
