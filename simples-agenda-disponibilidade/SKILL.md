---
name: simples-agenda-disponibilidade
description: Cruza a agenda FUTURA do Simples Agenda com a disponibilidade semanal de cada profissional e com o historico recente de atendimentos para sugerir pacientes que preencham horarios vagos ("buracos" na agenda). Use esta skill sempre que o usuario pedir para analisar disponibilidade de agenda, analisar disponibilidade de profissionais, baixar/exportar a agenda futura, encontrar buracos ou horarios vagos na agenda dos profissionais, ou sugerir pacientes para ocupar horarios livres - mesmo que ele nao use exatamente essas palavras (ex.: "quais horarios estao livres essa semana?", "quem podemos encaixar na agenda da Dra. X?"). Gera uma planilha final ordenada por profissional + data + hora, com as sugestoes de pacientes recorrentes (Cenario A) antes dos horarios vagos sem sugestao (Cenario B). NAO use esta skill para apenas baixar/exportar a agenda ja realizada (passado) - isso e a skill simples-agenda-download.
compatibility: PowerShell 5.1+ (Invoke-WebRequest), Microsoft Excel (COM), MySQL Shell (mysqlsh.exe) no PATH, credential-manager. Sem navegador/Selenium.
---

# Simples Agenda - Disponibilidade x Agenda Futura

## Qual skill usar?

| Pedido do usuário | Skill a chamar | Por quê? |
|---|---|---|
| "Baixa a agenda passada" / "Sincroniza a agenda realizada" | **simples-agenda-download** | Lê agenda já realizada, sincroniza em sbx990 automaticamente |
| "Preciso da agenda futura" / "Qual é a agenda futura?" (sem mais contexto) | ❌ **AMBÍGUO** — se quer só ver a agenda, é download; se quer analisar, é disponibilidade |
| "Preciso da agenda futura" + "analisar disponibilidade" / "sugerir pacientes" / "encontrar buracos" | **simples-agenda-disponibilidade** ← USE ESTA |
| "Quais horários estão vagos?" / "Quem encaixar?" / "Qual a disponibilidade?" | **simples-agenda-disponibilidade** ← USE ESTA |

## Visao geral

Esta skill responde a uma pergunta que `simples-agenda-download` nao responde:
**"quais horarios profissionais vao ficar vagos no periodo X, e quem eu poderia
encaixar neles?"**

Ela **nao substitui nem modifica** `simples-agenda-download` (que baixa agenda
JA REALIZADA/passada e a sincroniza em `sbx990`). Em vez disso:

1. Baixa a agenda **futura** direto do Simples Agenda (mesmo protocolo HTTP
   documentado em [`simples-agenda-download/SKILL.md`](../simples-agenda-download/SKILL.md),
   mas com os guardrails de data invertidos - aqui a data tem que ser futura).
2. Le a disponibilidade semanal de cada profissional em `sb5990`.
3. Le o historico de atendimentos ja realizados em `sbx990` (a mesma tabela que
   `simples-agenda-download` ja mantem atualizada via `import-db-agenda`).
4. Calcula os "buracos": horarios em que o profissional está disponível
   (`sb5990`) mas não há nada agendado nele na agenda futura baixada.
5. Para cada buraco, tenta sugerir um paciente que já foi atendido por aquele
   profissional nas últimas semanas e que ainda não está na agenda futura
   (Cenário A). Buracos que sobram sem sugestão viram Cenário B.
6. Gera **uma planilha só**, ordenada por profissional + data + hora, com o
   Cenário A primeiro e o Cenário B depois.

### Por que não chamar `baixar_agenda.ps1` diretamente

`baixar_agenda.ps1` (a skill `simples-agenda-download`) tem duas coisas
incompatíveis com este uso:
- Guardrail explícito: **rejeita** `DataIni`/`DataFim` no futuro (ela existe
  para baixar o que já aconteceu).
- Depois do download, sincroniza automaticamente em `sbx990` (histórico) e
  manda e-mail - efeitos colaterais errados para uma agenda que ainda vai
  acontecer.

