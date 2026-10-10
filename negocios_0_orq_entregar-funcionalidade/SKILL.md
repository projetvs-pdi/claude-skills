---
name: entregar-funcionalidade
description: Conduz uma funcionalidade nova ou mudança de regra de ponta a ponta — regra de negócio, dados/API, interface e validação — em fases com gate. Use ao iniciar qualquer funcionalidade, fase de roadmap ou mudança de regra que atravesse back e front. Coordena as skills definir-regra-negocio, modelar-dados-api, integridade-transacional, desenhar-interface e aplicar-design-system.
---

# Entregar funcionalidade (orquestração)

Uma funcionalidade passa por quatro etapas, sempre nesta ordem. Cada etapa preenche uma seção da **ficha da funcionalidade** e só começa com a anterior aceita.

| Etapa | Skill | Sai daqui |
|---|---|---|
| 1. Regra | `definir-regra-negocio` | decisões, perfis, efeitos, recusas, critérios de aceite |
| 2. Dados e API | `modelar-dados-api` + `integridade-transacional` | tabelas, contrato da API, códigos de recusa, auditoria, concorrência (linha dona, ordem de travas, invariantes) |
| 3. Interface | `desenhar-interface` + `aplicar-design-system` | telas por perfil e tamanho, mensagens, estados — construídas com os tokens e componentes do sistema |
| 4. Validação | esta skill | testes, navegador, capturas, documentação |

## Regras do processo

1. **Discussão não é autorização.** Durante o desenho, não mudar código. Implementar só depois de um "pode implementar" explícito do usuário.
2. **Ficha no projeto, não na conversa.** Criar ou atualizar a ficha em `docs/` (ou onde o projeto guarda documentação) antes de codar. A conversa se perde; o arquivo fica.
3. **Gate de fase.** A fase seguinte só começa com a anterior: documentada, com testes passando e validada no navegador. Se o usuário pedir pausa, registrar o ponto de parada na ficha.
4. **Back é a fonte da verdade.** Toda regra existe no back; a tela só orienta. Mudou a regra (ex.: campo deixou de ser obrigatório)? Muda back, tela, testes dos dois lados e documentação juntos.
5. **Mostrar cedo.** Capturar telas assim que a primeira versão roda e mostrar ao usuário — a maior parte dos ajustes de interface surge ao ver.
6. **Pedido com imagem descreve um caso, não o problema inteiro.** Procurar os outros lugares onde o mesmo problema acontece (ex.: corrigiu na consulta bloqueada, conferir também na edição).
7. **Decisão de produto vira regra durável.** Quando o usuário disser "já alinhamos que…", registrar a regra (memória/ficha) para não depender de repetição.

## Ficha da funcionalidade (modelo)

```markdown
# <Funcionalidade> — <fase>

## 1. Regra  (definir-regra-negocio)
- Objetivo:
- Decisões (Dn): pergunta → resposta → data
- Perfis: quem faz / quem vê / quem é recusado
- Efeitos: o que muda, para quem, a partir de quando
- Não efeitos: o que explicitamente NÃO muda
- Recusas: CÓDIGO — motivo — o que fazer
- Casos de borda:
- Critérios de aceite:

## 2. Dados e API  (modelar-dados-api)
- Tabelas/campos, relações, compartilhamento/tenant
- Rotas: método, caminho, corpo, resposta, status
- Auditoria: ação, quem, sem conteúdo sensível
- Concorrência (integridade-transacional §5): linha dona e invariante, ordem de travas, versão, recusas da disputa, barreiras no banco, cenários de teste

## 3. Interface  (desenhar-interface + aplicar-design-system)
- Componentes e padrões do sistema usados; algo novo criado no sistema?
- Telas por perfil; desktop e celular
- Mensagens (avisos, vazios, confirmações)
- Estados: carregando, vazio, recusa, sucesso

## 4. Validação
- Testes back / tela / navegador (tamanhos)
- Capturas conferidas
- Pendências e pausa
```

## Etapa 4 — validação (gate)

Antes de declarar a fase concluída:

- [ ] **Back:** cada regra, cada recusa (com o código), cada caso de borda e o teste de equivalência quando a regra existir em duas formas (ver `modelar-dados-api`).
- [ ] **Concorrência:** testes reais contra o banco passando em 5 execuções seguidas, invariantes conferidos, nenhum 500, sem sobra de dados de teste (ver `integridade-transacional` §6). O relato separa o que foi provado do que é preventivo.
- [ ] **Tela:** testes de componente para cada perfil e estado (vazio, recusa, sucesso, confirmação).
- [ ] **Design system:** lista de verificação de `aplicar-design-system` (sem valor solto, estados, contraste, teclado, sem rolagem lateral).
- [ ] **Navegador:** fluxo real em celular (~375 px) e desktop (~1366 px), com usuários de cada perfil, dados marcados e limpos ao final.
- [ ] **Capturas:** conferir imagens das telas principais — mensagem errada, informação repetida e texto cortado aparecem aqui, não nas asserções.
- [ ] **Suítes completas** de back e front rodadas, não só as novas. Falha sob carga: rodar de novo antes de concluir e distinguir de regressão.
- [ ] **Documentação** da regra, da API e da tela atualizada; fase marcada como concluída no plano.
- [ ] **Relato honesto:** o que passou, o que não foi verificado e o que ficou pendente.

## Testes que envelhecem bem

- Estrutura por identificador estável (`data-testid`, código de recusa); texto exato só onde o significado é o objeto do teste. Mudança de redação não deve quebrar dezenas de testes.
- Dado de teste com marca identificável (prefixo de login, nome) e comando de limpeza, para rodar contra base real sem resíduo.
- Mocks de modelos/serviços centralizados: tabela nova não pode quebrar todos os testes antigos por falta de mock.
- Execuções longas em segundo plano, com tempo limite explícito.
