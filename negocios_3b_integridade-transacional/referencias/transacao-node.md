# Exemplo: função comum de transação em Node + Sequelize (MySQL/InnoDB)

Adaptar nomes, erro de negócio e logger ao projeto. Códigos do MySQL: `ER_LOCK_DEADLOCK` (1213), `ER_LOCK_WAIT_TIMEOUT` (1205). Em PostgreSQL: SQLSTATE `40P01` (deadlock) e `55P03`/`40001` (trava/serialização).

```js
'use strict';
const { ErroNegocio } = require('../erros/ErroNegocio');

const CODIGOS = new Set(['ER_LOCK_DEADLOCK', 'ER_LOCK_WAIT_TIMEOUT']);
const ERRNOS = new Set([1213, 1205]);

/** Reconhece o conflito de trava em qualquer embrulho do ORM. */
function ehConflitoDeTrava(e) {
  if (!e) return false;
  return [e.original, e.parent, e].some((b) => b && (CODIGOS.has(b.code) || ERRNOS.has(Number(b.errno))));
}

const pausar = ([min, max]) => new Promise((r) => setTimeout(r, min + Math.random() * Math.max(0, max - min)));

async function comTransacao(fn, { tentativas = 3, esperaMs = [30, 120], sequelize, rotulo = 'transacao' } = {}) {
  const db = sequelize || require('../../models').sequelize; // lazy: mocks de teste continuam valendo
  for (let tentativa = 1; ; tentativa += 1) {
    const t = await db.transaction();
    try {
      const resultado = await fn(t, tentativa);
      await t.commit();
      return resultado;
    } catch (e) {
      // deadlock: o banco já desfez; espera esgotada: só o comando → desfazer sempre
      if (!t.finished) await t.rollback().catch(() => {});
      if (!ehConflitoDeTrava(e)) throw e;
      if (tentativa >= tentativas) {
        throw new ErroNegocio('Outra pessoa está gravando este registro agora. Tente de novo.', 409, { codigo: 'CONCORRENCIA_TENTE_NOVAMENTE' });
      }
      console.warn(`[${rotulo}] conflito de trava, tentativa ${tentativa + 1}/${tentativas}`); // sem dados do pedido
      await pausar(esperaMs);
    }
  }
}

module.exports = { comTransacao, ehConflitoDeTrava };
```

## Espera máxima por trava nas conexões da API

```js
sequelize.addHook('afterConnect', (conexao) => new Promise((ok, falha) => {
  conexao.query('SET SESSION innodb_lock_wait_timeout = 10', (e) => (e ? falha(e) : ok()));
}));
```

## Uso no controller

```js
static async store(req, res) {
  try {
    const criado = await comTransacao(async (t) => {
      await travarSequencias(filialId, ['PEDIDO', 'PEDIDO_ITEM'], t);                // 1. sequências (ordem alfabética)
      const dono = await Conta.findOne({ where, transaction: t, lock: t.LOCK.UPDATE }); // 3. linha dona
      // … ler e contar, validar (ErroNegocio), gravar com a mesma t, log com a mesma t …
      await conferirInvariante({ dono, transaction: t });                           // T7
      return registro;
    }, { rotulo: 'Pedido.store' });
    return res.status(201).json({ success: true, data: criado });                  // depois do commit
  } catch (e) {
    return tratarErro(e, req, res); // ErroNegocio → status + código; resto → tratador genérico (1213/1205 → 409)
  }
}
```

Resposta que depende de variáveis de dentro: `fn` devolve `async () => res.status(200).json(...)` e o controller chama `return await (await comTransacao(...))()`.

## Trava da sequência sem reservar

```js
async function travarSequencias(filial, tabelas, t) {
  for (const nome of [...new Set(tabelas)].sort()) {
    await Sequencia.findOne({ where: { filial, nome }, transaction: t, lock: t.LOCK.UPDATE });
  }
}
```

## Deadlock de verdade para o teste de integração

Duas transações em conexões separadas: A trava a linha 1 e B trava a linha 2; as duas esperam uma barreira; então A pede a 2 e B pede a 1. O banco derruba uma; a função comum a repete e as duas concluem (uma com `tentativa === 2`).
