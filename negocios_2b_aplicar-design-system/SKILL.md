---
name: aplicar-design-system
description: Princípios e práticas de design system para construir ou ajustar interfaces de desktop e celular com consistência — tokens (cor, tipografia, espaço, forma, elevação, movimento), componentes e variantes, estados, responsividade mobile-first, acessibilidade, feedback e microcopy, governança e verificação. Use ao criar telas ou componentes, definir ou revisar tema, padronizar telas antigas, ou quando a interface parecer inconsistente. Complementa desenhar-interface (que cuida da regra na tela); este cuida de como a tela é construída visualmente.
---

# Aplicar design system

Um design system é a **fonte única** de decisões visuais e de comportamento. Telas novas **consomem** o sistema; não inventam valores. Antes de qualquer tela: ler o tema, os tokens e o guia de padrões do projeto e **reaproveitar o que existe**. Só criar algo novo quando nada existente serve — e então criar no sistema, não na tela.

## 1. Camadas (de baixo para cima)

1. **Tokens** — valores nomeados: cor, tipografia, espaçamento, raio, sombra, movimento, breakpoints.
2. **Componentes base** — botão, campo, seleção, diálogo, alerta, tabela/lista, chip, menu.
3. **Padrões** — composições recorrentes: formulário, lista com filtros, confirmação em duas etapas, estado vazio, aviso ao afetado.
4. **Telas** — só montam padrões e componentes.

Uma decisão visual mora em **uma** camada. Se a tela precisa repetir um estilo, ele sobe para componente ou padrão.

## 2. Tokens

- **Nunca valor solto na tela** (`#1976d2`, `13px`, `margin: 7px`). Sempre token do tema.
- **Semânticos, não literais.** `cor.perigo`, `cor.texto.secundario`, `espaco.3` — não `vermelho`, `cinza-600`. O significado permite trocar o valor (tema escuro, marca nova) sem tocar nas telas.
- **Cor**
  - Papéis: primária, secundária, sucesso, atenção, perigo, informação, neutros (fundo, superfície, borda, texto).
  - Estados de cada papel: normal, hover, pressionado, desabilitado, foco.
  - **Cor nunca é o único sinal** (acompanha ícone, texto ou forma). Status do domínio (ex.: situação de um pedido ou agendamento) tem um mapa único de cor + rótulo + ícone, reutilizado em todas as telas.
  - Contraste mínimo WCAG AA: 4,5:1 para texto normal; 3:1 para texto grande e componentes de interface. Verificar nos dois temas.
  - Tema claro e escuro desde o início, pelos mesmos tokens.
- **Tipografia:** escala curta e fixa (título de página, seção, subtítulo, corpo, apoio, legenda), com tamanho, peso e entrelinha por nível. Informação de apoio usa o **mesmo tamanho do cabeçalho a que pertence**, com peso menor — não um tamanho novo. Campos no celular com fonte ≥ 16 px (evita zoom automático).
- **Espaçamento:** uma escala (ex.: múltiplos de 4 ou 8). Distância entre itens relacionados < distância entre grupos.
- **Forma e elevação:** poucos raios e poucos níveis de sombra, cada um com função clara (cartão, menu, diálogo).
- **Movimento:** curto (100–250 ms), com propósito (mostrar origem/destino, confirmar), respeitando `prefers-reduced-motion`.
- **Breakpoints:** poucos e nomeados (celular, tablet, desktop). O layout decide pela largura, não por detectar aparelho.

## 3. Componentes

- **Um componente, uma função.** Botão primário (uma ação principal por área), secundário, texto, destrutivo. Não criar variante por tela.
- **API pequena e previsível:** variantes e tamanhos por propriedade, não por estilo solto; conteúdo por `children`/slots.
- **Estados completos em todo componente interativo:** repouso, hover, foco visível, pressionado, desabilitado, carregando, erro, sucesso. Desabilitado **explica o motivo** quando a pessoa pode querer saber.
- **Campos:** rótulo sempre visível (não só placeholder); ajuda e erro junto ao campo; obrigatoriedade indicada sempre do mesmo jeito; teclado certo no celular (numérico, e-mail, telefone); máscara e validação cedo, sem travar a digitação.
- **Feedback proporcional ao peso:**
  - inline junto ao campo — erro de preenchimento;
  - alerta na tela — situação que afeta o que a pessoa está vendo;
  - toast curto — confirmação de ação concluída, sem exigir ação;
  - diálogo — decisão que exige confirmação ou tem efeito amplo.
