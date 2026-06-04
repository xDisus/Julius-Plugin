# Julius — Token Economy Plugin for Claude Code

> **Status:** Requirements (ce-brainstorm output)  
> **Date:** 2026-06-04

## Problem

Claude Code sessions consomem tokens em excesso com:
- Preamble verboso ("I'll read the file to understand...")
- Tool outputs crus injetados na íntegra no contexto
- Subagentes usando modelo principal para tarefas triviais
- Contexto acumulando histórico não-comprimido
- Modelo principal lendo arquivos enormes que um haiku resumiria

## Core Insight

O plugin **não modifica** o loop do Claude Code. Ele usa hooks para interceptar eventos e injetar feedback. O modelo é "enganado" a ver menos tokens sem perceber que está vendo menos.

## Tiers (usuário escolhe no SessionStart)

| Tier | Filosofia | Garantia |
|------|-----------|----------|
| **Normal** | Zero perda de qualidade. Só otimizações transparentes | Output idêntico ao sem plugin |
| **Pro** | Compressão leve com redes de segurança | Pode perder nuance em histórico antigo |
| **Beast** | Máxima economia, abraça trade-off | Sem garantias; ideal para agentes autônomos |

## Feature Inventory (confirmed)

### Inter-agent Compression
- **F1:** Caveman agents — subagentes com system prompt em caveman/wenyan para tarefas mecânicas (Beast)
- **F2:** Internal docs compressed — SessionStart gera versão comprimida de CLAUDE.md/AGENTS.md (Beast)

### Smart Routing
- **F3:** Model-tier agents — haiku agents para tasks triviais (Normal: conservador; Beast: agressivo)

### Output & Context Compression
- **F4:** Tool result compression — PostToolUse resume outputs (Pro: 100+ linhas; Beast: 20+)
- **F5:** Conversation summarization — PreCompact customizado (Pro: 85%+; Beast: 60%+)
- **F6:** Subagent reader — PreToolUse redireciona Read de arquivos grandes pra haiku (Beast: 50+ linhas)
- **F7:** Batch cross-referencing — PostToolBatch correlaciona outputs paralelos (Pro+)
- **F8:** Context oracle — UserPromptSubmit pré-processa prompt com flash (Beast)

### Continuous Services
- **F9:** Continuous agent pipelines — TeammateIdle mantém subagentes vivos (Pro+)
- **F10:** Turn coach — Stop hook analisa eficiência e injeta coaching (Normal+)
- **F11:** Task manifest compression — TaskCreated/TaskCompleted mantém lista comprimida (Normal+)

## Out of Scope

- Cache-hit maximization (não exposto na API de plugins)
- Hash-based incremental context (sem acesso ao estado interno)
- Mirror mode / output interception (MessageDisplay é observability-only)
- Fallback model switching (modelo fixo na sessão)
- Dynamic agent routing via SubagentStart (rejeitado pelo usuário)
- FileChanged diff pre-digestion (rejeitado pelo usuário)
- Context-mode automático granular (risco de qualidade, rejeitado)

## Success Criteria

1. Beast mode: ≥60% redução de tokens em sessões típicas de desenvolvimento
2. Pro mode: ≥30% redução sem degradação percebida pelo usuário
3. Normal mode: ≥10% redução com zero mudança no output
4. Plugin ativado com comando único: `julius normal|pro|beast`
