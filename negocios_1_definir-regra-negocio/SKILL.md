---
name: definir-regra-negocio
description: Levanta e especifica uma regra de negócio antes de qualquer código — perguntas de decisão numeradas, perfis e permissões, efeitos e não efeitos, recusas com motivo e orientação, casos de borda e critérios de aceite. Use ao receber pedido de funcionalidade, mudança de regra, permissão, obrigatoriedade de campo ou fluxo de aprovação. Primeira etapa de entregar-funcionalidade; alimenta modelar-dados-api e desenhar-interface.
---

# Definir regra de negócio

Saída: seção **1. Regra** da ficha (ver `entregar-funcionalidade`). Nada de código nesta etapa.

## Passo 1 — Perguntas de decisão

Levantar o que o pedido não responde e perguntar de uma vez, **numerado e fechado**, para o usuário responder em uma linha ("1. sim / 2. só o X / 3. …"). Para cada pergunta, oferecer a recomendação.

Perguntas que quase sempre aparecem:

1. **Quem pode fazer?** E quem, mesmo com cargo alto, **não** pode?
2. **Quem é afetado** e como fica sabendo?
3. **O que acontece com o que já existe** (histórico, registros anteriores, agendamentos, saldos)?
4. **Pode desfazer?** Como, por quem, e o que volta a valer?
5. **Encadeia?** (A→B→C, ida e volta, repetição)
6. **O que bloqueia** a ação (estado em andamento, dado faltando, conflito)?
7. **O que é obrigatório** — e isso existe de fato no processo real?
8. **O que precisa ficar registrado** para auditoria?
9. **O que nunca pode divergir** se duas pessoas agirem ao mesmo tempo? (soma = total, saldo ≥ 0, um único desfecho, um horário por profissional). Vira o invariante da etapa de dados (`integridade-transacional`).

Registrar cada resposta como decisão `Dn` com data. Não implementar até "pode implementar".

## Passo 2 — Princípios para fechar a regra

1. **Poder segue responsabilidade, não hierarquia.** O administrador do sistema não é automaticamente dono do dado sensível. Dar o poder a quem responde pelo dado e recusar os demais — inclusive o admin.
2. **Menor privilégio por padrão.** Na dúvida, não lê. Cada perfil recebe só o que precisa; a recepção não vê conteúdo clínico, o profissional vê só o que o afeta.
3. **Regra que muda no tempo é evento, não flag.** Guardar *quando* aconteceu e calcular o efeito por período. Isso resolve cadeia, ida e volta e revogação sem reescrever registros antigos.
4. **Nunca apagar.** Desfazer = revogar/inativar com quem, quando e motivo. O histórico da decisão faz parte da regra.
5. **Declarar os não efeitos.** "A agenda não muda", "o saldo não é estornado". Evita suposição de quem implementa e de quem usa.
6. **Obrigatoriedade só com evidência do processo.** Campo obrigatório que o processo real não tem trava a operação e gera dado inventado. Separar o que é obrigatório sempre do que é obrigatório só em um contexto (ex.: só com convênio).
7. **Falha fechada.** Se o sistema não consegue decidir (contexto faltando), recusa.
8. **Uma regra, um lugar.** Definir a regra como uma função de decisão única (`pode(ator, alvo, contexto)`) que todas as rotas e consultas usam.

## Passo 3 — Recusas

Toda situação fora do normal vira uma recusa com três partes:

| Código estável | Motivo (o que aconteceu) | O que fazer (ação) |
|---|---|---|
| `ORIGEM_EM_ATENDIMENTO` | X está com o paciente em atendimento. | Finalize a consulta e tente de novo. |
| `SO_ADMIN_CLINICO` | Só o Admin Clínico transfere pacientes. | Peça a quem tem essa função. |

- O código serve à máquina e aos testes e **não muda**; a mensagem serve à pessoa e pode ser reescrita.
- Nunca bloquear em silêncio, nunca esconder um dado sem dizer que ele existe e por que não aparece (sem revelar o conteúdo).
- Sem permissão de leitura: responder como "não encontrado" quando revelar a existência já é vazamento.

## Passo 4 — Casos de borda e aceite

Listar cenários concretos com resultado esperado, no formato:

> Dado <estado>, quando <ator> faz <ação>, então <efeito> e <quem vê o quê>.

Cobrir: cada perfil (inclusive o recusado), encadeamento, desfazer, **ação concorrente** (duas pessoas no mesmo registro: quem vence e o que a outra vê), estado em andamento, dado ausente, primeira vez (lista vazia). Esses cenários viram os testes da etapa 4.

## Próxima etapa

Com as decisões aceitas: `modelar-dados-api` (estrutura e contrato) e depois `desenhar-interface` com `aplicar-design-system`.