Por isso esta skill **reimplementa só o login + export + download** (os
mesmos três endpoints, já provados em produção: `autenticacao_usuario.php`,
`crud_autenticacao.php`, `crud.php?acao=exporta_agendamentos`), com o
guardrail de data invertido. Ela reutiliza a skill `credential-manager` com o
**mesmo `service=simples-agenda`**, então se o usuário já autenticou antes
pela `simples-agenda-download`, não precisa digitar a senha de novo.
`baixar_agenda.ps1` não é tocado nem chamado - zero risco de regressão nela.

---

## Como usar

### 1. Reunir parâmetros

**Obrigatórios:**
- **Email** - login do Simples Agenda (senha vem do `credential-manager`, mesmo cofre já usado por `simples-agenda-download`; se não houver, pede uma vez e salva)

**Datas - combinações válidas:**
- **Nenhuma data informada** (padrão) → usa hoje até hoje+7 dias automaticamente
- **Ambas informadas** (`-DataIni` + `-DataFim`, dd/mm/yyyy) → tem que ser hoje ou no futuro, e Fim >= Início
- **Apenas uma informada** → erro com mensagem orientadora

**Opcionais** (pergunte só se fizer diferença para o pedido do usuário; senão use o default):
- **Profissionais** - filtra quais baixar do Simples Agenda (default: todos)
- **Semanas de histórico** para o Cenário A (default: 4, igual ao documento original)
- **Duração padrão do atendimento** em minutos, usada para saber quanto tempo um horário fica ocupado (default: 50 min - pergunte ao usuário se ele sabe a duração real, ela muda o resultado)

### 2. Validar datas (guardrail - invertido em relação a `simples-agenda-download`)

```
✓ ACEITAR: Nenhuma data → defaults: Hoje 02/01/2024, Início 02/01/2024, Fim 09/01/2024 (hoje+7)
✓ ACEITAR: Ambas → Hoje 02/01/2024, Início 02/01/2024, Fim 31/01/2024
✓ ACEITAR: Ambas → Hoje 02/01/2024, Início 03/01/2024, Fim 31/01/2024
✓ ACEITAR: Ambas → Hoje 02/01/2024, Início 02/01/2024, Fim 02/01/2024 (mesmo dia)
✗ REJEITAR: Apenas uma data informada
✗ REJEITAR: Início no passado (Hoje 02/01/2024, Início 01/01/2024)
✗ REJEITAR: Fim < Início
✗ REJEITAR: formato != dd/mm/yyyy (mesmas regras de `simples-agenda-download`: sem ISO, sem mm/dd, sem texto)
```

A skill agora **não pergunta** mais as datas se o usuário não informar - usa
automaticamente hoje até hoje+7 dias. Isso evita o fluxo interativo e
mantém a skill rápida em uso programático. Se o usuário quiser um período
diferente, passa `-DataIni` e `-DataFim` explicitamente (ambas obrigatórias
uma vez que informa qualquer uma).

### 3. Executar

```bash
powershell -ExecutionPolicy Bypass -File .claude/skills/simples-agenda-disponibilidade/scripts/gerar_disponibilidade.ps1 `
    -Email voce@email.com -DataIni 15/09/2026 -DataFim 30/09/2026
```

O script cuida de: login, export, download do .xls futuro, leitura de
`sb5990`/`sbx990`, cálculo dos buracos, sugestão de pacientes e geração da
planilha final. Ele imprime cada etapa com prefixo `[*]`/`[OK]`/`[AVISO]`/`[ERRO]`.

### 4. Conferir a saída

**Sucesso:**
```
✓ "Planilha 'agenda_futura_x_disponibilidade_profissional_20260908_143025.xlsx'
   gerada com sucesso em C:\Users\usuario\Downloads
   (N sugestões de Cenário A, M horários vagos sem sugestão - Cenário B)"
