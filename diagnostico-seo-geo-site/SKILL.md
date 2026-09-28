---
name: diagnostico-seo-geo-site
description: Age como especialista de SEO e GEO (otimização para respostas de IA generativas, como ChatGPT/Perplexity/Gemini) de um site já publicado — diagnostica bloqueios técnicos, pesquisa as melhores palavras-chave e termos para aquele negócio específico (com base em concorrência real e prática de mercado, buscando a primeira página de resultados), propõe um plano completo de correção de conteúdo e código, e — só depois que o usuário confirmar os termos e as mudanças — aplica no código-fonte, publica, e finaliza os cadastros necessários para o efeito completo (Google Search Console, Bing Webmaster Tools e afins). Use esta skill sempre que o usuário pedir para "avaliar o SEO do site", "analisar SEO e GEO", "fazer um diagnóstico de SEO", "por que meu site não aparece no Google", "como melhorar o posicionamento no Google", "meu site não é indexado", "otimizar para IA/ChatGPT encontrar meu negócio", "corrigir o SEO do site", "colocar o site na primeira página", "ajustar o SEO e publicar", ou simplesmente citar um domínio pedindo uma avaliação/opinião sobre ele — mesmo que o usuário não use os termos técnicos "SEO" ou "GEO" explicitamente. Nunca edita nem publica nada sem antes apresentar um relatório com os termos/mudanças propostos e obter confirmação explícita do usuário.
---

# Diagnóstico e Otimização de SEO e GEO de um Site

## Por que esta skill existe

A causa mais comum de um site "não aparecer no Google" não é falta de conteúdo bonito — é um bloqueio técnico simples (um `robots.txt` errado, uma tag `noindex` esquecida de um ambiente de teste) que torna todo o resto do trabalho de SEO inútil. Mas resolver só o bloqueio técnico deixa o site "indexável, porém genérico" — não é suficiente para aparecer bem posicionado. Esta skill vai além do diagnóstico técnico: atua como a parte que detém o conhecimento de mercado sobre quais termos/palavras-chave realmente colocam esse negócio específico bem posicionado (baseado em concorrência real, intenção de busca, e prática corrente de SEO/GEO) — não apenas corrige bloqueios, mas propõe a melhor estratégia de termos para aquele site, e depois executa de ponta a ponta: aplica no código, publica, e finaliza os cadastros externos (Search Console e afins) que fazem a otimização ter efeito de verdade.

A skill tem três fases, cada uma separada da próxima por uma confirmação do usuário:

1. **Diagnóstico + pesquisa de termos** (Passos 1-4): investiga o site publicado, pesquisa concorrência e intenção de busca, e propõe os melhores termos/conteúdo para aquele negócio — sem editar nada ainda.
2. **Aplicação e publicação** (Passos 5-8): só começa depois que o usuário aprovar os termos propostos. Edita o código, valida com build local, mostra o diff, publica.
3. **Efetivação externa** (Passo 9): registra/verifica o site nos mecanismos de busca necessários para a otimização realmente valer (Google Search Console, Bing Webmaster Tools, e o que mais fizer sentido) — só depois que o site já estiver publicado com as mudanças.

## Guardrails (regras de segurança)

