# Critério de escolha de ferramenta

Este arquivo detalha o Passo 3 do SKILL.md. A ideia central: a ferramenta certa depende do que o usuário vai fazer com a peça depois — publicar direto, editar visualmente, ou apresentar em múltiplas páginas.

## Canva

**Use quando:**
- O usuário já tem (ou pede para usar) um brand kit configurado no Canva — cores, fontes e logo já definidos.
- O pedido é uma peça de redes sociais ou anúncio que deve sair pronta para publicar, sem etapa manual de edição depois.
- É preciso gerar várias variações rapidamente (ex.: 5 posts com a mesma copy em ângulos diferentes, ou o mesmo post em 3 tamanhos de plataforma).
- Existe um template de marca (brand template) que já resolve o layout — só falta encaixar a copy.

**Ferramentas típicas (nomes dos MCP tools disponíveis):**
- `list-brand-kits` — verificar se existe brand kit configurado antes de perguntar cores/fontes ao usuário.
- `search-brand-templates` — procurar um template de marca já pronto para o formato pedido.
- `create-design-from-brand-template` — gerar a peça a partir de um template de marca (preferível quando existe).
- `generate-design` / `generate-design-structured` — gerar do zero quando não há template aproveitável.
- `export-design` — exportar a peça final no formato de arquivo pedido (PNG, PDF, etc.).
- `get-export-formats` — conferir quais formatos de exportação estão disponíveis antes de prometer um ao usuário.

**Sinal de que Canva é a escolha errada:** o usuário quer poder arrastar elementos, editar texto campo a campo, ou não sabe ainda exatamente o layout que quer (está explorando) — nesses casos o canvas do Claude Design serve melhor porque é pensado para edição visual iterativa.

## Claude Design (skill `design`)

**Use quando:**
- O pedido é um mockup de UI, tela, fluxo de produto, ou wireframe.
- É um pôster, flyer, brochura, banner ou one-pager que o usuário prefere revisar e ajustar visualmente (clicar para selecionar, editar texto inline, mover elementos) em vez de receber pronto.
- Não há brand kit/Canva disponível e o usuário não tem uma identidade visual fixa ainda — o canvas permite explorar um layout sem compromisso com templates existentes.
- O usuário pede explicitamente algo para "mexer depois" ou "ver o rascunho antes de fechar".

**Como usar:** invoque a skill `design` (via Skill tool) passando a copy definida e o contexto de marca coletado. Ela publica o resultado como Artifact (canvas `.dc.html`) que o usuário pode refinar visualmente.

**Sinal de que não é a escolha certa:** o usuário quer o arquivo final pronto para postar imediatamente, sem etapa de edição manual — nesse caso prefira Canva (se houver identidade de marca) para não gerar um rascunho quando o pedido era uma entrega finalizada.

## Gamma

**Use quando:**
- O pedido é uma apresentação, deck, documento com múltiplas páginas/slides, ou uma webpage — não uma imagem/post único.
- A copy já está organizada em seções (ex.: capítulos de um documento, slides de um pitch) e precisa virar um formato navegável.

**Ferramentas típicas:** `generate` (a partir de um brief), `generate_from_template` (quando há um template do workspace), `generate_multi_page_gamma` para conteúdo com várias páginas.

**Sinal de que não é a escolha certa:** o pedido é uma peça única de imagem (post, anúncio, banner) — isso é Canva ou Claude Design, não Gamma.

## Quando o cenário é ambíguo

Se mais de uma ferramenta se encaixa igualmente bem (ex.: "quero um banner" sem dizer se é pronto ou rascunho), pergunte diretamente: "você quer a peça já pronta para publicar, ou prefere um rascunho para ajustar visualmente depois?" — essa única pergunta resolve a maioria dos casos ambíguos entre Canva e Claude Design.