```

Confira com o usuário se os nomes de profissionais/serviços que apareceram
como "[AVISO] não mapeado" fazem sentido - eles não entram no cruzamento
porque não existe correspondência em `sa2990`/`sa4990` (ver seção "Limitações").

### 5. Envio automático por email (padrão: ligado)

Depois de gerar a planilha, a skill a envia por email usando a skill
[`email-sender`](../email-sender/SKILL.md), reaproveitando o `service=simples-agenda`
já configurado (mesmo remetente `projetvs.pdi@gmail.com`, mesma allowlist -
não precisa rodar setup de novo).

- **Destinatário padrão:** `amazonasterapiafisio@gmail.com` (`-EnviarPara`
  para trocar - tem que estar na allowlist do `email-sender` para o service
  usado, senão o envio é bloqueado).
- **Sucesso no envio:** a planilha local é **apagada** (o destinatário já a
  recebeu em anexo - não faz sentido acumular dado de paciente em Downloads).
- **Falha no envio:** a planilha **NÃO é apagada** (fica em Downloads para
  reenvio manual) e a skill manda um segundo email, para
  `projetvs.pdi@gmail.com` (`-EmailErroPara` para trocar), com o motivo exato
  da falha (allowlist, credencial, TLS, etc. - ver tabela de exit codes do
  `email-sender` no SKILL.md dele).
- **Desligar o envio:** `-SemEnvioEmail` gera só a planilha local, como antes
  desse recurso existir.

```bash
# padrão: gera e envia para amazonasterapiafisio@gmail.com
powershell -ExecutionPolicy Bypass -File .claude/skills/simples-agenda-disponibilidade/scripts/gerar_disponibilidade.ps1 `
    -Email voce@email.com -DataIni 15/09/2026 -DataFim 30/09/2026

# sem envio por email (só gera a planilha em Downloads)
powershell -ExecutionPolicy Bypass -File .claude/skills/simples-agenda-disponibilidade/scripts/gerar_disponibilidade.ps1 `
    -Email voce@email.com -DataIni 15/09/2026 -DataFim 30/09/2026 -SemEnvioEmail