- **Nunca edite arquivos, nunca rode deploy, nunca faça commit/push sem confirmação explícita do usuário** — mesmo que ele peça tudo numa única mensagem ("corrija e publique o SEO"). Entregue primeiro o relatório com os termos propostos; a aprovação desses termos específicos é o que autoriza seguir para a edição, não o pedido genérico inicial.
- **Os termos propostos (title, description, palavras-chave, conteúdo novo) são uma proposta, não um fato** — apresente-os como recomendação fundamentada (com a lógica por trás: por que esse termo, o que a concorrência usa, qual intenção de busca ele captura), e dê ao usuário a chance de ajustar antes de aplicar. Ele conhece o negócio melhor do que qualquer busca consegue revelar.
- Antes de editar qualquer arquivo, confirme onde está o código-fonte (repositório Git ou pasta local) — não adivinhe nem assuma uma estrutura de projeto sem checar.
- **Sempre valide as mudanças com um build local** (ex.: `npm run build` ou equivalente do projeto) antes de comitar — um SEO "corrigido" que quebra o build é pior que o problema original.
- **Sempre mostre o diff (`git diff`) e peça confirmação explícita antes de `git commit`/`git push`** — publicar/enviar código para o repositório remoto é uma ação visível e difícil de desfazer de forma limpa.
- **Antes de publicar (deploy), confirme com o usuário** — mesmo que ele já tenha aprovado o diff/commit, publicar no site ao vivo é uma etapa própria que merece sua própria confirmação, especialmente se for a etapa que chama `atualizar-deploy-cloudflare-pages`.
- Nunca peça, armazene, ou tente extrair/editar credenciais (token do CloudFlare, senha de Git, token de API) por conta própria — se o acesso falhar por permissão, explique o que falta e peça para o usuário resolver (ex.: ajustar escopo do token no próprio dashboard), em vez de tentar contornar.
- Não invente dados: se uma checagem falhar (ex.: URL não responde, busca não retorna nada), reporte isso como "não foi possível verificar", não como "está tudo certo". Da mesma forma, nunca invente endereço, telefone, horário ou qualquer dado factual do negócio para preencher dados estruturados — use só o que está confirmado no próprio site ou que o usuário informar.

## Passo 1 — Confirmar o domínio e entender o negócio

Se o usuário já informou o domínio, não pergunte de novo. Se não informou, pergunte qual é. Diferente de um diagnóstico puramente técnico, aqui vale entender rapidamente (a partir do próprio conteúdo do site, sem precisar interrogar o usuário) qual é o negócio, os serviços oferecidos, e a região/público atendido — essa é a base para a pesquisa de termos do Passo 3.

## Passo 2 — Diagnóstico técnico

Busque cada um destes itens via scrape/fetch direto das URLs do domínio informado (requisição "fresca", sem cache):

1. **`robots.txt`** — verifique `Disallow` bloqueando o site inteiro ou seções relevantes. Achado mais crítico possível: se bloquear tudo, nada mais importa até corrigir isso.
2. **Meta tag `robots` no HTML** — `noindex`/`nofollow` no `<head>`, independente do `robots.txt` (cheque os dois separadamente).
3. **`<html lang="...">`** — deve corresponder ao idioma real do conteúdo.
4. **`sitemap.xml`** — existe e é um XML de sitemap válido? (Cuidado com SPAs que devolvem a home como fallback de rota em qualquer URL.)
5. **Metadados** — `title`, `meta description`, `og:title`, `og:description`, `canonical`.
6. **Dados estruturados (JSON-LD)** — tipo apropriado ao negócio (`LocalBusiness`, `MedicalBusiness`, `Restaurant`, etc.) com nome, endereço, telefone, horário.
7. **Estrutura de headings** — H1 único e coerente, hierarquia H2/H3.
8. **Atributos `alt`** das imagens.
9. **Status de indexação real** — busca `site:dominio.com.br`; "No information is available" ou zero resultados confirma bloqueio efetivo.
10. **Sinal de SPA client-side-rendered** — pouco conteúdo textual no HTML bruto é um risco para crawlers/IAs que não executam JS.
11. **Páginas internas sem URL própria** — em SPAs, "Sobre", "Serviços", "Contato" etc. podem ser só trocas de estado na mesma URL (menu feito de `<button onClick>` em vez de `<a href>`). Nesse caso o Google só enxerga a home e todo o conteúdo interno fica fora do índice. Confirme lendo o código-fonte quando tiver acesso (o scrape da home não revela isso). A correção que funcionou em projeto Vite + React sem dependência nova: rotas reais com metadados por página, menu com `<a href>` + `history.pushState`, e pré-renderização de cada rota no `build` (gerando `dist/<rota>.html`, que o CloudFlare Pages serve com URL limpa), com o cliente hidratando o HTML existente.

