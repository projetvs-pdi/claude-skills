#!/usr/bin/env python3
"""
provisionar_dominio.py — depois que uma zona nova termina de propagar
(nameservers configurados no registrador e o Cloudflare marca a zona como
"active"), aplica de uma vez as recomendações padrão que o próprio painel do
Cloudflare mostra para uma zona recém-criada:

  1. Conecta a raiz do domínio (e, por padrão, o "www") ao projeto do
     Cloudflare Pages indicado — usando o endpoint de "Custom Domains" do
     Pages (não só um CNAME solto), que é o que de fato ativa o roteamento e
     o certificado SSL para aquele domínio.
  2. Se a zona ainda não tem nenhum registro MX (ou seja, não há e-mail
     configurado), adiciona um SPF (`v=spf1 -all`) e um DMARC
     (`v=DMARC1; p=reject;`) restritivos, só para impedir que alguém
     falsifique e-mails "de" esse domínio enquanto ele não tem e-mail de
     verdade. Se já existir MX, este script NÃO mexe em nada de e-mail —
     presume que já há uma configuração real que não deve ser sobrescrita.

Por que existe como um passo separado (e não dentro de zone_manager.py
criar): a zona só fica "active" depois que o usuário configura os
nameservers no registrador do domínio — isso pode levar minutos ou até 24h,
e é inteiramente fora do controle da Cloudflare/desta skill. Este comando é
seguro para rodar várias vezes (idempotente): se a zona ainda não propagou,
ele não faz nenhuma mudança e só avisa; se algo já foi criado numa execução
anterior, ele detecta e pula em vez de duplicar ou falhar.

Autenticação: usa DOIS tokens diferentes, de propósito:
  - CLOUDFLARE_BOOTSTRAP_TOKEN — só para checar o status da zona (leitura).
  - CLOUDFLARE_ZONE_TOKEN — o token JÁ ESCOPADO a essa zona (criado com
    token_manager.py, preset "dns-pages"), usado para de fato criar os
    registros de DNS e conectar o domínio personalizado ao Pages. O token de
    bootstrap nunca é usado para essas escritas — ele só sabe gerenciar
    outros tokens e checar status.

Exemplo:

  python provisionar_dominio.py verificar-e-aplicar \
      --dominio novosite.com.br --projeto-pages meu-projeto
"""

import argparse
import sys

from cf_api import CredencialAusente, chamar_api, ler_credencial

BOOTSTRAP_VAR = "CLOUDFLARE_BOOTSTRAP_TOKEN"
ZONE_VAR = "CLOUDFLARE_ZONE_TOKEN"
ACCOUNT_VAR = "CLOUDFLARE_ACCOUNT_ID"


def _status_da_zona(dominio: str):
    """Retorna (zone_id, status) consultando com o token de bootstrap.
    Em dry-run, retorna valores simbólicos e status 'active' para que o
    resto do fluxo seja demonstrável sem credencial."""
    resp = chamar_api("GET", "/zones", BOOTSTRAP_VAR, query={"name": dominio},
                       dry_run_label=f"Checar status de propagação de '{dominio}'")
    if resp["dry_run"]:
        print(f"[DRY-RUN] {resp['aviso']}\n  {resp['method']} {resp['url']}")
        return "<resolver-em-runtime:zone_id>", "active (assumido em dry-run)"
    zonas = resp["result"]
    if not zonas:
        raise RuntimeError(
            f"Nenhuma zona chamada '{dominio}' encontrada. Rode zone_manager.py "
            "criar primeiro."
        )
    zona = zonas[0]
    return zona["id"], zona["status"]


def _ja_existe_erro_de_duplicado(mensagem: str) -> bool:
    m = mensagem.lower()
    return "already" in m or "duplicate" in m or "exists" in m


def _conectar_dominio_pages(host: str, projeto: str, account_id: str) -> str:
    """Registra `host` como domínio personalizado do projeto Pages.
    Retorna 'criado', 'ja_existia' ou 'dry_run'."""
    body = {"name": host}
    try:
        resp = chamar_api(
            "POST", f"/accounts/{account_id}/pages/projects/{projeto}/domains", ZONE_VAR,
            body=body, dry_run_label=f"Adicionar '{host}' como domínio personalizado do projeto Pages '{projeto}'",
        )
    except RuntimeError as e:
        if _ja_existe_erro_de_duplicado(str(e)):
            return "ja_existia"
        raise
    if resp["dry_run"]:
        print(f"[DRY-RUN] {resp['aviso']}\n  {resp['method']} {resp['url']}\n  body: {body}")
        return "dry_run"
    return "criado"


