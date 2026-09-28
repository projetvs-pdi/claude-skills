"""Simulador de renda fixa para a skill analise-financeira-investimentos.

Calcula aportes mensais, resgates, Imposto de Renda regressivo (por aplicação, começando
pela mais antiga) e, se pedido, a taxa de custódia acima de um limite de isenção.
Serve para o relatório: os números vêm daqui, não de conta feita de cabeça.

Regras importantes:
- As alíquotas e a taxa de custódia padrão abaixo estão confirmadas para o Tesouro Direto
  (site do Tesouro Direto e Lei 11.033/2004), mas CONFIRME-AS de novo na data da análise
  e passe valores diferentes pelas opções, se mudarem.
- A taxa anual é uma PREMISSA que você informa (ex.: Selic meta + spread do título).
  O script não busca dados de mercado.
- Não calcula IOF (só existe em resgate com menos de 30 dias; evite resgatar antes disso
  ou avise o investidor).

Exemplos:
  # Aporte inicial 1.800 em Out/26, 1.000 por mês até Dez/27, resgates líquidos de 4.500
  # nos meses 12, 13 e 14 (Out, Nov e Dez/27), taxa de 13,82% ao ano
  python simular.py --taxa 13.82 --inicial 1800 --mensal 1000 --meses 15 \
      --resgate 12=4500 --resgate 13=4500 --resgate 14=4500 --liquido

  # Sensibilidade a queda de juros
  python simular.py --taxa 13.82 --inicial 1000 --mensal 1000 --meses 15 \
      --resgate 12=4500 --resgate 13=4500 --resgate 14=4500 --liquido --sens 12.5 11.5 10.5
"""
import argparse
import sys

ALIQUOTAS = [(180, 0.225), (360, 0.20), (720, 0.175), (10**9, 0.15)]


def aliquota(dias, sem_ir):
    if sem_ir:
        return 0.0
    for limite, a in ALIQUOTAS:
        if dias <= limite:
            return a
    return 0.15


def mensal(taxa_anual_pct):
    return (1 + taxa_anual_pct / 100.0) ** (1 / 12) - 1


def sacar(lotes, bruto, sem_ir):
    """Saca `bruto` das aplicações mais antigas. Retorna (imposto, efetivamente_sacado)."""
    imposto, falta, sacado = 0.0, bruto, 0.0
    for lote in lotes:
        if falta <= 1e-9:
            break
        tira = min(falta, lote["valor"])
        frac = tira / lote["valor"]
        principal = lote["principal"] * frac
        imposto += (tira - principal) * aliquota(lote["meses"] * 30, sem_ir)
        lote["valor"] -= tira
        lote["principal"] -= principal
        falta -= tira
        sacado += tira
    return imposto, sacado


def simular(taxa, inicial, mensal_aporte, meses, resgates, liquido, sem_ir,
            custodia_taxa, custodia_isencao, posicao_externa):
    tx = mensal(taxa)
    lotes, linhas = [], []
    aplicado = total_bruto = total_ir = total_liq = total_custodia = 0.0
    for i in range(meses):
        for lote in lotes:
            lote["valor"] *= 1 + tx
            lote["meses"] += 1
        custodia = 0.0
        if custodia_taxa > 0 and lotes:
            saldo = sum(l["valor"] for l in lotes)
            excedente = max(0.0, saldo + posicao_externa - custodia_isencao)
            custodia = min(saldo, excedente) * custodia_taxa / 100.0 / 12
            fator = 1 - custodia / saldo
            for lote in lotes:
                lote["valor"] *= fator
            total_custodia += custodia
        bruto = ir = liq = 0.0
        alvo = resgates.get(i, 0.0)
        if alvo > 0:
            if liquido:
                lo, hi = alvo, alvo * 1.5
                for _ in range(60):
                    meio = (lo + hi) / 2
                    copia = [dict(l) for l in lotes]
                    imp, _ = sacar(copia, meio, sem_ir)
                    if meio - imp < alvo:
                        lo = meio
                    else:
                        hi = meio
                alvo_bruto = hi
            else:
                alvo_bruto = alvo
            ir, bruto = sacar(lotes, alvo_bruto, sem_ir)
            lotes = [l for l in lotes if l["valor"] > 1e-9]
            liq = bruto - ir
            total_bruto += bruto
            total_ir += ir
            total_liq += liq
        aporte = inicial if i == 0 else mensal_aporte
        if aporte > 0:
            lotes.append({"valor": aporte, "principal": aporte, "meses": 0})
            aplicado += aporte
        saldo_fim = sum(l["valor"] for l in lotes)
        linhas.append((i, bruto, ir, liq, aporte, saldo_fim))
    saldo = sum(l["valor"] for l in lotes)
    ir_saldo = sum((l["valor"] - l["principal"]) * aliquota(l["meses"] * 30, sem_ir) for l in lotes)
    rend = total_liq + saldo - ir_saldo - aplicado
    return dict(linhas=linhas, aplicado=aplicado, resgatado_bruto=total_bruto, ir_resgates=total_ir,
                resgatado_liquido=total_liq, saldo_bruto=saldo, ir_sobre_saldo=ir_saldo,
                saldo_liquido=saldo - ir_saldo, rendimento_liquido=rend, custodia=total_custodia)


