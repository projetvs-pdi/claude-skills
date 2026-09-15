---
name: criacao-conteudo-design
description: Transforma uma copy já finalizada (ex.: saída da skill criacao-conteudo-copy) em peças visuais prontas — posts para redes sociais, anúncios, banners, capas, apresentações ou mockups de página/produto. Use esta skill sempre que o usuário pedir para "criar a arte", "desenhar o post", "montar o design", "criar as peças gráficas", "fazer a identidade visual do post", "transformar essa copy em imagem/arte", "gerar as artes para publicar", "montar a apresentação/slide" ou qualquer pedido de produção visual a partir de um texto/copy já pronto — mesmo que o usuário não diga explicitamente "design" ou "designer". Dispare também quando o usuário disser que acabou de escrever a copy e agora quer "a parte visual" ou "colocar isso numa arte". Esta skill não escreve copy — se não houver texto de base, direcione para a criacao-conteudo-copy primeiro. Ela decide a ferramenta certa (Canva, Claude Design canvas, ou Gamma) de acordo com o cenário, em vez de usar sempre a mesma.
---

# Criação de Conteúdo / Design

Skill genérica de produção visual: parte de uma copy já pronta (ou fornecida pelo usuário) e produz peças gráficas finais — post social, anúncio, banner, capa, apresentação ou mockup — escolhendo a ferramenta de execução mais adequada a cada cenário, em vez de fixar uma só. Não escreve texto por conta própria; se a copy ainda não existir, direcione o usuário para a `criacao-conteudo-copy` antes de desenhar qualquer coisa.

## Por que a escolha da ferramenta não é fixa

Design, diferente de copy, depende muito do canal de saída: um post para Instagram carregado num brand kit do Canva pede uma ferramenta diferente de um mockup de página que o usuário quer refinar campo a campo, que por sua vez é diferente de um deck de apresentação. Forçar sempre a mesma ferramenta produz resultado pior em pelo menos um desses cenários. Por isso o Passo 3 existe: ele te dá o critério para escolher, e não uma regra de "sempre use X".

## Passo 1 — Confirmar a copy de base

Antes de desenhar qualquer coisa, garanta que existe texto pronto para colocar na peça:

- Se o usuário já colou a copy, apontou um arquivo, ou este é a continuação direta de uma `criacao-conteudo-copy` que rodou nesta mesma conversa, use esse conteúdo como base.
- Se não houver copy clara (só uma ideia solta, ou "quero um post sobre X"), pergunte se ele já tem o texto pronto ou se quer que você gere a copy primeiro (nesse caso, siga para a skill `criacao-conteudo-copy` antes de continuar aqui). Não invente headline, CTA ou corpo de texto — a copy final é responsabilidade da outra skill.

## Passo 2 — Coletar o contexto de design

Use `AskUserQuestion` (se disponível) para resolver isso rápido. Não pergunte o que já for óbvio a partir do pedido original ou do que já foi decidido na etapa de copy.

1. **Formato(s) de saída.** Post social (qual plataforma e qual formato — feed, story, carrossel?), anúncio, banner, capa, apresentação/deck, ou mockup de página/produto? Pode ser mais de um formato da mesma campanha.
2. **Identidade visual disponível.** Existe brand kit (cores, fontes, logo) já configurado em algum lugar (Canva, manual de marca, exemplos anteriores)? Se não houver nada, pergunte a paleta/tom visual desejado (ex.: minimalista, vibrante, corporativo) em vez de assumir.
3. **Quantidade e variações.** Uma peça única ou um lote (ex.: 5 variações de post, ou uma peça por plataforma)?
4. **Nível de acabamento esperado.** O usuário quer a peça finalizada pronta para publicar, ou um rascunho/mockup que ele mesmo vai ajustar visualmente depois? Isso influencia diretamente a escolha de ferramenta no Passo 3.

## Passo 3 — Escolher a ferramenta pelo cenário, não por hábito

Leia `references/ferramentas.md` para o critério completo de decisão. Resumo:

- **Canva** — quando existe brand kit/templates de marca para reaproveitar, quando o pedido é uma peça de redes sociais/anúncio com texto sobre imagem pronta para publicar, ou quando é preciso gerar/exportar várias variações rapidamente. Ferramentas: `search-brand-templates` / `list-brand-kits` para reaproveitar identidade existente, `generate-design` ou `create-design-from-brand-template` para gerar, `export-design` para entregar o arquivo final.
- **Claude Design (skill `design`)** — quando o pedido é um mockup de UI/página, um protótipo, um pôster/flyer/one-pager que o usuário prefere ajustar visualmente à mão (arrastar, editar texto inline) depois de gerado, ou quando não há brand kit/Canva disponível. Invoque a skill `design` para isso — ela publica um canvas editável como Artifact.
- **Gamma** — quando o pedido é uma apresentação, deck, documento com múltiplas páginas, ou webpage — não um post/imagem única.

Quando o cenário for ambíguo (ex.: usuário não deixou claro se quer algo pronto ou editável), pergunte antes de escolher em vez de assumir — a ferramenta errada aqui significa refazer o trabalho.

## Passo 4 — Gerar a peça

Com a ferramenta escolhida:

- **Canva**: confira `references/formatos.md` para as dimensões corretas por plataforma/formato antes de gerar. Se houver brand kit, prefira `create-design-from-brand-template` para manter consistência visual; use `generate-design` quando não houver template aproveitável. Sempre posicione a copy definida no Passo 1 dentro da peça — não reescreva o texto ao adaptá-lo ao layout, apenas ajuste quebras de linha/hierarquia visual quando necessário.
- **Claude Design**: invoque a skill `design`, passando a copy e o contexto de marca coletado no Passo 2 como input. Ela cuida do restante (artboards, canvas, Artifact).
- **Gamma**: use `generate` ou `generate_from_template`, passando a copy como conteúdo-base de cada seção/slide.

Se o usuário pediu mais de um formato, gere cada peça mantendo a mesma identidade visual (cores, fontes, tom) entre elas — peças da mesma campanha devem parecer da mesma campanha.

## Passo 5 — Entregar o resultado

Entregue cada peça com um link ou arquivo (dependendo da ferramenta usada) e uma linha dizendo qual ferramenta gerou aquela peça e por quê, para o usuário entender a escolha. Se alguma peça ficou como rascunho/editável (Claude Design canvas), avise isso explicitamente — não apresente um rascunho como se fosse a arte final pronta para publicar.

Ao final, pergunte se o usuário quer ajustar cores/layout, gerar variações adicionais, ou trocar de ferramenta para alguma peça específica — design, assim como copy, costuma ser iterativo.
