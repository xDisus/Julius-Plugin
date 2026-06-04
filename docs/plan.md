# Julius — Implementation Plan

> **Source:** [requirements.md](requirements.md)  
> **Date:** 2026-06-04  
> **Type:** Plugin  
> **Depth:** Standard

---

## Summary

Julius é um plugin Claude Code que reduz consumo de tokens em 10-60% (dependendo do tier) usando hooks do ciclo de vida para interceptar, comprimir e rotear antes que tokens desnecessários entrem no contexto do modelo principal.

**Abordagem:** Hooks como middleware transparente. O modelo não sabe que o plugin existe — ele só recebe menos tokens e responde igual (ou quase igual).

**Nome:** Julius Rock — o pai do Chris em *Todo Mundo Odeia o Chris*. Frugal, econômico, obcecado por cada centavo.

**Ativação:** `julius normal|pro|beast`

**Repo:** `github.com/xDisus/Julius-Plugin` (público)

---

## Installation

### Via npm / npx (one-liner)

```bash
npx julius-plugin
```

O bin do npm detecta automaticamente o Claude Code instalado, copia o plugin para `~/.claude/plugins/julius/`, e registra os hooks. Zero configuração manual.

Para atualizar:
```bash
npx julius-plugin@latest
```

### Via Claude Code Plugin Marketplace

```bash
# Adicionar o marketplace do Julius
claude plugin marketplace add github:xDisus/Julius-Plugin

# Instalar o plugin
claude plugin install julius@julius-plugin

# Ou via slash command dentro do Claude Code:
/plugin marketplace add github:xDisus/Julius-Plugin
/plugin install julius@julius-plugin
```

### Via Git (manual)

```bash
git clone https://github.com/xDisus/Julius-Plugin.git ~/.claude/plugins/julius
claude plugin enable julius
```

### Verificar instalação

Dentro do Claude Code:
```
/julius
# → Mostra: "Julius active. Tier: normal. Switch: /julius pro | beast"
```

---

## Distribution Architecture

```
Julius-Plugin/                      # GitHub repo (public)
├── .claude-plugin/
│   └── marketplace.json           # Self-hosted marketplace manifest
├── package.json                    # npm package: name="julius-plugin", bin
├── bin/
│   └── install.sh                 # npx entrypoint: detects Claude, copies plugin
├── plugin.json                     # Plugin manifest
├── agents/                         # Caveman + tier-router agents
├── hooks/hooks.json                # Lifecycle hooks
├── skills/julius/SKILL.md          # /julius slash command
├── scripts/                        # Bash scripts (hooks)
├── lib/tier-config.json            # Thresholds per tier
└── README.md
```

### `package.json` (campos relevantes)

```json
{
  "name": "julius-plugin",
  "version": "1.0.0",
  "description": "Token economy plugin for Claude Code — every token counts.",
  "bin": {
    "julius-plugin": "./bin/install.sh"
  },
  "files": [
    "plugin.json",
    "agents/",
    "hooks/",
    "skills/",
    "scripts/",
    "lib/",
    "bin/",
    ".claude-plugin/"
  ],
  "keywords": ["claude-code", "claude-plugin", "token-economy"],
  "repository": "github:xDisus/Julius-Plugin",
  "license": "MIT"
}
```

### `marketplace.json`

```json
{
  "name": "julius-plugin",
  "owner": { "name": "xDisus", "email": "renan@disus.cloud" },
  "plugins": [
    {
      "name": "julius",
      "source": "./",
      "description": "Token economy plugin — Normal, Pro & Beast modes",
      "version": "1.0.0",
      "tags": ["token-economy", "optimization", "cost-saving"]
    }
  ]
}
```

### `bin/install.sh` (npx entrypoint)

Fluxo:
1. Detecta se Claude Code está instalado (`which claude` ou `~/.claude/`)
2. Cria `~/.claude/plugins/julius/` se não existir
3. Copia todos os arquivos do plugin (excluindo `.git`, `node_modules`, `tests`)
4. Se Claude Code estiver rodando: avisa para restartar
5. Printa: `✅ Julius installed. Run /julius in Claude Code to activate.`