## Passo 3 — Pesquisa de mercado e definição dos melhores termos

Esta é a etapa que faz a diferença entre "o site ficou indexável" e "o site tem chance real de aparecer bem posicionado". Não proponha termos genéricos — pesquise:

1. **Descubra a concorrência real**: faça buscas pelos serviços + região que o negócio atende (ex.: "[serviço principal] em [cidade]", variações com sinônimos e termos que um cliente real digitaria, não só termos técnicos). Anote quais concorrentes aparecem bem posicionados e, quando possível, olhe o `title`/`meta description` deles (via scrape rápido) para entender o padrão de linguagem que o Google já está recompensando naquele nicho.
2. **Identifique o padrão de intenção de busca**: termos "cabeça" (ex.: "clínica em Manaus") tendem a ter muita concorrência e pouca especificidade; termos de cauda longa (ex.: "fisioterapia infantil para atraso motor em Manaus") têm menos concorrência e capturam intenção mais qualificada. Um bom plano de termos usa os dois: título/description mais gerais (para volume) e conteúdo interno/FAQ com cauda longa (para conversão e para GEO).
3. **Cruze com o que o site já oferece**: liste os serviços/diferenciais reais do negócio (extraídos do próprio conteúdo) e combine com os termos de maior potencial encontrados na pesquisa — nunca proponha um termo que o negócio não ofereça de fato.
4. **Defina, com base nisso**:
   - Um `title` e `meta description` otimizados (concisos, com o termo de maior intenção comercial + região, sem keyword stuffing).
   - Uma lista curta de palavras-chave secundárias/cauda longa para orientar conteúdo futuro (FAQ, páginas por serviço).
   - Os campos de dados estruturados (Schema.org) mais relevantes ao tipo de negócio.
   - Se fizer sentido pelo diagnóstico do Passo 2 (site raso, sem FAQ), sugira 2-3 blocos de conteúdo citável (perguntas reais + resposta objetiva) que ajudam tanto SEO de cauda longa quanto GEO — mas isso entra como sugestão de conteúdo futuro, não precisa ser implementado nesta mesma rodada a menos que o usuário peça.

Não pule esta etapa mesmo sob pressão de tempo — é o que diferencia esta skill de um simples "linter técnico de SEO".

## Passo 4 — Montar o relatório e a proposta de termos

Entregue direto na conversa (Markdown), a menos que o usuário peça arquivo ou for compartilhar com terceiros. Use esta estrutura:

```markdown
## Avaliação de SEO/GEO — [domínio]

### 🚨 Bloqueadores críticos (se houver)
[Achados de robots.txt/noindex, em destaque]

### Achados técnicos
| Item | Situação | Impacto |
|---|---|---|

### Concorrência e intenção de busca
[O que a pesquisa do Passo 3 encontrou: concorrentes, padrões de linguagem, termos de maior potencial]

### Termos propostos
- **Title:** "..."
- **Meta description:** "..."
- **Palavras-chave secundárias/cauda longa:** ...
- **Dados estruturados propostos:** [campos e valores, só com dados confirmados]
- **Sugestões de conteúdo futuro (opcional):** [FAQ/páginas por serviço, se aplicável]

### Plano de ação priorizado
1. [Crítico — bloqueios técnicos]
2. [Importante — termos e dados estruturados]
3. [Nice-to-have — conteúdo futuro]
```

Ao final, pergunte explicitamente se o usuário aprova os termos propostos (ou quer ajustar algo) antes de aplicar qualquer mudança no código. Só depois dessa aprovação específica siga para o Passo 5 — mesmo que o pedido inicial já tenha sido "corrija e publique".

## Passo 5 — Localizar e editar o código-fonte

