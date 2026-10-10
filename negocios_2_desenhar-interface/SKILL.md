---
name: desenhar-interface
description: Desenha e implementa telas a partir de uma regra e de um contrato de API — o que cada perfil vê, desktop e celular, avisos a quem é afetado, confirmações em duas etapas, estados vazios que explicam, ordem pelo modelo mental do usuário — com testes de tela e de navegador. Use ao criar ou ajustar telas, formulários, listas, diálogos ou mensagens. Terceira etapa de entregar-funcionalidade; parte de definir-regra-negocio e modelar-dados-api.
---

# Desenhar interface

Entrada: regra (seção 1) e contrato (seção 2) da ficha. Saída: seção **3. Interface**, telas e testes. Antes de criar, ler o guia de padrões de tela do projeto, se existir, e seguir os componentes já usados. **A construção visual (tokens, componentes, responsivo, acessibilidade) segue `aplicar-design-system`**; esta skill decide o que cada perfil vê e como a regra aparece na tela.

## Princípios

1. **A tela mostra a regra para quem é afetado.** Quem ganhou ou perdeu algo é avisado no lugar onde percebe a diferença, com o quê, de quem, quando e o que fazer.
2. **Tela enxuta: nada aparece quando não se aplica.** Sem bloco vazio, sem botão que não pode ser usado, sem lista de opções que não valem para o caso (ex.: em registro já vinculado, mostrar só o vínculo, não todas as alternativas). Detalhes ficam recolhidos ("Transferências (2)").
3. **Fora do normal, sempre orientar.** Recusa, dado faltando ou opção indisponível: motivo + o que fazer + a ação, quando houver. Opção indisponível aparece desabilitada com o motivo, não some sem explicação.
4. **Vazio explica o porquê.** "Nenhum registro" é ambíguo quando há dados ocultos por regra. Dizer por que está vazio e onde está o que falta.
5. **Ação de efeito amplo em duas etapas.** Escolha → confirmação que descreve em linguagem simples o que vai mudar e para quem (vindo da prévia do back) → executar.
6. **Ordem e agrupamento pelo modelo mental do usuário,** não pelo campo técnico. Ex.: histórico por consulta, da mais recente para a mais antiga, e dentro dela por registro. Quando houver dúvida, perguntar com um exemplo concreto.
7. **Não repetir informação na mesma tela.** Dado repetido confunde a leitura; manter um lugar só, perto do que ele descreve.
8. **Preservar o contexto de chegada.** Quem abre a tela a partir de um item específico chega filtrado nele, com saída clara ("Ver tudo") — e volta ("Ver só este").
9. **Texto essencial nunca cortado** (nome de pessoa completo, quebrando linha se preciso).

## Desktop e celular

- Desenhar para os dois desde o início; celular é restrição, não adaptação posterior.
- Saber **quem usa no celular** e para quê; não levar ao celular o que ninguém faz lá.
- Celular: ações secundárias em menu (⋮), uma coluna, alvos de toque grandes, **sem rolagem lateral** (com teste automático).
- Hierarquia tipográfica consistente: informação de apoio no mesmo tamanho/estilo do cabeçalho a que pertence, com peso menor.

## Estados de cada tela

Para cada tela, prever e testar: carregando, vazio (com o porquê), recusa (motivo + o que fazer), sucesso (aviso do efeito), conflito (dado mudou — recarregar e dizer o que mudou), e a visão de cada perfil.

## Contrato com o back

- A tela não reimplementa a regra: usa opções, prévia e campos que o back devolve por perfil.
- Validação na tela só para orientar cedo; o back recusa de novo.
- Mostrar a mensagem do back nas recusas; usar o `codigo` só para decidir comportamento (ex.: recarregar a lista em `JA_REVOGADA`).
- Mudou a obrigatoriedade de um campo? Ajustar marcação, habilitação do botão, texto de ajuda e testes, junto com o back.

## Testes

- **Componente:** cada perfil e estado; fluxo em duas etapas; recusa exibida com orientação; nada exibido quando não se aplica.
- **Navegador:** fluxo real com usuários de cada perfil, em celular (~375 px) e desktop (~1366 px); conferir também pela API que o dado não chega a quem não deve ver.
- **Capturas:** guardar as telas principais e olhar as imagens — pegam texto cortado, mensagem errada e repetição que as asserções não pegam. Mostrar ao usuário cedo.
- **Seletores estáveis:** `data-testid`, papel e rótulo acessível. Texto exato só onde o significado é o objeto do teste.
- Seguir o formatador e o lint do projeto (ex.: consultas assíncronas com `findBy`, sem acesso direto ao DOM).

## Próxima etapa

Validação e gate em `entregar-funcionalidade`.