Para desinstalar:
```bash
rm -rf ~/.claude/plugins/julius
# Ou: claude plugin remove julius
```

---

## Key Technical Decisions

| Decisão | Escolha | Justificativa |
|---------|---------|--------------|
| **Linguagem dos scripts** | Bash + jq + curl | Claude Code hooks executam shell commands. Bash é zero-dependência, jq é onipresente em ambientes dev |
| **Flash LLM client** | curl direto na Anthropic API | Scripts hook não têm SDK. `curl` + `ANTHROPIC_API_KEY` do ambiente do Claude |
| **Tier configuration** | Arquivo JSON compartilhado em `lib/tier-config.json` | Todos os scripts leem thresholds do mesmo lugar. Trocar tier = trocar 1 arquivo |
| **Compressed agents** | Arquivos `.md` em `agents/` com YAML frontmatter | Nativo do Claude Code. Modelo principal delega com `model: haiku` |
| **Manifest storage** | Arquivo JSON em `.claude/julius/` | Persiste entre turnos sem depender de DB |
| **Coach feedback injection** | stdout do hook `Stop` → context do próximo turno | Mecanismo nativo de hooks. Sem parsing necessário |

---

## Project Structure

```
Julius-Plugin/                        # GitHub repo (public)
├── .claude-plugin/
│   └── marketplace.json             # Self-hosted marketplace manifest
├── package.json                      # npm: julius-plugin, bin: ./bin/install.sh
├── bin/
│   └── install.sh                   # npx entrypoint: detects Claude, copies plugin
├── plugin.json                       # Plugin manifest
├── agents/
│   ├── julius-reader.md            # F1: Haiku reader with caveman prompt
│   ├── julius-executor.md          # F1: Haiku executor (lint, format, test)
│   ├── julius-researcher.md        # F1: Haiku web researcher
│   └── tier-router.md               # F3: Generic worker, model set by hook
├── hooks/
│   └── hooks.json                   # All hook registrations
├── skills/
│   └── julius/
│       └── SKILL.md                 # /julius slash command
├── scripts/
│   ├── compress-output.sh           # F4: PostToolUse output summarizer
│   ├── oracle-preprocess.sh         # F8: UserPromptSubmit flash pre-processor
│   ├── smart-compact.sh             # F5: PreCompact custom compactor
│   ├── large-file-guard.sh          # F6: PreToolUse Read redirector
│   ├── batch-synthesizer.sh         # F7: PostToolBatch cross-referencer
│   ├── keep-busy.sh                 # F9: TeammateIdle pipeline maintainer
│   ├── turn-coach.sh                # F10: Stop efficiency analyzer
│   ├── task-manifest.sh             # F11: TaskCreated/TaskCompleted compressor
│   ├── tier-setter.sh               # Sets active tier (called by /julius command)
│   └── flash-client.sh              # Shared: calls flash LLM via Anthropic API
├── lib/
│   └── tier-config.json             # Thresholds per tier (Normal/Pro/Beast)
├── tests/                            # U13: Integration tests
└── README.md
```

---

## Implementation Units

### Phase 1 — Core Foundation (Normal Tier)

#### U1: Plugin Scaffold + Tier System + Skill

| Field | Value |
|-------|-------|
| **Goal** | Estrutura base do plugin, sistema de tiers, skill que ensina o modelo |
| **Dependencies** | — |
| **Files** | `plugin.json` (Create), `skills/julius/SKILL.md` (Create), `lib/tier-config.json` (Create), `scripts/tier-setter.sh` (Create) |
| **Approach** | `plugin.json` registra o skill `julius` como command. Skill define `/julius normal\|pro\|beast` que chama `tier-setter.sh`. `tier-config.json` contém thresholds numéricos por tier. `tier-setter.sh` escreve o tier ativo em `.claude/julius/active-tier` |
| **Patterns** | Um JSON, um shell script, um SKILL.md. Minimalista |
| **Test Scenarios** | |
| | Happy: `/julius beast` → `active-tier` escrito como `"beast"` |
| | Happy: `/julius pro` → thresholds carregados corretamente |
| | Edge: `/julius` sem argumento → mostra tier atual |
| | Error: `/julius invalid` → erro claro, tier mantido |
| **Verification** | `cat .claude/julius/active-tier` mostra o tier; scripts leem `tier-config.json` |
| **Model** | Haiku (scaffold mecânico) |

