# Casos sob demanda

Leia só a parte que o pedido do usuário exigir. Em todos os casos vale a regra central do
SKILL.md: sem fonte, sem número.

## 1. O investidor enviou um print, uma oferta ou um PDF

O nome do produto pode enganar. Confira sempre:

| Ponto | Por quê |
|---|---|
| Emissor | Quem paga o dinheiro de volta (banco, financeira, governo) |
| Vencimento e liquidez | "CDB 100% CDI" com resgate só em 721 dias não é liquidez diária |
| Taxa fixa ou pós-fixada | Fixa protege da queda dos juros, mas o preço varia se vender antes |
| Rating do emissor, com data | Use o mais recente. Uma agência pode ter rebaixado depois do que o site do emissor mostra |
| FGC e aplicação mínima | Cobre até R$ 250 mil por CPF e instituição (confirme no site do FGC) |
| Custos | Taxa de administração e de performance, se for fundo |

Para PDF sem leitor instalado: `python scripts/pdf_texto.py arquivo.pdf`. Não instale nada sem pedir.
Em formulários de fundo, procure taxa de administração, tributação, garantia do FGC e regras de resgate; se o
documento for antigo, busque a versão atual do fundo antes de recomendar.

## 2. "E se a Selic continuar caindo?"

Rode o simulador com outras taxas (`--sens 12.5 11.5 10.5`) e mostre o efeito em reais. Não invente uma
projeção da Selic: use só uma projeção validada em fonte oficial (Banco Central, pesquisa Focus) ou diga que
não há e trate como cenário hipotético. Explique que os produtos pós-fixados acompanham a Selic e que
os prefixados travam a taxa, mas podem perder valor se forem vendidos antes do vencimento.

## 3. "Renda variável não renderia mais?"

Responda com números, não só com argumento:

1. Busque a rentabilidade do índice em 12, 24, 36 e 60 meses, a volatilidade e o pior mês, em fonte confiável, e compare
   com uma referência de renda fixa do mesmo período.
2. Mostre em reais, com o dinheiro do investidor, um ano bom e um ano ruim.
3. Relacione ao objetivo: dinheiro com data marcada de uso e prazo curto é exposto a perda justamente quando
   será usado. Se o investidor quiser, sugira uma parte pequena, só do que ele aceitaria perder.
4. Cite a fonte e o período. Se o período de um resultado for incerto, não use.

## 4. Quando resgatar: usar o dinheiro no fim ou aos poucos?

Compare as duas estratégias no simulador (mesmos aportes, resgates diferentes). Sem desconto por
pagamento antecipado, deixar o dinheiro aplicado por mais tempo rende mais, mas exige mais caixa no início.
Mostre a diferença em reais e o caixa mensal que cada estratégia pede.

Se o destino do dinheiro der desconto ou travar preço para quem paga antes, antecipar só compensa quando a
economia for maior que o rendimento perdido. Exemplo: com rendimento líquido de cerca de 0,85% ao mês, adiantar
uma parcela em 3 meses só compensa se a economia passar de cerca de 2,6% (3 x 0,85%). Confirme com o
destino (escola, fornecedor) se aceita pagamento parcial ou antecipado, em vez de supor.

## 5. Custódia do Tesouro Selic

A isenção de R$ 10 mil é por CPF, somando tudo que o investidor já tem em Tesouro Selic, inclusive em outras
instituições (confirme a regra atual no site do Tesouro Direto). Pergunte quanto ele já possui e use
`--externo` e `--custodia 0.2` no simulador para estimar o custo.