Só chegue aqui depois que o usuário aprovar os termos do Passo 4.

1. **Descobrir onde está o código-fonte**: repositório Git (peça a URL) ou pasta local. Se precisar clonar, use o diretório de scratchpad da sessão. Se o SSH falhar por permissão, verifique se existe um host alias específico em `~/.ssh/config` para aquela organização/conta antes de desistir.
2. **Entender como o site gera `robots.txt`, a meta `robots`, o `lang` e os metadados** antes de editar — varia por stack:
   - `robots.txt`/meta tag estáticos em `public/` ou no HTML/template — edite direto.
   - Site gerado por ferramenta com config central (ex.: Figma Make, `.figma/make/site.json` com campo `robots.index`) — edite a config, nunca o HTML gerado (seria sobrescrito no próximo build).
   - Procure esse padrão de config central antes de editar — evita duplicar a correção e é mais robusto a builds futuros.
3. **Aplicar as mudanças aprovadas**: liberar indexação, corrigir `lang`, criar/corrigir `sitemap.xml`, aplicar o `title`/`description` e os dados estruturados definidos no Passo 4 exatamente como aprovados (ou com os ajustes que o usuário pediu).
4. **Validar com build local**: rode o comando de build do projeto e confira o HTML/arquivos gerados (`dist/` ou equivalente) — não assuma que a config teve o efeito esperado sem checar a saída.

## Passo 6 — Revisar e confirmar antes de publicar no repositório

1. Rode `git status` e `git diff` e mostre ao usuário um resumo do que vai mudar.
2. **Peça confirmação explícita antes de `git commit` e `git push`.**
3. Comite com mensagem descritiva e faça push para o branch atual.

## Passo 7 — Publicar (deploy)

Confirme com o usuário antes de publicar. Se o site for CloudFlare Pages, chame `atualizar-deploy-cloudflare-pages` (ou verifique se o projeto já tem deploy automático via integração Git — nesse caso o push do Passo 6 já dispara o deploy sozinho; confirme o status do deployment antes de assumir que terminou). Se for outro provedor, identifique e informe o usuário o que esperar.

## Passo 8 — Validar em produção

Depois do deploy confirmado com sucesso, refaça uma checagem rápida (fresca, sem cache) dos itens corrigidos direto no domínio de produção — `robots.txt`, meta tags, `lang`, `sitemap.xml`, dados estruturados — para confirmar que o que foi publicado é realmente o que foi planejado, antes de dar o trabalho por concluído.

## Passo 9 — Efetivar nos mecanismos de busca

Corrigir o site não basta sozinho — os mecanismos de busca precisam ser avisados/reverificados para o efeito completo. Depois que o Passo 8 confirmar que as mudanças estão no ar:

### 9.1 Google Search Console
- Verifique se já existe uma propriedade para o domínio (com ou sem `www`, conforme o domínio canônico do site). Se não existir, crie uma propriedade do tipo "Prefixo do URL" e verifique via **Tag HTML** — é o método mais simples de automatizar: pegue a meta tag de verificação, adicione-a ao código-fonte (mesmo mecanismo do Passo 5, ex. `customScripts.headStart` se for config central) e publique (Passos 6-8) antes de clicar em "Verificar".
- Depois de verificada, submeta o `sitemap.xml` em **Sitemaps**.
- Se o site sofreu bloqueio de indexação por muito tempo, considere também usar a **Inspeção de URL** para solicitar reindexação imediata da home, em vez de esperar o crawl natural.

### 9.2 Bing Webmaster Tools
Se o usuário topar, repita o mesmo processo (verificação + submissão de sitemap); o Bing também alimenta a Copilot/IA da Microsoft, relevante para GEO. Pergunte se o usuário quer isso antes de navegar até lá (é outra conta/login).

### 9.3 Google Business Profile
Se o negócio for local (a maioria dos casos desta skill), o Google Business Profile é uma oportunidade direta de comunicar termos de SEO/GEO e dados estruturados ao Google. Ao contrário de Search Console (que é automático), o GBP é edited manualmente, e esta skill pode guiar o usuário:

