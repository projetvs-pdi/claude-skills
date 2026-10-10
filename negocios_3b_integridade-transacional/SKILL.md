---
name: integridade-transacional
description: Garante que gravações concorrentes nunca deixem dinheiro, saldo, estoque, vaga, agenda ou cadastro divergente, duplicado ou meio gravado — transação tudo-ou-nada, trava da linha dona, ordem fixa de travas, repetição em deadlock, versão otimista, códigos sob trava, conferência antes do commit, barreiras no banco e testes de concorrência reais. Use ao desenhar ou alterar qualquer escrita no servidor, ao revisar ou adequar um projeto existente a esse padrão, ou ao investigar valor duplicado, saldo negativo, código repetido ou deadlock. Chamada por modelar-dados-api e pelo gate de entregar-funcionalidade.
---

# Integridade transacional

Controle transacional é **requisito de segurança da informação**, não otimização: nenhuma combinação de acessos simultâneos pode gerar divergência. Quem perde a disputa recebe uma recusa clara (motivo + o que fazer), nunca um 500 e nunca um dado errado em silêncio.

Dois modos de uso:
- **Desenho** (funcionalidade nova ou mudança): preencher a parte "Concorrência" da seção 2 da ficha (ver `modelar-dados-api`) com as regras abaixo e os testes da §6.
- **Adequação** (projeto existente): levantamento → inventário → ondas (§7).

Antes de propor, ler o que o projeto já tem (função de transação, controle de versão, gerador de códigos, padrão de erro de negócio) e **reaproveitar**. Só criar o que falta, num lugar comum.

## 1. Regras (T1–T9)

| # | Regra | Como |
|---|---|---|
| T1 | **Tudo ou nada.** Validação que depende do banco, gravações, geração de códigos, histórico e log de auditoria na **mesma transação**. Qualquer erro desfaz tudo, inclusive o contador de códigos. A resposta sai **depois** do commit. | Uma função comum de transação gerenciada (§2). Log e histórico recebem a mesma transação. |
| T2 | **A linha dona serializa o agregado.** Antes de ler e contar o que decide a gravação (saldo, soma, uso, "já existe"), travar a linha dona com `SELECT … FOR UPDATE`. | A dona é a linha cuja trava impede a decisão errada (o pacote para o saldo, o pai para a exclusão), não necessariamente a que muda. Leituras de apoio (cadastro ativo, nome) não precisam de trava. |
| T3 | **Ordem fixa de travas** em todo o código (§3). Várias linhas do mesmo tipo: `id` crescente. | Quem trava fora de ordem cria ciclo de espera entre rotinas diferentes → deadlock. |
| T4 | **Deadlock e espera de trava**: desfazer e **repetir a transação inteira** (padrão: até 2 repetições). Persistiu → 409 com código estável (ex.: `CONCORRENCIA_TENTE_NOVAMENTE`) e "Outra pessoa está gravando este registro agora. Tente de novo." | Na função comum. Reduzir a espera máxima por trava das conexões da API (ex.: 10 s) para não parecer tela travada. |
| T5 | **Versão otimista** para quem estava com a tela aberta: a versão enviada é conferida **depois** da trava (ou por `UPDATE … WHERE versao = ?`, que é atômico). Toda gravação sobe a versão. | 409 de "registro alterado" + "carregar atuais". Exclusão: travar e só então conferir a versão. |
| T6 | **Códigos sob trava.** Gerador de códigos/sequência lido e incrementado com trava, reservando de uma vez a quantidade do lote. Nunca "ler o último + 1" sem trava. | Teste de contrato que proíbe o gerador antigo (§6). |
| T7 | **Conferência antes do commit** onde há dinheiro ou saldo: reler do banco o invariante (Σ parcelas = total, saldo ≥ 0) e desfazer tudo se não fechar (500 com código de integridade). | Protege contra erro de código. O registro da falha vai para o log do servidor: um log na mesma transação seria desfeito junto. |
| T8 | **Banco como última barreira** (vale para SQL manual e scripts): PK/UNIQUE, FK composta, `CHECK`, e `TRIGGER` que recusa alterar dado imutável. | Migration reversível, backup antes, teste por SQL direto. Inclui `UNIQUE (tenant, id)` quando a PK não garante id único por tenant. |
| T9 | **Testes de concorrência reais** contra o banco, sem mock (§6). | Exatamente uma vence, as outras recebem a recusa prevista, o invariante relido confere. |

