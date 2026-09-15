---
name: criacao-conteudo-copy
description: Transforma um relatório de pesquisa (ex.: saída da skill pesquisa-conteudo-web) ou qualquer material bruto em copy final — pronta para publicar — para posts de redes sociais, e-mail marketing, anúncios, ou páginas de site institucional (home, sobre, serviços, landing page). Use esta skill sempre que o usuário pedir para "transformar essa pesquisa em conteúdo", "escrever os posts", "criar a copy do site", "redigir os e-mails", "montar a legenda/anúncio", "dar forma final ao texto para publicar" ou qualquer pedido de redação persuasiva/comercial a partir de informações já levantadas — mesmo que ele não use a palavra "copy" ou "copywriting" explicitamente. Dispare também quando o usuário mencionar que acabou de pesquisar algo e agora quer "usar isso" para criar conteúdo. Esta skill roda tipicamente DEPOIS da pesquisa-conteudo-web (que entrega o relatório) — não faz pesquisa própria, apenas escreve a partir do material fornecido.
---

# Criação de Conteúdo / Copy

Skill genérica de copywriting: parte de um material já pesquisado ou fornecido pelo usuário e produz textos finais, prontos para publicar, em qualquer formato — post social, e-mail, anúncio, ou página de site institucional. Não pesquisa nada por conta própria; se não houver material de base suficiente, peça ao usuário para apontar o relatório (ex.: o que a `pesquisa-conteudo-web` gerou) ou colar o conteúdo bruto antes de escrever.

## Por que a ordem dos passos importa

Copy ruim quase sempre nasce de pular a etapa de contexto e ir direto para "escrever bonito". As melhores skills de copywriting do mercado (analisadas antes de criar esta) convergem num ponto: a qualidade do texto final depende mais do que você sabe sobre o leitor e a oferta do que da fórmula retórica escolhida. Por isso, colete contexto antes de escrever — não porque é uma regra arbitrária, mas porque um CTA "perfeito" para o público errado, ou um tom informal para uma clínica jurídica, não converte independente de quão bem escrito esteja.

## Passo 1 — Confirmar o material de base

Antes de escrever qualquer coisa, garanta que você tem o material de origem:

- Se o usuário já apontou um arquivo, colou um relatório, ou este é a continuação direta de uma pesquisa que rodou nesta mesma conversa, use esse conteúdo como base.
- Se não houver material claro, pergunte ao usuário onde está o relatório ou conteúdo bruto (ex.: "qual arquivo/relatório da pesquisa devo usar como base?") — não invente fatos, números ou diferenciais que não estejam no material fornecido nem na resposta do usuário.

## Passo 2 — Coletar o contexto de escrita

Use `AskUserQuestion` (se disponível) para resolver rapidamente o que for necessário — é mais rápido para o usuário do que escrever um parágrafo. Não pergunte o que já for óbvio a partir do pedido original ou do material de base.

1. **Formato(s) de saída.** Post social (qual plataforma?), e-mail marketing (peça única ou sequência?), anúncio, ou página de site institucional (qual página: home, sobre, serviços, landing page)? Pode ser mais de um.
2. **Objetivo/ação desejada.** O que o leitor deve fazer ao final (comprar, agendar, responder, clicar, se cadastrar, etc.)?
3. **Tom de voz.** Sempre perguntar quando não houver manual de marca ou exemplo anterior do usuário nesta conversa — o tom certo varia demais entre um negócio e outro para assumir um padrão (ex.: direto e vendedor vs. institucional e formal vs. leve e bem-humorado).
4. **Público e nível de consciência.** Quem vai ler, e o quanto essa pessoa já conhece o problema/produto (frio, já conhece o problema, já conhece a solução, já considera comprar). Isso muda o quanto o texto precisa "educar" antes de vender.

## Passo 3 — Escolher o framework pelo contexto, não por hábito

Não force sempre o mesmo framework retórico. Leia `references/frameworks.md` para os detalhes de cada um (PAS, AIDA, BAB, 4 Ps, QUEST) e escolha com base no formato e no nível de consciência do público:

- Público frio / anúncio / post curto → geralmente **PAS** (Problema → Agitar → Solução).
- Página institucional / apresentação de marca → geralmente **AIDA**.
- Prova social, case, testemunho → geralmente **BAB** (Antes → Depois → Ponte).
- Página de vendas / oferta com prova extensa → geralmente **4 Ps** (Promessa → Retrato → Prova → Chamada).
- Conteúdo educativo longo (artigo, e-mail de nutrição) → geralmente **QUEST**.

Está tudo bem combinar frameworks dentro de uma mesma peça (ex.: abrir com PAS e fechar com uma chamada no estilo 4 Ps) — a fórmula é um ponto de partida, não uma camisa de força.

## Passo 4 — Escrever por formato

Leia `references/formatos.md` para os templates e convenções específicas de cada formato (estrutura de post por plataforma, estrutura de e-mail e assunto, estrutura de página institucional, fórmulas de headline e de CTA). Ele cobre:

- Posts de redes sociais (Instagram, LinkedIn, X/Twitter, Facebook)
- E-mail marketing (assunto, corpo único, sequência)
- Anúncios (texto principal + headline)
- Páginas de site institucional (home, sobre, serviços, landing page)

## Princípios de escrita (valem para qualquer formato)

- **Clareza acima de criatividade.** Se tiver que escolher entre uma frase clara e uma frase criativa, escolha a clara.
- **Benefício, não característica.** Não diga o que o produto/serviço *é*; diga o que ele *muda* para quem lê.
- **Especificidade vence generalidade.** "Atendemos em até 24h" convence mais que "atendimento rápido".
- **Linguagem do leitor, não da empresa.** Use as palavras que o público usaria para descrever o próprio problema, não o jargão interno do negócio.
- **Honestidade.** Nunca invente números, prova social ou diferenciais que não estejam no material de base fornecido. Se faltar prova concreta, escreva sem ela em vez de fabricá-la, e avise o usuário que aquele ponto ficou sem sustentação.
- **CTA forte:** [verbo de ação] + [o que a pessoa ganha] + [qualificador quando ajudar a reduzir fricção]. Ex.: "Agende sua avaliação gratuita" em vez de "Clique aqui".

## Passo 5 — Entregar o resultado

Entregue a copy final como um arquivo Markdown (Artifact), organizado por formato/canal, para o usuário revisar e copiar. Estrutura:

```markdown
# Copy: [Assunto/Campanha]

## [Formato 1 — ex. Post Instagram]
[Texto final pronto para publicar]

**Alternativas de headline/abertura:**
1. ...
2. ...

## [Formato 2 — ex. E-mail]
**Assunto:** ...
[Corpo do e-mail]

...
```

Para cada peça de headline, abertura ou CTA de alto impacto, ofereça 2-3 alternativas com uma linha explicando a diferença de ângulo entre elas (não só variações estéticas da mesma ideia). Se algum ponto do texto dependeu de uma suposição (porque o material de base não tinha aquela informação), sinalize isso ao usuário em vez de deixar como se fosse fato confirmado.

Ao final, pergunte se o usuário quer ajustar o tom, testar outro framework, ou gerar variações A/B de algum trecho específico — copy costuma ser iterativa.