#### U4: Model-Tier Agents (F3)

| Field | Value |
|-------|-------|
| **Goal** | Definir agentes haiku para tasks triviais; skill ensina modelo a delegar |
| **Dependencies** | U1 (plugin base) |
| **Files** | `agents/tier-router.md` (Create), update `skills/julius/SKILL.md` (Modify) |
| **Approach** | `tier-router.md` é um agente genérico com `model: haiku` (Normal) ou `model: haiku` (Pro/Beast). System prompt instrui a receber qualquer task e executar com ferramentas mínimas. Skill instrui o modelo principal: "Tasks como 'rode os testes', 'liste arquivos', 'formate código' → delegue ao `tier-router`" |
| **Patterns** | YAML frontmatter + system prompt enxuto. Sem tools de escrita no haiku (só Read, Bash, Grep, Glob) |
| **Test Scenarios** | |
| | Happy: Modelo principal recebe "rode pytest" → delega ao tier-router haiku |
| | Happy: Tier-router executa testes corretamente |
| | Edge: Tier-router falha → modelo principal assume a task |
| | Integration: Beast mode → tasks triviais nunca chegam ao modelo principal |
| **Verification** | Sessão com `/julius pro` + "liste os arquivos .py" → subagente haiku spawnado (visível no log) |
| **Model** | Sonnet (precisa escrever bons system prompts) |

#### U11: Turn Coach (F10)

| Field | Value |
|-------|-------|
| **Goal** | Analisar eficiência do turno após `Stop` e injetar coaching |
| **Dependencies** | U1 |
| **Files** | `scripts/turn-coach.sh` (Create), update `hooks/hooks.json` (Create/Modify) |
| **Approach** | Hook `Stop` dispara `turn-coach.sh`. Script analisa o output do turno via stdin (fornecido pelo Claude): conta preamble ("I'll...", "Let me..."), detecta tool calls sequenciais que poderiam ser paralelas, mede contexto atual. Se detecta ≥2 maus hábitos, stdout = `[JULIUS COACH] ...`. Se ≤1, stdout vazio = sem injeção. Normal tier: só reporta preamble >20% do turno. Pro/Beast: todos os checks |
| **Patterns** | stdout vazio = skip. Shell script stateless. jq para parsing |
| **Test Scenarios** | |
| | Happy: Turno com 30% preamble → coach injeta "17% preamble waste. Prefer action verbs." |
| | Happy: Turno limpo → stdout vazio, nada injetado |
| | Edge: StopFailure → coach skipped (não analisa erros) |
| | Error: Script crash → hook loga erro, não bloqueia |
| **Verification** | Sessão com `/julius normal`. Faz pergunta trivial. Checa se próximo turno tem mensagem `[JULIUS COACH]` no contexto (se preamble foi alto) |
| **Model** | Haiku (script simples de análise textual) |

#### U12: Task Manifest Compression (F11)

| Field | Value |
|-------|-------|
| **Goal** | Manter versão comprimida da lista de tasks, injetar no SessionStart |
| **Dependencies** | U1 |
| **Files** | `scripts/task-manifest.sh` (Create), update `hooks/hooks.json` (Modify) |
| **Approach** | `TaskCreated`: hook extrai task description, adiciona ao `tasks.json` em `.claude/julius/`. `TaskCompleted`: hook marca como done + captura output relevante (1 linha). `SessionStart`: hook injeta `[TASKS] 2/6 done. Active: #3 auth middleware. Next: #4 test expiry` no contexto. Sempre ativo (Normal+), zero risco |
| **Patterns** | JSON state file em `.claude/julius/tasks.json`. Append-only, nunca perde dados |
| **Test Scenarios** | |
| | Happy: Modelo cria 3 tasks → manifest mostra "0/3 done. Active: #1 ..." |
| | Happy: Task completada → manifest atualiza "1/3 done" |
| | Edge: Sessão reiniciada → manifest carrega do arquivo |
| | Edge: Task completada sem TaskCreated prévio → graceful skip |
| **Verification** | `cat .claude/julius/tasks.json` após criar/completar tasks |
| **Model** | Haiku |