def brl(v):
    return "R$ " + f"{v:,.2f}".replace(",", "X").replace(".", ",").replace("X", ".")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--taxa", type=float, required=True, help="taxa bruta anual em %% (premissa)")
    p.add_argument("--inicial", type=float, default=0.0)
    p.add_argument("--mensal", type=float, default=0.0)
    p.add_argument("--meses", type=int, required=True, help="meses simulados (mês 0 = primeiro aporte)")
    p.add_argument("--resgate", action="append", default=[], metavar="MES=VALOR",
                   help="resgate no mês (0 = primeiro). Pode repetir.")
    p.add_argument("--liquido", action="store_true", help="VALOR do resgate é líquido de IR")
    p.add_argument("--sem-ir", action="store_true", help="produto isento (ex.: poupança)")
    p.add_argument("--custodia", type=float, default=0.0, help="taxa de custódia anual em %% (ex.: 0.2)")
    p.add_argument("--isencao", type=float, default=10000.0, help="limite de isenção da custódia")
    p.add_argument("--externo", type=float, default=0.0,
                   help="valor que o investidor já tem no mesmo tipo de título (conta no limite)")
    p.add_argument("--sens", type=float, nargs="*", default=[], help="outras taxas para comparar")
    a = p.parse_args()
    resgates = {}
    for r in a.resgate:
        m, v = r.split("=")
        resgates[int(m)] = float(v)
    args = (a.inicial, a.mensal, a.meses, resgates, a.liquido, a.sem_ir, a.custodia, a.isencao, a.externo)
    res = simular(a.taxa, *args)
    print(f"| Mês | Resgate bruto | IR | Cai na conta | Aporte | Saldo no fim do mês |")
    print("|---:|---:|---:|---:|---:|---:|")
    for i, b, ir, liq, ap, s in res["linhas"]:
        print(f"| {i} | {brl(b)} | {brl(ir)} | {brl(liq)} | {brl(ap)} | {brl(s)} |")
    print()
    print(f"Aplicado: {brl(res['aplicado'])}")
    print(f"Resgatado (bruto / IR / líquido): {brl(res['resgatado_bruto'])} / {brl(res['ir_resgates'])} / {brl(res['resgatado_liquido'])}")
    print(f"Saldo no fim (bruto / líquido se resgatado): {brl(res['saldo_bruto'])} / {brl(res['saldo_liquido'])}")
    print(f"Custódia paga na simulação: {brl(res['custodia'])}")
    print(f"Rendimento líquido total: {brl(res['rendimento_liquido'])}")
    if a.sens:
        print("\nSensibilidade (rendimento líquido total):")
        for t in [a.taxa] + a.sens:
            print(f"- taxa {t:.2f}% ao ano: {brl(simular(t, *args)['rendimento_liquido'])}")


if __name__ == "__main__":
    sys.exit(main())
