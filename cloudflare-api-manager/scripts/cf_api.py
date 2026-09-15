#!/usr/bin/env python3
"""
cf_api.py — cliente mínimo para a API REST do Cloudflare (v4), sem dependências
externas (só biblioteca padrão do Python).

Por que existe: todos os outros scripts desta skill (zona, dns, token) importam
este módulo em vez de reimplementar chamadas HTTP. Isso garante que a lógica de
autenticação, modo dry-run e tratamento de erro seja idêntica em toda a skill.

## Modo DRY-RUN (padrão de segurança)

Se a variável de ambiente de credencial esperada não estiver definida, as
funções aqui NÃO fazem nenhuma chamada de rede: elas devolvem uma descrição do
que seria enviado (método, URL, corpo) marcada com "dry_run": True. Isso existe
para que:

  1. Nunca seja necessário colar um token da Cloudflare nesta conversa/sessão
     para "testar" a skill — o comportamento pode ser validado sem credencial.
  2. Se o usuário esquecer de configurar a variável de ambiente, a skill avisa
     claramente em vez de falhar com um 401 confuso ou, pior, tentar adivinhar
     uma credencial de outro lugar.

Nunca implemente um "fallback" que leia a credencial de outro lugar (histórico
de shell, arquivo de configuração não documentado, etc.) — se a variável de
ambiente não existir, o usuário precisa configurá-la explicitamente.
"""

import json
import os
import sys
import urllib.error
import urllib.request

API_BASE = "https://api.cloudflare.com/client/v4"


class CredencialAusente(Exception):
    """Levantada quando a variável de ambiente de credencial não está definida.

    Isso nunca deve ser tratado silenciosamente: o chamador deve mostrar ao
    usuário exatamente qual variável falta e como criá-la (veja SKILL.md,
    seção "Pré-requisitos").
    """


def ler_credencial(nome_var: str, obrigatoria: bool = True) -> str | None:
    valor = os.environ.get(nome_var, "").strip()
    if not valor:
        if obrigatoria:
            raise CredencialAusente(nome_var)
        return None
    return valor