def _garantir_cname(host: str, projeto: str, zona_id: str) -> str:
    """Garante que existe um CNAME `host` -> `projeto.pages.dev` (com proxy).
    O endpoint de Custom Domains do Pages normalmente já provisiona isso
    quando a zona está na mesma conta, mas checamos e criamos como rede de
    segurança caso não tenha sido criado automaticamente.
    Retorna 'criado', 'ja_existia' ou 'dry_run'."""
    consulta = chamar_api("GET", f"/zones/{zona_id}/dns_records", ZONE_VAR,
                           query={"type": "CNAME", "name": host},
                           dry_run_label=f"Checar se já existe CNAME para {host}")
    if consulta["dry_run"]:
        print(f"[DRY-RUN] {consulta['aviso']}\n  {consulta['method']} {consulta['url']}")
        return "dry_run"
    if consulta["result"]:
        return "ja_existia"

    destino = f"{projeto}.pages.dev"
    body = {"type": "CNAME", "name": host, "content": destino, "ttl": 1, "proxied": True}
    chamar_api("POST", f"/zones/{zona_id}/dns_records", ZONE_VAR, body=body,
               dry_run_label=f"Criar CNAME {host} -> {destino} (rede de segurança)")
    return "criado"


def _zona_tem_mx(zona_id: str) -> bool | None:
    """None em dry-run (não sabemos); True/False caso contrário."""
    resp = chamar_api("GET", f"/zones/{zona_id}/dns_records", ZONE_VAR, query={"type": "MX"},
                       dry_run_label="Checar se a zona já tem registro MX (não mexer em e-mail se tiver)")
    if resp["dry_run"]:
        print(f"[DRY-RUN] {resp['aviso']}\n  {resp['method']} {resp['url']}")
        return None
    return len(resp["result"]) > 0


def _garantir_txt(zona_id: str, nome: str, conteudo_esperado_prefixo: str, conteudo_novo: str, descricao: str) -> str:
    consulta = chamar_api("GET", f"/zones/{zona_id}/dns_records", ZONE_VAR,
                           query={"type": "TXT", "name": nome}, dry_run_label=f"Checar se já existe {descricao}")
    if consulta["dry_run"]:
        print(f"[DRY-RUN] {consulta['aviso']}\n  {consulta['method']} {consulta['url']}")
        return "dry_run"
    for registro in consulta["result"]:
        if registro.get("content", "").startswith(conteudo_esperado_prefixo):
            return "ja_existia"

    body = {"type": "TXT", "name": nome, "content": conteudo_novo, "ttl": 1}
    chamar_api("POST", f"/zones/{zona_id}/dns_records", ZONE_VAR, body=body, dry_run_label=f"Criar {descricao}")
    return "criado"


def verificar_e_aplicar(args):
    zona_id, status = _status_da_zona(args.dominio)
    print(f"\nStatus atual da zona '{args.dominio}': {status}")

    if status not in ("active", "active (assumido em dry-run)"):
        print(
            "\nAinda não propagou — nada foi alterado. Isso é normal logo após "
            "criar a zona; pode levar de alguns minutos a até 24h, dependendo "
            "do registrador do domínio. Rode este mesmo comando de novo mais "
            "tarde para checar/aplicar."
        )
        return

    account_id = args.account_id
    hosts = [args.dominio] + ([f"www.{args.dominio}"] if not args.sem_www else [])

    print(f"\n=== Conectando ao Cloudflare Pages (projeto: {args.projeto_pages}) ===")
    for host in hosts:
        resultado_pages = _conectar_dominio_pages(host, args.projeto_pages, account_id)
        resultado_dns = _garantir_cname(host, args.projeto_pages, zona_id)
        print(f"  {host}: domínio personalizado = {resultado_pages}, registro DNS = {resultado_dns}")

    if args.pular_seguranca_email:
        print("\n=== E-mail: pulado (--pular-seguranca-email) ===")
        return

    print("\n=== Verificando e-mail ===")
    tem_mx = _zona_tem_mx(zona_id)
    if tem_mx is None:
        print("  [DRY-RUN] não é possível checar MX sem credencial — SPF/DMARC não seriam alterados nesta simulação.")
        return
    if tem_mx:
        print(
            "  Já existe registro MX nesta zona — presumo que já há e-mail "
            "configurado e NÃO vou mexer em SPF/DMARC. Ajuste manualmente com "
            "dns_manager.py se precisar."
        )
        return

    print("  Nenhum MX encontrado — aplicando SPF/DMARC restritivos (sem e-mail neste domínio):")
    r_spf = _garantir_txt(zona_id, args.dominio, "v=spf1", "v=spf1 -all", "SPF restritivo (v=spf1 -all)")
    print(f"    SPF: {r_spf}")
    r_dmarc = _garantir_txt(zona_id, f"_dmarc.{args.dominio}", "v=DMARC1", "v=DMARC1; p=reject;",
                             "DMARC restritivo (v=DMARC1; p=reject;)")
    print(f"    DMARC: {r_dmarc}")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="comando", required=True)

    pv = sub.add_parser("verificar-e-aplicar", help="Checa se a zona propagou e, se sim, aplica as recomendações")
    pv.add_argument("--dominio", required=True)
    pv.add_argument("--projeto-pages", required=True, help="Nome do projeto no Cloudflare Pages (o <isso>.pages.dev)")
    pv.add_argument("--sem-www", action="store_true", help="Não conectar o subdomínio www, só a raiz")
    pv.add_argument("--pular-seguranca-email", action="store_true", help="Não mexer em SPF/DMARC de jeito nenhum")
    pv.add_argument("--account-id", default=None, help=f"Se omitido, lê de {ACCOUNT_VAR}")
    pv.set_defaults(func=verificar_e_aplicar)

    args = p.parse_args()
    if not args.account_id:
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