---

### Phase 2 — Compression Engine (Pro Tier)

#### U5: Tool Result Compression (F4)

| Field | Value |
|-------|-------|
| **Goal** | Resumir outputs de Bash/Read/Grep/Grep antes do modelo ver |
| **Dependencies** | U1 (tier config) |
| **Files** | `scripts/compress-output.sh` (Create), `scripts/flash-client.sh` (Create), update `hooks/hooks.json` (Modify) |
| **Approach** | `PostToolUse` hook com matcher `Bash|Read|Grep|Glob`. Script lê tier-config: Pro threshold = 100 linhas, Beast = 20. Se output ≤ threshold, bypass. Se > threshold, chama `flash-client.sh` com prompt: "Summarize this output. Keep ALL errors, stack traces, file paths, line numbers. Drop progress bars, ANSI codes, repeated lines." Pro: mantém estrutura completa. Beast: ultra-compacto |
| **Patterns** | Early return (bypass) para outputs pequenos. Flash LLM só chamado quando necessário. `flash-client.sh` é shared utility |
| **Test Scenarios** | |
| | Happy: Bash output de 200 linhas → resumo de 15 linhas com erros preservados |
| | Happy: Output de 30 linhas no Pro → bypass, output cru |
| | Edge: Output contém "ERROR" → compressão nunca remove linhas com ERROR/FATAL/Traceback |
| | Edge: Flash API falha → fallback: output cru injetado (não bloqueia) |
| | Error: Script timeout → output cru, log de warning |
| **Verification** | Sessão Pro. `pytest` com 500 linhas. Modelo só vê "3 passed, 1 FAILED: test_x(line 45)..." |
| **Model** | Sonnet (lógica de preservação de erros é sutil) |

#### U6: Conversation Summarization (F5)

| Field | Value |
|-------|-------|
| **Goal** | Compactação customizada quando contexto enche |
| **Dependencies** | U1, U5 (flash client) |
| **Files** | `scripts/smart-compact.sh` (Create), update `hooks/hooks.json` (Modify) |
| **Approach** | `PreCompact` hook bloqueia compactação padrão. Script: mantém últimas N interações intactas (Pro: 15, Beast: 8). Interações antigas → flash resume em parágrafo denso por "episódio": decisões tomadas, erros corrigidos, fatos descobertos. Descarta diálogo verboso. Resultado injetado como `[HISTORICAL SUMMARY]` |
| **Patterns** | Nunca compacta os turnos mais recentes. Preserva decisões, descarta conversa. Flash processa em lotes de 10 interações |
| **Test Scenarios** | |
| | Happy: Contexto 87% → PreCompact resume interações 1-20 em 500 tokens |
| | Happy: Após compact: "Decided: use bcrypt. Fixed: JWT expiry in L145. Discovered: Redis timeout on cold start" |
| | Edge: Contexto < threshold → bypass (não compacta) |
| | Error: Flash falha → fallback pra compactação padrão do Claude |
| **Verification** | Sessão longa (30+ turnos). Verificar que sumário aparece no contexto |
| **Model** | Sonnet (flash prompt precisa ser preciso sobre o que preservar) |

#### U7: Subagent Reader (F6)

| Field | Value |
|-------|-------|
| **Goal** | Redirecionar leitura de arquivos grandes para subagente haiku |
| **Dependencies** | U1, U2 (caveman agents) |
| **Files** | `scripts/large-file-guard.sh` (Create), `agents/julius-reader.md` (Create), update `hooks/hooks.json` (Modify) |
| **Approach** | `PreToolUse` hook com matcher `Read`. Script verifica `file_path` e tamanho (via `wc -l`). Beast: >50 linhas → `exit 2` (bloqueia). Script então spawna `julius-reader` agent que lê o arquivo e retorna JSON com `{summary, structure, edit_targets, confidence}`. JSON é injetado como feedback via stdout. Se arquivo ≤ threshold → `exit 0` (deixa passar) |
| **Patterns** | `exit 2` = block. Feedback = stdout do hook. Caveman agent é haiku, custo ~1/30 do modelo principal |
| **Test Scenarios** | |
| | Happy: Read("auth.py", 500 linhas) → bloqueado → julius-reader retorna resumo de 200 tokens |
| | Happy: Read("auth.py", offset=145, limit=30) → 30 linhas < threshold → bypass |
| | Edge: Modelo não consegue trabalhar com resumo → faz Read direto (segunda tentativa, hook deixa passar) |
| | Error: Caveman-reader falha → fallback: deixa Read original passar |
| **Verification** | Beast mode. Pede "analise auth.py". Verificar que modelo nunca recebe arquivo >50 linhas cru |
| **Model** | Sonnet (lógica de fallback + JSON schema do retorno) |