def chamar_api(
    method: str,
    path: str,
    token_env_var: str,
    body: dict | None = None,
    query: dict | None = None,
    dry_run_label: str | None = None,
) -> dict:
    """Faz (ou simula) uma chamada à API do Cloudflare.

    - method: "GET", "POST", "PUT", "DELETE"
    - path: caminho relativo, ex. "/zones" ou "/user/tokens/123/value"
    - token_env_var: nome da variável de ambiente que contém o Bearer token
      a ser usado nesta chamada específica (ex. "CLOUDFLARE_BOOTSTRAP_TOKEN"
      para operações de gestão de token, ou o token específico de um projeto
      para operações de DNS naquela zona).
    - dry_run_label: texto curto explicando o que esta chamada faz, usado
      apenas na saída do modo dry-run para ficar legível.

    Retorna sempre um dict com pelo menos a chave "dry_run" (bool). Se
    dry_run=True, contém "method", "url", "body". Se dry_run=False, contém o
    "result" já extraído da resposta da Cloudflare (list ou dict) e "raw"
    com a resposta completa (inclui "success", "errors", "messages").
    """
    url = f"{API_BASE}{path}"
    if query:
        qs = "&".join(f"{k}={v}" for k, v in query.items() if v is not None)
        if qs:
            url = f"{url}?{qs}"

    token = ler_credencial(token_env_var, obrigatoria=False)
    if not token:
        return {
            "dry_run": True,
            "method": method,
            "url": url,
            "body": body,
            "aviso": (
                f"Variável de ambiente '{token_env_var}' não encontrada — "
                "nenhuma chamada real foi feita. Configure a credencial "
                "seguindo o SKILL.md antes de executar de verdade."
            ),
            "descricao": dry_run_label or f"{method} {path}",
        }

    req = urllib.request.Request(url, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/json")
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")

    try:
        with urllib.request.urlopen(req, data=data, timeout=30) as resp:
            raw = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        raw_bytes = e.read()
        try:
            raw = json.loads(raw_bytes.decode("utf-8"))
        except Exception:
            raw = {"success": False, "errors": [{"message": raw_bytes.decode("utf-8", "replace")}]}
        raw["_http_status"] = e.code

    if not raw.get("success", False):
        erros = "; ".join(err.get("message", str(err)) for err in raw.get("errors", []))
        status = raw.get("_http_status", "?")
        raise RuntimeError(
            f"Cloudflare API retornou erro (HTTP {status}) em {method} {path}: {erros or 'sem detalhes'}"
        )

    return {"dry_run": False, "result": raw.get("result"), "raw": raw}


def resolver_grupo_permissao(nomes_desejados: list[str], token_env_var: str, escopo: str = "user") -> dict:
    """Busca, na lista oficial de permission groups da Cloudflare, o id de
    cada nome desejado (ex. "DNS Write", "Zone Write", "Pages Write").

    Por que resolver dinamicamente em vez de fixar IDs no código: os ids de
    permission group não são garantidos como estáveis entre contas/regiões
    pela documentação pública da Cloudflare — o próprio guia oficial recomenda
    descobri-los via API antes de montar o token. Fixar IDs no código seria
    frágil e poderia silenciosamente criar um token com a permissão errada.

    - escopo: "user" usa GET /user/tokens/permission_groups (permissões que
      o usuário dono do token de bootstrap pode conceder); "account" usa
      GET /accounts/{account_id}/tokens/permission_groups (necessário
      passar account_id em query quando escopo="account").

    Em modo dry-run, devolve um dict com um id simbólico
    "<resolver-em-runtime:NOME>" para cada nome, para que o restante do
    fluxo (montagem do body do token) continue sendo demonstrável sem
    credencial.
    """
    if escopo == "user":
        path = "/user/tokens/permission_groups"
    else:
        raise ValueError("escopo inválido, use 'user' (accounts não implementado aqui)")

    resposta = chamar_api("GET", path, token_env_var, dry_run_label="Listar permission groups disponíveis")

    if resposta["dry_run"]:
        return {nome: f"<resolver-em-runtime:{nome}>" for nome in nomes_desejados}

    disponiveis = {item["name"]: item["id"] for item in resposta["result"]}
    encontrados = {}
    faltando = []
    for nome in nomes_desejados:
        if nome in disponiveis:
            encontrados[nome] = disponiveis[nome]
        else:
            faltando.append(nome)

    if faltando:
        parecidos = ", ".join(sorted(disponiveis.keys()))
        raise RuntimeError(
            f"Não encontrei o(s) permission group(s) {faltando} na sua conta. "
            f"Grupos disponíveis: {parecidos}"
        )
    return encontrados


def imprimir_resultado(resposta: dict, titulo: str) -> None:
    print(f"\n=== {titulo} ===")
    if resposta["dry_run"]:
        print(f"[DRY-RUN] {resposta['aviso']}")
        print(f"  {resposta['method']} {resposta['url']}")
        if resposta["body"] is not None:
            print(json.dumps(resposta["body"], indent=2, ensure_ascii=False))
    else:
        print(json.dumps(resposta["result"], indent=2, ensure_ascii=False))


if __name__ == "__main__":
    # Uso rápido de diagnóstico: python cf_api.py <VAR_DE_AMBIENTE>
    # Verifica se a credencial na variável indicada é válida (GET /user/tokens/verify).
    if len(sys.argv) != 2:
        print("Uso: python cf_api.py <NOME_DA_VARIAVEL_DE_AMBIENTE>")
        sys.exit(1)
    var = sys.argv[1]
    try:
        r = chamar_api("GET", "/user/tokens/verify", var, dry_run_label="Verificar validade do token")
        imprimir_resultado(r, f"Verificação de '{var}'")
    except CredencialAusente as e:
        print(f"Variável de ambiente '{e}' não está definida.")
        sys.exit(1)
    except RuntimeError as e:
        print(f"Erro: {e}")
        sys.exit(1)
