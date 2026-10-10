---
name: modelar-dados-api
description: Traduz uma regra de negócio aceita em estrutura de dados e API — tabelas, migrations, models, relações, multi-tenant, concorrência, auditoria, contrato de rotas e códigos de recusa, com os testes do back. Use ao criar ou alterar tabela, model, migration, rota ou regra de acesso no servidor. Segunda etapa de entregar-funcionalidade; parte da saída de definir-regra-negocio. Toda escrita aplica integridade-transacional.
---

# Modelar dados e API

Entrada: seção **1. Regra** da ficha. Saída: seção **2. Dados e API** e o código do back com testes. Antes de criar, ler o padrão do projeto (models, migrations e rotas existentes) e seguir os nomes e convenções que já estão lá.

## Estrutura de dados

1. **Evento em vez de estado.** Para regra que muda no tempo, uma linha por acontecimento: `quando`, `quem fez`, `ativo`, e na revogação `revogadoEm`, `revogadoPor`, `motivoRevogacao`. Nada é apagado.
2. **Auditoria nas colunas.** Criado/alterado por e em, em toda tabela.
3. **Concorrência e integridade transacional: aplicar a skill `integridade-transacional`.** Em resumo: transação tudo-ou-nada pela função comum (repete em deadlock), trava da linha dona antes de contar, ordem fixa de travas, versão otimista conferida depois da trava, códigos sob trava, conferência do invariante antes do commit onde há dinheiro ou saldo, barreiras no banco. Proporcional ao risco: cadastro simples leva versão + transação + códigos sob trava; dinheiro, saldo e recurso disputado levam tudo.
   - Escolher um nome de campo de versão que não colida com campo de negócio e usá-lo em todo o projeto.
4. **Multi-tenant pelo contexto.** Empresa/filial vêm da sessão/requisição, nunca do corpo ou da URL que o cliente controla. Toda consulta filtra por elas.
5. **Relações declaradas e testadas.** Tabela nova registra seus vínculos no mapa do projeto, e um teste falha se faltar o registro ou se as regras de compartilhamento entre tabelas forem violadas.
6. **Índices pelas consultas reais** (ex.: `paciente + ativo`, `profissional + ativo`).
7. **Migration reversível** e com nome que diga a fase e o assunto.

## Regra de acesso

1. **Uma função de decisão** (`podeLer(registro, contexto)`) usada por todas as rotas que devolvem um registro.
2. **O filtro de listagem é a mesma regra em forma de consulta.** Quando a regra existe em duas formas (filtro no banco e função na memória), criar um **teste de equivalência**: gerar muitos cenários aleatórios e afirmar que o filtro e a função escolhem exatamente os mesmos registros.
3. **Falha fechada.** Contexto não carregado (ex.: lista de transferências ausente) lança erro, não libera.
4. **Sem permissão de leitura → 404** quando dizer "existe, mas você não pode ver" já vaza informação.

## Contrato da API

1. **Rotas por recurso**, ações que não são CRUD como sub-recurso: `POST /recurso/:id/revogar`.
2. **Prévia sem gravar.** Ação de efeito amplo ganha `GET …/previa` que roda **a mesma função de validação** da gravação e devolve os efeitos (ex.: quantos agendamentos futuros). A tela usa isso na confirmação.
3. **Opções vindas do back.** Listas de escolha (quem pode ser destino) vêm prontas com o motivo de cada item indisponível (`temUsuario: false`), para a tela mostrar desabilitado com explicação.
4. **Resposta por perfil.** O mesmo recurso devolve campos diferentes conforme quem pede (ex.: o motivo vai para quem decidiu e para o destino, não para a origem). Montar isso numa função `paraTela(registro, contexto)`.
5. **Erro de negócio padronizado:** status HTTP + `codigo` estável + mensagem com motivo e o que fazer (ver `definir-regra-negocio`). 400 dado inválido, 403 sem permissão, 404 não encontrado/não visível, 409 conflito de estado/versão.
6. **Tudo numa transação:** validação, gravação e registro de auditoria juntos; erro desfaz tudo; resposta só depois do commit. Disputa que persiste → 409 com código estável (ex.: `CONCORRENCIA_TENTE_NOVAMENTE`), tratado num ponto só do front com "Tentar de novo" (ver `integridade-transacional` §4).

## Auditoria de acesso

- Registrar ações sensíveis (ler, transferir, revogar) com quem, quando, o quê e sobre quem.
- **Não registrar o conteúdo sensível** (motivo clínico, texto do registro) no log.
- Log só de inclusão; teste que garante que não há alteração nem exclusão.

## Testes do back

- [ ] Cada regra e cada recusa com o código esperado.
- [ ] Cada perfil, inclusive o recusado (e o "admin que não pode").
- [ ] Cenários de tempo: encadeamento, ida e volta, revogação.
- [ ] Equivalência filtro × função com cenários aleatórios.
- [ ] Falha fechada sem contexto.
- [ ] Prévia não grava nada.
- [ ] Conflito de versão/estado → 409.
- [ ] **Concorrência real** contra o banco (largada simultânea, exatamente uma vence, nenhum 500, invariante relido), 5× seguidas — ver `integridade-transacional` §6.
- [ ] Contrato: nenhum código novo abre transação na mão nem gera código sem trava.
- [ ] Teste do mapa de relações atualizado.
- [ ] Mocks de models centralizados, para tabela nova não quebrar testes antigos.

## Dados para teste no navegador

Script com comandos `preparar` (cria/acha os dados do cenário e devolve ids em JSON), `limpar` (remove tudo pela marca) e consultas de apoio (ex.: `log`). Dados marcados com prefixo identificável.

## Próxima etapa

`desenhar-interface`, usando o contrato e os códigos definidos aqui.
