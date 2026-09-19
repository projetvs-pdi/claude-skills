---
name: pesquisa-conteudo-web
description: Pesquisa conteúdo na web sobre qualquer assunto que o usuário indicar e entrega um relatório em Markdown com resumo executivo, principais achados e fontes. Use esta skill sempre que o usuário pedir para "pesquisar sobre", "fazer uma pesquisa de mercado", "levantar informações sobre", "entender o cenário/concorrência de X", "buscar conteúdo/artigos/notícias sobre um tema", comparar um negócio com o mercado, ou qualquer pedido de investigação sobre um assunto específico usando fontes da internet — mesmo que o usuário não diga explicitamente "pesquisa". A skill é genérica: NUNCA presuma o assunto, sempre pergunte qual é o tema (e o nível de profundidade desejado) antes de começar, a menos que o usuário já tenha informado ambos na própria mensagem.
---

# Pesquisa de Conteúdo na Web

Skill genérica para pesquisar qualquer assunto na web e produzir um relatório organizado. Funciona para pesquisa de mercado, concorrência, tendências, temas técnicos, notícias, ou qualquer outro tópico — o assunto é sempre definido pelo usuário, nunca hardcoded aqui.

## Passo 1 — Confirmar o assunto e a profundidade

Antes de pesquisar, garanta que você tem duas informações. Se o usuário já deu essa informação na mensagem que disparou a skill, não pergunte de novo — apenas confirme rapidamente o entendimento e siga.

1. **Assunto exato da pesquisa.** Não assuma — pergunte especificamente o que o usuário quer entender. Se o pedido for vago (ex.: "pesquisa sobre meu mercado"), peça para detalhar: qual negócio/produto, qual ângulo (concorrentes? tamanho de mercado? tendências? preços?), e qualquer contexto que ajude a mirar a busca (região, público-alvo, período de tempo relevante).
2. **Profundidade desejada.** Pergunte se o usuário quer uma pesquisa **rápida** (poucas fontes, visão geral) ou **aprofundada** (mais fontes, cruzamento de dados, maior confiabilidade). Isso muda quantas buscas e quanto tempo você vai investir.

Use a ferramenta de pergunta ao usuário (AskUserQuestion, se disponível) para isso — é mais rápido para o usuário responder do que escrever um parágrafo.

## Passo 2 — Escolher as ferramentas de pesquisa

Use as ferramentas de pesquisa já disponíveis nesta sessão, na seguinte ordem de preferência (pule qualquer uma que não esteja disponível no ambiente atual — não é necessário instalar nada):

1. **Firecrawl** (`firecrawl_search`, `firecrawl_developer_search`, `firecrawl_research_search_papers` e variantes) — preferido quando disponível, porque devolve conteúdo já extraído das páginas, não só links.
   - `firecrawl_search`: busca geral na web. Use `categories: ["developer"]` ou `["research"]` para inclinar os resultados a fontes técnicas ou acadêmicas quando fizer sentido.
   - `firecrawl_developer_search`: quando o assunto é técnico (bibliotecas, APIs, ferramentas de código, comparação de stacks).
   - `firecrawl_research_search_papers` / `firecrawl_research_read_paper` / `firecrawl_research_related_papers`: quando o assunto é científico, acadêmico ou precisa de embasamento em papers (ex.: pesquisa clínica, estudos de mercado com base acadêmica).
2. **WebSearch** — use como alternativa ou complemento quando Firecrawl não estiver disponível ou não cobrir bem o tema (ex.: notícias muito recentes, blogs regionais, fóruns).
3. **WebFetch** — depois de identificar URLs relevantes (via Firecrawl ou WebSearch), use para ler o conteúdo completo de uma página específica quando o resumo da busca não for suficiente.

Se, mesmo combinando essas ferramentas, você não conseguir cobrir bem o assunto (tema muito de nicho, sem cobertura na internet), diga isso ao usuário em vez de inventar informação — e ofereça pesquisar um ângulo adjacente ou pedir mais contexto.

## Passo 3 — Executar a pesquisa

Faça múltiplas buscas com variações de termos (sinônimos, termos em português e inglês quando fizer sentido, nomes de concorrentes específicos se o usuário mencionar) em vez de uma única query genérica — isso evita relatórios rasos baseados em uma só fonte.

Quantidade de buscas / fontes por nível de profundidade:
- **Rápida**: 3-5 buscas, 5-8 fontes distintas.
- **Aprofundada**: 6-10+ buscas cobrindo ângulos diferentes (visão geral, concorrentes, dados/números, opiniões/análises, notícias recentes), 10-20 fontes distintas, cruzando informação entre pelo menos duas fontes para qualquer afirmação relevante.

Priorize fontes primárias e recentes. Ao encontrar informações conflitantes entre fontes, registre o conflito no relatório em vez de escolher uma arbitrariamente.

## Passo 4 — Montar o relatório

Entregue o resultado como um relatório em Markdown, direto na conversa (não como arquivo, a menos que o usuário peça um arquivo). Use sempre esta estrutura:

```markdown
# Pesquisa: [Assunto]

## Resumo executivo
[2-4 frases com a conclusão principal — o que o usuário mais precisa saber]

## Principais achados
- [Achado 1, com contexto suficiente para ser útil sozinho]
- [Achado 2]
- ...

## Análise / comparação
[Se o pedido envolver comparação — ex.: negócio do usuário vs. mercado/concorrência — inclua aqui uma seção comparativa explícita: pontos fortes, gaps, oportunidades.]

## Pontos de atenção / incertezas
[Informações conflitantes entre fontes, dados desatualizados, ou áreas onde a pesquisa não encontrou cobertura suficiente]

## Fontes
1. [Título da fonte](URL) — data, se disponível
2. ...
```

Adapte as seções ao contexto: se não houver comparação a fazer, omita essa seção. Se o assunto for simples e a pesquisa rápida, o relatório pode ser mais curto — não force todas as seções a terem conteúdo artificial.

## Boas práticas

- Sempre cite a fonte de cada achado relevante — não apresente números ou afirmações fortes sem link de origem.
- Não reproduza texto extenso das fontes (respeite direitos autorais) — sintetize com suas próprias palavras, usando no máximo uma citação curta (menos de 15 palavras) por fonte, entre aspas e com atribuição.
- Se o usuário pedir para comparar o próprio negócio com o mercado, peça (se ainda não souber) informações mínimas sobre o negócio dele para poder comparar de forma específica, em vez de genérica.
- Ao final, pergunte se o usuário quer aprofundar algum achado específico ou ajustar o foco da pesquisa — pesquisa de mercado costuma ser iterativa.