#### U8: Batch Cross-Referencing (F7)

| Field | Value |
|-------|-------|
| **Goal** | Correlacionar outputs de tool calls paralelas antes do modelo processar |
| **Dependencies** | U1, U5 (flash client) |
| **Files** | `scripts/batch-synthesizer.sh` (Create), update `hooks/hooks.json` (Modify) |
| **Approach** | `PostToolBatch` hook. Recebe todos os outputs da batch. Script analisa: (1) arquivos lidos → detecta imports/classes compartilhadas, (2) grep results → agrupa por arquivo, (3) bash outputs → extrai métricas comuns. Se ≥2 outputs na batch, chama flash: "You received N tool outputs. Find cross-references and produce a unified report." Resultado injetado como `[BATCH SYNTHESIS]` |
| **Patterns** | Só ativa quando batch tem ≥2 outputs. Resultado é aditivo (não substitui outputs individuais) |
| **Test Scenarios** | |
| | Happy: Batch com Read(a.py) + Read(b.py) + Grep("import.*auth") → síntese: "b.py imports AuthManager from a.py (L12). 5 of 23 grep matches are cross-file refs" |
| | Happy: Batch com 1 tool → bypass |
| | Error: Flash timeout → skip synthesis, outputs crus mantidos |
| **Verification** | Sessão Pro. Dispara 3+ tool calls. Verificar mensagem `[BATCH SYNTHESIS]` no contexto |
| **Model** | Sonnet |

---

### Phase 3 — Full Beast Mode

#### U2: Caveman Agents (F1)

| Field | Value |
|-------|-------|
| **Goal** | Criar agentes com system prompt ultra-comprimido em caveman |
| **Dependencies** | U1 |
| **Files** | `agents/julius-reader.md` (Create, ou update se criado em U7), `agents/julius-executor.md` (Create), `agents/julius-researcher.md` (Create) |
| **Approach** | Cada agente com `model: haiku`. System prompt em caveman: sem artigos, sem preposições, verbos no imperativo. Ex: "U READ FILE. U FIND structure: classes, functions, notable lines. U RETURN JSON. NO EXPLAIN. NO PREAMBLE." Agentes referenciados pela skill `julius`, que instrui o modelo principal a delegar para eles em Beast mode |
| **Patterns** | System prompt <200 tokens. Retorno estruturado (JSON). Sempre haiku |
| **Test Scenarios** | |
| | Happy: Modelo delega "read and summarize auth.py" → julius-reader spawnado |
| | Happy: Caveman-reader retorna JSON válido em <500 tokens |
| | Edge: Modelo delega task complexa → caveman responde "TOO COMPLEX. DELEGATE BACK" |
| **Verification** | Beast mode. Verificar que subagentes usam haiku, retornam JSON compacto |
| **Model** | Haiku (escrever caveman é mecânico) |

#### U3: Internal Docs Compression (F2)

| Field | Value |
|-------|-------|
| **Goal** | SessionStart gera versão comprimida de docs de projeto |
| **Dependencies** | U1, U5 (flash client) |
| **Files** | Update `scripts/tier-setter.sh` ou novo `scripts/docs-compressor.sh` (Create), update `hooks/hooks.json` (Modify) |
| **Approach** | `SessionStart` hook (Beast mode only). Script lê `CLAUDE.md`, `AGENTS.md`, `.claude/rules/*.md`. Chama flash: "Compress this into caveman-style shorthand. Preserve all rules, conventions, commands. Drop explanations." Output cacheado em `.claude/julius/compressed-docs.md`. Injetado como additional instructions. Próximos SessionStart usam cache (só recompila se arquivos mudaram) |
| **Patterns** | Cache com hash dos arquivos fonte. Recompila só quando necessário |
| **Test Scenarios** | |
| | Happy: CLAUDE.md de 2K tokens → versão caveman de 400 tokens |
| | Happy: Arquivo não mudou → usa cache |
| | Edge: Sem CLAUDE.md no projeto → skip silencioso |
| **Verification** | `cat .claude/julius/compressed-docs.md` mostra versão caveman |
| **Model** | Haiku |