Proporcional ao risco: cadastro simples precisa de T1, T4, T5, T6 e T8. Dinheiro, saldo e recurso disputado precisam de todas.

## 2. Função comum de transação

Uma única porta (ex.: `comTransacao(fn, { tentativas })`) que: abre a transação, executa `fn(t, tentativa)`, faz commit, desfaz em qualquer erro e repete **só** em deadlock/espera de trava. Esgotou → erro de negócio 409. Exemplo em Node/Sequelize: [referencias/transacao-node.md](referencias/transacao-node.md).

Regras para quem escreve `fn`:
1. Não responde nem faz commit/rollback: **devolve os dados**; a resposta sai depois. Se a resposta precisa de variáveis de dentro, `fn` devolve uma função que responde, chamada depois do commit.
2. Pode rodar mais de uma vez: tudo o que decide é lido de novo dentro dela; nenhum efeito externo (e-mail, arquivo, fila) dentro.
3. Toda chamada ao banco leva a transação (log e histórico inclusive).
4. Erro de negócio não é repetido. Validação sem banco fica fora, antes.
5. Saída antecipada sem escrita (ex.: "em uso", "já fechado") é um `return` normal: o commit de uma transação sem escrita não grava nada.

Detalhes que costumam escapar:
- No **deadlock** o banco já desfez a transação; na **espera de trava esgotada** só o comando foi desfeito → desfazer sempre explicitamente.
- O driver/ORM pode embrulhar o erro: reconhecer pelo código/errno em todos os níveis (`original`, `parent`, o próprio erro).
- O tratador genérico de erros também converte deadlock que escapou para o mesmo 409, nunca 500.

## 3. Ordem global de travas

Escrever a ordem **do projeto** num documento e segui-la em toda rotina:

```text
1. Sequência/gerador de códigos de todas as tabelas que vão receber linhas (ordem alfabética)
2. Pai que será excluído → filhas lidas na verificação de vínculos
3. Linha dona do agregado (ex.: pacote, pedido, conta) — várias: id crescente
4. Filhos do agregado na ordem pai → filho
5. Log de auditoria (só inclusão; nunca trava nada)
```

**Por que a sequência vem primeiro.** Ela é ponto de passagem de todas as inclusões da tabela. Pegá-la por último, depois de travar dados (inclusive intervalos de um `FOR UPDATE` por faixa), fecha ciclos com quem já a tem e insere naquela faixa. Pegando primeiro, as inclusões entram em fila na entrada. Dá para **travar a linha da sequência sem reservar** e reservar depois, na mesma transação: mesmo efeito, sem gastar código quando a regra recusa.

**Mudança que troca o dono** (mover um item para outro agregado): ler o dono atual **sem trava**, travar os donos envolvidos em ordem, travar o item e conferir que o dono não mudou no meio (senão 409 de registro alterado).

Aplicar a ordem a **todas** as rotinas que disputam as mesmas linhas, ou nenhuma: aplicar em parte pode criar um ciclo novo.

## 4. Recusas e tela

| Situação | HTTP | Código (exemplo) | Tela |
|---|---|---|---|
| Disputa persistiu após as repetições | 409 | `CONCORRENCIA_TENTE_NOVAMENTE` | Aviso com motivo + **Tentar de novo** (reenvia o mesmo pedido) + fechar; mantém o que foi digitado |
| Versão antiga | 409 | `REGISTRO_ALTERADO` | Carregar atuais / manter na tela |
| Sem versão | 428 | `VERSAO_OBRIGATORIA` | Recarregar |
| Invariante não fechou | 500 | `INTEGRIDADE_…` | "Nada foi gravado. Avise o suporte." |

O "Tentar de novo" fica **num ponto só** do front (o cliente HTTP comum segura a resposta e pergunta), não em cada tela. Sem resposta da pessoa em um tempo razoável, desiste e entrega o erro à tela.

## 5. Ficha: o que registrar na seção "Concorrência"