- **Ícones:** um conjunto só, tamanhos da escala, sempre com rótulo acessível; ícone sozinho só quando universal.
- **Listas e tabelas:** densidade definida (confortável/compacta); ordenação e filtros no mesmo lugar em todas as telas; vazio e carregando previstos.

## 4. Responsivo: mobile-first

1. **Projetar primeiro a menor largura** e ampliar; o inverso gera telas que quebram no celular.
2. **Mesma informação, outra composição.** Desktop pode ter colunas, tabela e painel lateral; celular vira uma coluna, cartões, folha inferior ou tela cheia. Não esconder conteúdo essencial só porque a tela é pequena.
3. **Alvos de toque ≥ 44×44 px** (48 px é o confortável), com espaço entre eles. Ação principal ao alcance do polegar.
4. **Ações secundárias em menu (⋮)** no celular; no desktop podem ficar visíveis.
5. **Tabela vira cartões** no celular, mantendo a identificação completa (nome inteiro, quebrando linha, sem reticências).
6. **Diálogo vira tela cheia ou folha inferior** no celular; fechar sempre alcançável.
7. **Sem rolagem lateral** na página (só dentro de um componente que a justifique, como tabela larga). Testar de forma automática.
8. **Entrada para toque:** nada depende de hover ou clique direito; teclado virtual não cobre o campo ativo nem o botão de enviar.
9. **Desempenho percebido:** esqueleto ou indicador ao carregar; listas longas paginadas ou virtualizadas; espaço reservado para imagens (sem salto de layout).
10. **Navegação:** desktop com menu persistente; celular com menu recolhido ou barra inferior para poucos destinos; sempre mostrar onde a pessoa está e como voltar.

## 5. Acessibilidade (parte do sistema, não extra)

- Tudo alcançável por teclado, com **foco visível** e ordem lógica; diálogo prende o foco e o devolve ao fechar.
- Elementos semânticos (botão é botão, link é link); ARIA só quando o nativo não basta.
- Erros e avisos dinâmicos anunciados (`role="alert"` / `aria-live`) e ligados ao campo (`aria-describedby`).
- Texto ampliável até 200% sem perda; nada depende só de cor, som ou animação.
- Imagens com texto alternativo; ícones decorativos ocultos para leitores de tela.

## 6. Conteúdo e microcopy

- Voz única: direta, no idioma do usuário, com os termos do domínio que ele usa.
- Botão com verbo e objeto ("Transferir paciente", "Revogar"), não "OK"/"Enviar".
- Mensagem de problema = **o que houve + o que fazer**. Sem códigos internos na tela.
- Datas, horas, moeda e números no formato local, iguais em todas as telas.
- Estado vazio com o porquê e o próximo passo.

## 7. Governança

- **Documentar o sistema no projeto** (guia de padrões): tokens, componentes, padrões, o que fazer e o que não fazer, com exemplos.
- **Auditar antes de padronizar:** inventariar telas antigas, listar desvios (cores soltas, botões diferentes, espaçamentos próprios) e registrar um plano de adequação por prioridade, em vez de corrigir às cegas.
- **Mudança no sistema vale para todas as telas:** ao alterar token ou componente, rodar os testes e conferir capturas das telas principais nos dois tamanhos.
- **Sem exceções silenciosas.** Desvio só com motivo registrado; se repetir, vira padrão.
- Formatador e lint do projeto aplicados; nomes de componentes e arquivos seguem o que já existe.

## 8. Verificação

- [ ] Nenhum valor visual solto (cor, tamanho, espaçamento) fora do tema.
- [ ] Componentes do sistema usados; nada recriado na tela.
- [ ] Todos os estados dos elementos interativos existem e foram vistos.
- [ ] Tema claro e escuro conferidos; contraste AA.
- [ ] Teclado: tudo alcançável, foco visível.
- [ ] Celular (~375 px) e desktop (~1366 px): sem rolagem lateral, alvos de toque adequados, texto essencial sem corte.
- [ ] Capturas das telas principais olhadas (asserções não pegam inconsistência visual).
- [ ] Guia de padrões atualizado se algo novo foi criado.

## Relação com as outras skills

`entregar-funcionalidade` coordena; `definir-regra-negocio` e `modelar-dados-api` dizem **o que** a tela precisa mostrar; `desenhar-interface` decide **o que cada perfil vê e como a regra aparece**; esta skill garante que isso seja **construído com os mesmos blocos, nos dois tamanhos e de forma acessível**.