#### U9: Context Oracle (F8)

| Field | Value |
|-------|-------|
| **Goal** | Pré-processar prompt do usuário com flash antes do modelo principal |
| **Dependencies** | U1, U5 (flash client) |
| **Files** | `scripts/oracle-preprocess.sh` (Create), update `hooks/hooks.json` (Modify) |
| **Approach** | `UserPromptSubmit` hook (Beast only). Script recebe prompt + project context. Chama flash: "User prompt: X. Project index: Y. Identify: (1) relevant files, (2) likely approach, (3) potential pitfalls. Return in 200 tokens." Resultado injetado como prefixo do prompt: `[ORACLE] Targets: auth.py:145, middleware.py:89. Approach: check JWT expiry flow. Watch: Redis timeout.` |
| **Patterns** | Flash só processa prompt + index (não arquivos inteiros). Timeout curto (5s) |
| **Test Scenarios** | |
| | Happy: "debug o erro de auth" → oracle identifica auth.py, middleware.py |
| | Happy: Oracle output injetado → modelo pula fase de exploração |
| | Edge: Oracle retorna vazio → prompt segue normal |
| | Error: Flash timeout → skip, prompt inalterado |
| **Verification** | Beast mode. Prompt complexo. Verificar mensagem `[ORACLE]` no início do contexto |
| **Model** | Sonnet (prompt engineering do oracle é sutil) |

#### U10: Continuous Agent Pipelines (F9)

| Field | Value |
|-------|-------|
| **Goal** | Manter subagentes vivos entre turnos como serviços |
| **Dependencies** | U1 |
| **Files** | `scripts/keep-busy.sh` (Create), update `hooks/hooks.json` (Modify) |
| **Approach** | `TeammateIdle` hook. Quando um teammate (subagente) fica idle, script verifica: (1) há tasks pendentes no manifest, (2) há arquivos modificados não testados. Se sim, injeta prompt pro teammate: "Tester: run pytest on test_auth.py". Se não, deixa idle. Modelo principal só consulta resultados quando precisa |
| **Patterns** | Leitura do `tasks.json` (U11) e git diff. Nunca bloqueia — teammate idle é normal |
| **Test Scenarios** | |
| | Happy: Tester idle após 5s → keep-busy detecta untested changes → "run pytest on test_x.py" |
| | Happy: Nada pendente → teammate continua idle |
| | Edge: Teammate falha 3x seguida → keep-busy para de reativar |
| **Verification** | Pro mode. Sessão longa. Verificar que tester-agent roda testes sem o modelo principal pedir |
| **Model** | Haiku (lógica condicional simples) |

---

### Phase 4 — Polish

#### U13: Integration Tests + Documentation

| Field | Value |
|-------|-------|
| **Goal** | Testes end-to-end por tier, README, publish |
| **Dependencies** | All U1-U12 |
| **Files** | `README.md` (Create), `tests/` (Create) |
| **Approach** | README com: instalação, tiers, exemplos visuais de economia. Testes: scripts de shell que simulam cenários (mock do Claude Code hook stdin/stdout). Validação de tier-config.json. Smoke test de cada script |
| **Test Scenarios** | |
| | Happy: `./tests/test-all.sh` passa em todos os scripts |
| | Happy: Tier-config JSON válido (jq parse) |
| | Integration: Simular PostToolUse com output falso → verificar compressão |
| **Verification** | CI verde. Plugin instalável via marketplace |
| **Model** | Haiku (docs + testes boilerplate) |

#### U14: Distribution Infrastructure (npm + marketplace)