**9.3.1 — Verificar existência e propriedade**
- Pergunte ao usuário: "O negócio já tem um Google Business Profile (ficha no Google Maps/Pesquisa)? Você tem acesso para editá-lo?"
- Se não existir ou não tiver acesso: sinalize a recomendação, mas não tente reivindicar/criar — isso depende do usuário.
- Se tiver acesso (ou quiser solicitar acesso): prossiga.

**9.3.2 — Listar edições propostas** (sem editar ainda)
Prepare um plano de edições com base nos dados do site e nos termos aprovados no Passo 4:
- **Campo "Site"**: URL do domínio canônico (ex. `https://www.seudominio.com.br`)
- **Categorias**: adicionar categorias secundárias relevantes aos serviços/especialidades (ex.: Fisioterapeuta, Fonoaudiólogo, Terapeuta Ocupacional, Psicólogo, etc.)
- **Descrição**: atualizar com os termos de SEO/GEO aprovados (mesmos da Passo 4), sem alterar NAP (Nome/Endereço/Telefone) já que deve permanecer idêntico ao do site
- **NAP**: conferir se está correto; se precisar corrigir, faça isso também

Mostre ao usuário exatamente o que será editado e peça confirmação explícita: "Vou editar os seguintes campos no perfil (lista). Confirma?"

**9.3.3 — Editar via navegador**
Use o navegador (Google Maps → "Editar" ou `search.google.com/business`) para cada campo:
1. Abra o campo
2. Mostre exatamente o novo valor que será inserido
3. Peça confirmação: "Vou digitar [valor]. Confirma?"
4. Edite e salve
5. O Google exibirá "Sua edição está pendente de revisão" (geralmente ~10 minutos de análise)

Não edite múltiplos campos de uma vez — faça um por vez, com confirmação do usuário entre eles.

**9.3.4 — Nunca reivindicar sem permissão explícita**
Se o usuário disser que o perfil pertence a outra conta/pessoa:
- Não tente assumir propriedade ou fazer edições
- Ofereça a opção de "Solicitar acesso" (existe no interface do Google) — o dono receberá um convite para compartilhar a propriedade
- Só edite depois que a transferência/permissão estiver confirmada

### 9.4 Resumo final
Resuma tudo o que foi feito:
- **Técnico**: correções de bloqueios, metadados, estrutura, dados estruturados
- **Termos aplicados**: título, description, palavras-chave do site
- **Publicação**: site atualizado e no ar
- **Cadastros externos**: 
  - Google Search Console (sitemap submetido, URLs submetidas para reindexação)
  - Bing Webmaster Tools (se aplicável)
  - Google Business Profile (edições pendentes de revisão, ~10 min)

**Prazo realista**: Reindexação e reposicionamento no Google levam de 1-4 semanas, mesmo com tudo correto — não é instantâneo. O GBP geralmente reflete mudanças em ~10 minutos, mas o impacto em ranqueamento também leva dias a semanas.

## Boas práticas

- Sempre confirme achados críticos (robots.txt, meta noindex) com uma segunda checagem independente (ex.: resultado do `site:` no Google) antes de afirmar com certeza que o site está bloqueado.
- Toda proposta de termo/palavra-chave deve vir de pesquisa real feita nesta conversa (concorrência, buscas) — nunca de suposição genérica sobre "o que costuma funcionar" para esse tipo de negócio.
- Se o domínio não responder, estiver fora do ar, ou as ferramentas de busca/scrape não estiverem disponíveis, diga isso claramente em vez de gerar um relatório incompleto sem avisar.
- Ao usar o navegador para tarefas como Google Search Console/Bing Webmaster Tools, lembre que a sessão logada é do usuário — nunca faça logout, troque de conta, ou aja além do que a tarefa pede.