- Linha dona de cada agregado e o invariante que ela protege (o "nunca pode divergir" vindo da regra).
- Ordem de travas da rotina (deve bater com a do projeto).
- Versão otimista: onde a tela envia e onde é conferida.
- Códigos de recusa da disputa.
- Barreiras no banco (UNIQUE, FK, CHECK, trigger).
- Cenários de concorrência que viram teste (§6).

## 6. Testes

**Concorrência real (T9)** — critério de pronto para toda escrita com dinheiro, saldo ou recurso disputado:
- Banco real (o de teste do projeto), cada chamada com a própria transação/conexão; pool ≥ N + 2.
- **Largada simultânea** (barreira): todas esperam até as N estarem prontas.
- Chamar a camada de serviço/controller com requisição falsa já autenticada (ou HTTP real, se o app for exportável sem subir o servidor).
- Asserções: contagem por status+código (`{ 201: 1, '409:SEM_SALDO': 4 }`), **nenhum 500**, invariante **relido do banco**, ids únicos.
- Cenários típicos: N × incluir no mesmo agregado com saldo 1; mesmo recurso (horário, item) por agregados diferentes; lote × lote; desfazer × refazer; ação do usuário × rotina automática; confirmar × cancelar; mover × incluir no mesmo dono.
- Rodar **5 vezes seguidas** antes de concluir; falha intermitente se investiga, não se ignora.
- **Provar que o teste discrimina:** rodar o cenário com a correção desligada (cópia temporária com o comportamento antigo). Se o antigo também passa, o relato diz: "a correção é preventiva; o teste não reproduz a falha".

**Dados de teste em banco compartilhado:**
- Marca identificável (prefixo no nome) e datas sem uso real (ex.: daqui a anos).
- Limpeza no fim **e no início** (recupera sobra de rodada que caiu antes de limpar).
- A limpeza respeita os `CHECK`/FK do banco (ex.: zerar colunas que só existem em par).
- Contadores de código devolvidos ao valor anterior **só se** ninguém usou códigos depois.
- Conferir depois da suíte: zero sobras, contadores no lugar.

**Contrato (estático):**
- Nenhum arquivo novo abre transação na mão nem usa o gerador de códigos sem trava. Lista de **pendências que só diminui**: arquivo corrigido precisa sair da lista (o progresso fica registrado).
- Nenhuma resposta sai de dentro da transação.
- Unitários da função comum: commit, rollback sem repetir em erro de negócio, repetição em cada código de trava, esgotou → 409, rollback explícito na espera de trava.
- Integração: provocar um deadlock de verdade (duas conexões travando duas linhas em ordem cruzada) e uma espera esgotada (conexão de teste com espera curta).

**Armadilhas vistas:**
- Timer de cache/limpeza sem `unref` deixa o processo de teste vivo (a suíte "termina" mas não sai).
- Teste unitário com models simulados quebra quando a rotina passa a travar a sequência: simular a função de trava, não o banco inteiro.
- Liberação de trava marcada por relógio no teste é intermitente; amarrar ao evento (ex.: liberar só na 2ª tentativa).

## 7. Adequação de projeto existente

1. **Levantamento** (somente leitura): onde se abre transação, onde há `FOR UPDATE`, quem gera código sem trava, quem trata deadlock, log fora da transação, resposta antes do commit; configuração do banco (isolamento, espera de trava); chaves que não garantem id único por tenant; contagem de duplicados existentes.
2. **Inventário** por rotina: regras feridas (T1–T9) e risco — dinheiro > saldo > agenda/recurso > cadastro.
3. **Ondas**: 0 fundação (função comum, código de recusa, espera de trava, apoio de teste, contrato com pendências) → rotinas de dinheiro e saldo → configuração com valor → cadastros → limpeza (remover gerador antigo, barreiras restantes, documentos).
4. Cada onda: documento atualizado, testes novos + suítes completas, concorrência 5× verde, relato honesto do que não foi verificado. Implementar só com autorização explícita por onda.
5. Rotina que está sendo mexida por outra frente de trabalho fica de fora e recebe só a função comum e a ordem de travas.

## Relato

Separar sempre: o que o teste **provou**, o que é **preventivo** (correção sem falha reproduzida) e o que **não foi verificado** (ex.: navegador).