| Field | Value |
|-------|-------|
| **Goal** | Empacotar plugin para npm (npx) e marketplace do Claude Code |
| **Dependencies** | U1 (plugin base) |
| **Files** | `package.json` (Create), `bin/install.sh` (Create), `.claude-plugin/marketplace.json` (Create) |
| **Approach** | `package.json` com `bin.julius-plugin` apontando pra `bin/install.sh`. `bin/install.sh` detecta Claude Code, copia plugin pra `~/.claude/plugins/julius/`. `.claude-plugin/marketplace.json` é o manifest auto-hospedado no GitHub. `npm publish` publica o pacote. Marketplace do Claude Code referencia `github:xDisus/Julius-Plugin` |
| **Patterns** | `npx julius-plugin` → one-liner install. `files[]` no package.json exclui `.git`, `node_modules`, `tests` do pacote npm. `bin/install.sh` é idempotente (reinstalar = safe) |
| **Test Scenarios** | |
| | Happy: `npx julius-plugin` instala em `~/.claude/plugins/julius/` |
| | Happy: `/plugin marketplace add github:xDisus/Julius-Plugin` → `/plugin install julius@julius-plugin` |
| | Happy: `npx julius-plugin` com plugin já instalado → "Already installed. Updating..." |
| | Edge: Claude Code não instalado → "Claude Code not found. Install with: npm i -g @anthropic-ai/claude-code" |
| | Edge: `~/.claude/` não existe → cria diretório automaticamente |
| **Verification** | `npx julius-plugin` em máquina limpa → `/julius` funciona no Claude Code |
| **Model** | Haiku (script de shell + JSON boilerplate) |

---

## Phases

| Phase | Units | Deliverable | Model |
|-------|-------|-------------|-------|
| **1: Core Foundation** | U1, U4, U11, U12 | Normal tier funcional. Plugin instalável, `/julius normal` funciona. Coach + manifest ativos | Haiku-heavy |
| **2: Compression Engine** | U5, U6, U7, U8 | Pro tier completo. Compressão de outputs, sumarização, subagent reader, batch synthesis | Sonnet-heavy |
| **3: Full Beast** | U2, U3, U9, U10 | Beast tier completo. Caveman agents, docs comprimidos, oracle, pipelines | Mixed |
| **4: Polish** | U13, U14 | README, testes, npm publish, marketplace listing | Haiku |

---

## Scope Boundaries

### In Scope
- Plugin Claude Code nativo (hooks + agents + skills)
- Três tiers: Normal, Pro, Beast
- 11 features distribuídas nos tiers
- Scripts em Bash (zero dependências além de curl + jq)
- Flash LLM via Anthropic API (usa `ANTHROPIC_API_KEY` do ambiente)
- Distribuição via npm/npx e marketplace auto-hospedado no GitHub
- `npx julius-plugin` como one-liner de instalação

### Out of Scope
- Cache-hit maximization (API Anthropic não exposta)
- Modificação do modelo principal (modelo fixo na sessão)
- Output interception (MessageDisplay é observability-only)
- Dynamic agent routing via SubagentStart (rejeitado)
- FileChanged diff caching (rejeitado)
- Suporte a providers não-Anthropic (OpenAI, DeepSeek) — fase futura
- UI/config GUI — tudo via `/julius` slash command
- Registro no marketplace oficial da Anthropic (self-hosted apenas)

---

## Deferred Questions

1. **Flash model version:** Usar `claude-haiku-4-5` vs `claude-3-5-haiku`? Resolver na execução (testar custo/qualidade)
2. **Caveman vs Wenyan-full:** Qual comprime mais mantendo utilidade? Testar na U2 com exemplos reais
3. **Thresholds exatos:** 50/100/300 linhas são estimates. Ajustar com dados reais de sessão
4. **npm publish scope:** `julius-plugin` vs `@xdisus/julius-plugin`? `@xdisus/julius-plugin` é mais seguro contra name squatting
5. **Métricas de economia:** Como medir redução real de tokens? Hook `Stop` pode logar, mas precisa de baseline sem plugin
6. **Marketplace oficial Anthropic:** Registrar no marketplace centralizado vs manter self-hosted? Self-hosted é zero fricção inicial