```

---

## O que a planilha final contém

**Aba 1 - `DISPONIBILIDADE`:** colunas `Cenário` (A/B), `Profissional`,
`Data`, `Dia da Semana`, `Hora`, `Cliente Sugerido`, `Telefone`, `Email`,
`Último Atendimento`, `Turno Habitual`, `Observação`.

`Dia da Semana` é derivado da própria `Data` (segunda-feira, terça-feira,
..., sábado, domingo). O nome vem da **cultura `pt-BR` do .NET**
(`ToString('dddd', CultureInfo)`), não de literais no `.ps1` - "terça-feira"
e "sábado" têm acento, e literal acentuado dentro do script seria lido como
ANSI/cp1252 pelo PowerShell 5.1 e chegaria corrompido na planilha.

`Último Atendimento` sai como `dd/MM/yyyy HH:mm`, em célula formatada como
texto. O dado **interno** continua no formato do MySQL
(`yyyy-MM-dd HH:mm:ss`) porque é assim que ele ordena corretamente como
string (`Sort-Object UltimoAtendimento`) e permite extrair a hora habitual
por índice - a conversão acontece só na escrita da planilha. Sem a
formatação como texto, o Excel reinterpretava a string como data e exibia no
padrão americano (`8/24/26 13:00`).

**Ordenação:** profissional + data + hora + cenário. Dentro de cada
profissional, as linhas ficam na ordem cronológica real do dia/semana dele -
Cenário A e B aparecem intercalados conforme a agenda (um horário vago às
09h aparece antes de um às 14h, seja ele A ou seja B). A cada troca de
profissional entra uma **linha em branco**, para ficar fácil ver de relance
onde começa a agenda de cada um. `Cenário` só entra como critério de
desempate (data+hora iguais é raro).

- **Cenário A:** o profissional tinha um horário livre e havia um paciente
  atendido por ele nas últimas N semanas que **não tem nenhum agendamento
  futuro no período** (com nenhum profissional - ver "Paciente que já tem
  agendamento futuro" nos cenários de erro). Cada paciente é sugerido no
  máximo uma vez (não repete o mesmo nome em vários buracos), priorizando
  quem foi atendido mais recentemente -
  **mas só depois de tentar casar pelo turno habitual do paciente** (ver
  abaixo). `Turno Habitual` mostra se o histórico dele é predominantemente
  de manhã (08:00-11:59) ou de tarde (12:00-18:59).
- **Cenário B:** horário livre sem nenhum candidato encontrado no histórico
  recente. `Cliente Sugerido` fica em branco e `Observação` diz
  "Horário vago - sem sugestão".

### Compatibilidade de turno (evita sugestão inútil na prática)

Um paciente que sempre agenda de tarde não serve para preencher um buraco de
manhã - na prática, essa sugestão seria descartada assim que alguém olhasse a
planilha. E dentro do mesmo turno, dois pacientes diferentes (um de hábito
14:00, outro de hábito 15:00) não são intercambiáveis - encaixar cada um no
horário do outro é o tipo de sugestão que parece certa "no papel" (mesmo
turno) mas erra na prática. Por isso, para cada horário vago, a skill:

1. Calcula o turno do próprio horário (Manhã/Tarde) e determina, para cada
   paciente candidato, o **horário específico mais frequente** dele no
   histórico (não só o turno amplo) - por exemplo "14:00", calculado a
   partir de todas as visitas dentro da janela de `-SemanasHistorico`.
2. Primeiro tenta achar, entre os candidatos ainda não usados daquele
   profissional e do turno compatível (ou "Indefinido" - histórico
   insuficiente para saber), o de **horário habitual mais próximo** do
   horário vago. Empate na distância desempata pelo atendimento mais
   recente.
3. **Só se não sobrar nenhum candidato do turno certo** é que usa um
   candidato de turno diferente (mesmo critério de proximidade entre os
   restantes) - e nesse caso a linha vem com `Observação` começando em
   `ATENÇÃO:` e **destacada em amarelo** na planilha, para o usuário
   confirmar manualmente antes de agendar. A skill nunca esconde essa
   divergência - prefere sugerir sinalizando a errar silenciosamente.

A coluna `Turno Habitual` mostra o horário específico e o turno entre
parênteses (ex.: `14:00 (Tarde)`), e a `Observação` sempre diz se o horário
bateu exatamente com o hábito do paciente ou quantos minutos de diferença
houve.

Isso corrige dois problemas reais encontrados em teste com o usuário
(08/09/2026): a primeira versão (1) sugeria pacientes só pelo "mais recente
atendido", sem olhar o turno - sugeriu uma paciente com histórico 100% de
tarde para um horário de manhã; e (2) mesmo depois de corrigir por turno,
ainda trocava dois pacientes do MESMO turno entre si (um de hábito 15:00 foi
encaixado às 14:00, e vice-versa) - só resolvido ao descer do nível "turno"
para o nível "horário específico".

### Aba 2 - `SEM AGENDAMENTO`: pacientes recorrentes para contatar

Todo paciente que apareceu no histórico recente (`sbx990`, últimas N
semanas) e **não tem agendamento futuro** no período consultado, mas também
**não foi sugerido** em nenhum horário vago (ou porque o profissional dele
não teve buracos suficientes, ou porque outro paciente mais recente já
ocupou o horário compatível), entra nesta aba: `Profissional`, `Cliente`,
`Telefone`, `Último Atendimento`, `Turno Habitual`.

O objetivo é dar ao usuário uma lista pronta para ligar e entender por que
esse paciente ainda não remarcou - pode ser simplesmente falta de
disponibilidade de horário compatível, mas também pode ser um sinal de
abandono de tratamento que vale a pena investigar.

---

## Gravação em `sc0990` (agenda futura nativa do 4clinics) - OFF por padrão

O documento original pedia para inserir a agenda futura baixada em `sc0990`.
Investigando o schema real (08/09/2026), isso tem um problema: `sc0990` exige
`pacienteId`, `profId`, `especId`, `tipoConsultaId`, `planoSaudeId` (todos
`INT NOT NULL`), mas:
- `sa2990` (profissionais) e `sa4990` (especialidades) **têm dados reais** →
  `profId` e `especId` são resolvidos por de/para automaticamente e **são
  usados normalmente no cruzamento**, com ou sem gravação em `sc0990`.
- `sa1990` (pacientes), `sa3990` (tipo de consulta) e `sa5990` (plano de
  saúde) **estão vazias** no banco de referência → não há como resolver
  `pacienteId`/`tipoConsultaId`/`planoSaudeId` de verdade hoje.

Por isso, **por padrão a skill não escreve em `sc0990`** - todo o cruzamento
roda em memória, lendo `sb5990`/`sbx990` (somente leitura) e o .xls recém
baixado. Isso evita popular uma tabela de produção com um `pacienteId`
inventado repetido em centenas de linhas de pacientes diferentes.

Se o usuário pedir explicitamente para gravar em `sc0990` mesmo assim, use
`-SyncToSc0` **e confirme com ele antes** que:
- `-PacienteIdPadrao`, `-TipoConsultaIdPadrao`, `-PlanoSaudeIdPadrao` vão ser
  usados como valores fixos (placeholder) em toda linha inserida - a
  observação de cada linha registra o cliente real do Simples Agenda para não
  perder essa informação;
- isso é diferente de "cada agendamento aponta pro paciente certo" - só fica
  correto de verdade quando `sa1990`/`sa3990`/`sa5990` forem populadas e a
  skill for atualizada para fazer o de/para real.

---

## Cenários de erro

| Cenário | Ação da skill | Mensagem |
|---------|----------------|----------|
| Data Início no passado | Rejeita antes de chamar o Simples Agenda | "Data Início precisa ser hoje ou no futuro." |
| Data Fim < Data Início | Rejeita | "Data Fim deve ser maior ou igual a Data Início." |
| Formato de data inválido | Rejeita | "Formato de data inválido. Use dd/mm/yyyy." |
| Falha de login | Aborta, não salva senha errada | "Credenciais inválidas. Verifique login e senha." |
| CAPTCHA exigido | Aborta, nunca resolve | "O site está pedindo CAPTCHA. Faça login manual e tente depois." |
| HTTP 429 | Aborta sem repetir | "Muitas requisições em sequência. Aguarde alguns minutos." |
| Nenhum agendamento futuro no período | Segue normalmente - todos os slots de `sb5990` viram Cenário B | (informativo, não é erro) |
| `sb5990` vazio para os profissionais do período | Aborta (nada para cruzar) | "Nenhuma disponibilidade cadastrada em sb5990 para os profissionais informados." |
| Profissional/serviço sem correspondência em `sa2990`/`sa4990` | Avisa e exclui só aquele profissional/linha do cruzamento, resto continua | "[AVISO] Profissional 'X' não encontrado em sa2990 - excluído do cruzamento." |
| Falha de conexão MySQL | Aborta, preserva o .xls baixado | "Falha ao conectar no banco. O .xls original foi mantido em: [caminho]" |
| Arquivo .xls corrompido/incompleto | Apaga o parcial, aborta | "Download interrompido. Tente novamente." |
| Excel COM indisponível | Aborta | "Microsoft Excel não está disponível para gerar a planilha." |
| Falha no envio de email (destinatário fora da allowlist, credencial revogada, TLS, SMTP) | Não apaga a planilha; avisa `-EmailErroPara` com o motivo | "[ERRO] Falha ao enviar a planilha (exit N): [motivo]. Planilha preservada em [caminho]." |
| Email de erro também falha (ex: `EmailErroPara` fora da allowlist) | Só loga - a planilha já fica preservada em disco de qualquer forma | "[AVISO] Também falhou o envio do email de erro... Verifique manualmente." |
### Acentos corrompidos: a causa era a leitura do MySQL, não a escrita do Excel

Bug real encontrado pelo usuário (08/09/2026): nomes com acento apareciam
corrompidos na planilha (`Galvão` virava `Galv├úo`). O sintoma visível era só
a planilha, mas o dano era bem maior - ver a seção seguinte.

**Causa raiz:** a saída do `mysqlsh` (que é UTF-8) era capturada com
`& mysqlsh.exe ... 2>&1`, e o PowerShell decodifica a saída de um processo
filho usando `[Console]::OutputEncoding` - que neste ambiente é **CP850**
(`ibm850`). Ou seja, **todo texto acentuado vindo do banco já entrava
corrompido na memória do script**, antes de qualquer planilha existir.

**Fix:** ler o stdout do `mysqlsh` com **UTF-8 explícito**, via
`System.Diagnostics.Process` com `StandardOutputEncoding`, em vez de
depender do encoding do console. Verificado que funciona igual em
`powershell -File` e `powershell -Command` (mexer em
`[Console]::OutputEncoding` não funciona: o resultado muda conforme o
contexto de invocação).

> **Registro de um erro de diagnóstico:** a primeira correção atacou o
> sintoma errado - assumiu que o Excel COM corrompia ao salvar, e revertia a
> transformação no `xl/sharedStrings.xml` depois do `SaveAs`. Funcionava na
> planilha (por reverter exatamente a mesma transformação CP850↔UTF-8), mas
> era um remendo: os dados seguiam corrompidos durante todo o processamento,
> e o bug de duplicação abaixo continuava de pé. Depois de corrigir a origem,
> esse pós-processamento passou a **corromper** o arquivo e foi removido. O
> Excel COM sempre gravou UTF-8 corretamente.

### Paciente que já tem agendamento futuro não é sugerido

Bug real encontrado pelo usuário (08/09/2026): a paciente Juliana, **já
agendada** com a Jasmara em 09/09 às 08:00, foi sugerida para preencher um
buraco da mesma Jasmara em 09/09 às 13:00.

Havia **duas causas somadas**:

1. **A corrupção de encoding acima.** A chave de comparação do paciente vinha
   corrompida do banco (`JULIANA QUINTELO GALV├UO`) e não batia com a chave
   vinda da agenda futura, lida via Excel COM e correta
   (`JULIANA QUINTELO GALVAO`). A exclusão de "já tem agendamento" falhava
   **exatamente e somente para pacientes com acento no nome** - os outros 14
   candidatos daquele profissional eram excluídos corretamente, o que fazia o
   bug parecer aleatório.
2. **A exclusão era por profissional.** Um paciente já agendado com a ENA
   ainda podia ser sugerido para a LUCIANA. Agora a exclusão é **global no
   período**: se o paciente tem qualquer agendamento futuro no intervalo
   consultado, ele não é sugerido - o objetivo da skill é achar quem **não**
   tem agenda futura.

**Cancelamento não conta como alocação:** um agendamento com status
`Cancelado` é ignorado nessa exclusão - quem teve a sessão cancelada é
justamente quem vale a pena reencaixar (mesmo critério já usado no cálculo
dos horários ocupados).

---

## Limitações e fora de escopo

- ✗ Não modifica, cancela nem cria agendamentos reais no Simples Agenda -
  só lê (export) e, opcionalmente, grava sugestões em `sc0990` com
  `-SyncToSc0`.
- ✗ Não resolve `pacienteId` real (ver seção acima) - Cenário A sugere pelo
  **nome** do cliente encontrado em `sbx990`, não por um `pacienteId` do 4clinics.
- ✗ Profissional ou serviço sem correspondência em `sa2990`/`sa4990` fica de
  fora do cruzamento (não trava a skill inteira, só aquele profissional).
- ✗ `sb5990` é um template semanal (dia da semana), não uma agenda por data -
  feriados, folgas pontuais ou bloqueios de última hora que não estejam
  cadastrados em `sb5990` não são considerados.
- ✗ Nunca chama `baixar_agenda.ps1` nem `db_manager.ps1` diretamente - só a
  skill `credential-manager` (mesmos `service_name` já usados por elas).
- ⚠ **Cadastro ambíguo confirmado em 08/09/2026:** `sa2990.profSimplesAgId =
  'FISIOTERAPIA'` está cadastrado em **dois** profissionais (SIDIELY e
  SOLANGE). Uma linha do Simples Agenda com `Profissional = FISIOTERAPIA`
  resolve para qualquer um dos dois (sem ordem garantida) - se isso aparecer
  no resultado, o problema é o cadastro em `sa2990` (precisa de um
  `profSimplesAgId` único por profissional), não a skill.

---

## Status

Schemas de `sb5990`/`sc0990`/`sbx990` e das tabelas de de/para (`sa2990`,
`sa4990`) confirmados contra o banco real em 08/09/2026 (ver
[`manifest.json`](manifest.json) → `schema_reference`). A execução completa
contra o Simples Agenda real com um período futuro genuíno ainda não foi
testada - rode uma vez com dados reais e revise a planilha antes de confiar
no resultado no dia a dia.
