# libUE4SS.so — UE4SS em servidor Linux nativo

A peça que sustenta todo o resto. Sem ela, nenhum mod deste repositório roda.

Este **não** é um projeto nosso: é o `RE-UE4SS-Linux 0.1.1`, um downstream não oficial do UE4SS. O que documentamos aqui é o que medimos usando-o em produção.

---

## A afirmação que ele refuta

Páginas de mods e respostas de fórum repetem que servidor Linux nativo não roda mods, porque o UE4SS é Windows. O README do JolthogFishingShadowSync diz exatamente isso:

> Servidores dedicados Linux nativos não são suportados, porque não conseguem carregar o UE4SS.

Verdade para a distribuição oficial, que entrega uma DLL. Falso como afirmação geral: existe compilação nativa, e ela funciona.

Oito mods rodam com ela neste momento, incluindo dois que o próprio autor declara incompatíveis com Linux.

---

## Procedência

```
PackageName          RE-UE4SS-Linux
PackageVersion       0.1.1
Architecture         x86_64
BuildConfiguration   Game__Shipping__Linux
PackageSourceCommit  a5b3c4c5747d2c6a9162ac8283cb42c169a133c3
UEPseudoCommit       79b33ae93800a8d630c97b57b792a72831ce4fa9
PatternSleuthCommit  23d13d7471c854fb15b586deb2f2678a1b7bc690
```

Linhagem, de cima para baixo:

```
UE4SS-RE/RE-UE4SS          oficial
  └─ tc-imba/RE-UE4SS      porte Linux (branch linux-port)
       └─ NullPrism/RE-UE4SS-Linux   este build
```

Detalhes em `PROVENANCE.md`.

> **Aviso sobre este bloco.** Ele identifica as *fontes* do `RE-UE4SS-Linux
> 0.1.1`, não o binário em produção. O pacote oficial dessas fontes exige
> `GLIBC_2.39` e **não carrega** neste container. O que roda no servidor é o
> artefato desta receita, recompilado das mesmas fontes com o teto rebaixado
> para `GLIBC_2.28` — sha256
> `0b96231d9ad00f9de7213dea945ccfc7b9128ee80389986581a3cd7e68c41ff4`,
> 23.002.053 bytes, publicado no release `glibc228-v2`. Ver `README.md` nesta
> mesma pasta.

---

## Uma configuração obrigatória

No `UE4SS-settings.ini`:

```ini
[Hooks]
EngineTickResolveMethod = VTable
```

O padrão é `Scan`. Neste build os dois endereços divergem, e o log avisa em **todo** boot:

```
GameEngine::Tick address (vtable: 0xa396170; scan: 0xa396840)
WARNING: VTable and scan addresses differ for UGameEngine::Tick
Using scan address for GameEngine::Tick
```

Com `Scan`, o servidor travava com

```
Exception was "SIGSEGV: invalid attempt to read memory at address 0x00000000000000a0"
libUE4SS.so!TDetourInstance<...>::StaticHookFn(UEngine*, float, bool)
```

Aquela assinatura — `UEngine*, float, bool` — é o hook de `UGameEngine::Tick`. Com `VTable`, a última linha vira `Using vtable address` e o travamento não voltou.

Vale saber que **isso não era a causa de todos os nossos crashes** — a maioria vinha de erros nossos, listados no README principal. Mas é a primeira coisa a acertar, porque falha de forma aparentemente aleatória.

---

## Palworld 1.0.3 quebra o `HookEngineTick`

**Antes de deixar o servidor atualizar, leia isto.**

O [issue #38](https://github.com/NullPrism/RE-UE4SS-Linux/issues/38) do loader relata, neste mesmo commit (`a5b3c4c5`, `linux-v0.1.1`):

| versão do Palworld | `HookEngineTick` |
|---|---|
| 1.0.2.100993 | funciona |
| **1.0.2.101103** | **funciona — é a nossa** |
| 1.0.3.101283 | `Signal 11` cerca de 2-3 s depois de `Event loop start` |

Os outros 13 hooks seguem estáveis no 1.0.3; só o `EngineTick` cai.

**Por que isso importa aqui mais do que parece:** todos os mods desta coleção dependem do `EngineTick`. É ele que sustenta o `ExecuteInGameThreadWithDelay`, para o qual migramos AdminCommands, PalLootScaling, HumansWithGender, AutoLootNearbyItems e o refresh de config do PalLevelScaling — justamente porque `ExecuteWithDelay` e `LoopAsync` não disparam (ver a seção seguinte).

O workaround do issue é `HookEngineTick = 0`. O servidor fica de pé e **todos esses mods param de funcionar**. Não é solução, é a diferença entre servidor no ar e servidor reiniciando em loop.

### Nossa evidência pode ser a explicação

O autor do issue mostra um endereço só:

```
[PS] Found GameEngineTick: 0xa39f0d0
DIAG: signature=UGameEngineTick status=resolved address=0xa39f0d0
```

O nosso log, no mesmo loader, mostra **dois divergentes** — e o crash era o mesmo tipo:

```
GameEngine::Tick address (vtable: 0xa396170; scan: 0xa396840)
WARNING: VTable and scan addresses differ for UGameEngine::Tick
Using scan address for GameEngine::Tick

Exception was "SIGSEGV: invalid attempt to read memory at address 0x00000000000000a0"
libUE4SS.so!TDetourInstance<...>::StaticHookFn(UEngine*, float, bool)
```

Trocar para `EngineTickResolveMethod = VTable` resolveu no nosso caso. A hipótese do issue é prólogo recompilado no 1.0.3; pode ser, mais simplesmente, a varredura resolvendo o endereço errado — e ele não menciona ter testado essa opção.

Rascunho de comentário para o issue em `issue-38-comment.md`, para quem quiser contribuir.

---

## `ExecuteWithDelay` e `LoopAsync` não disparam — e é de propósito

**Não é um bug.** Está explícito em `UE4SS/include/Mod/LuaMod.hpp`:

```cpp
auto start_async_thread() -> void
{
#ifdef __linux__
    // Native Linux currently disables the per-mod asynchronous worker
    // because its shutdown path can intermittently terminate the host
    // process. Lua features that depend on update_async are unavailable
    // until the thread lifecycle is made safe on Linux.
    return;
#else
    m_async_thread = std::jthread{&Mod::update_async, this};
#endif
}
```

A thread assíncrona por mod é desativada no Linux porque o encerramento dela às vezes mata o processo do servidor. `ExecuteAsync`, `ExecuteWithDelay` e `LoopAsync` empilham em `m_pending_actions`, e o único consumidor é `process_delayed_actions()`, chamado apenas por `update_async()` — a função da thread que nunca nasce.

Daí o silêncio absoluto: o agendamento é aceito, a fila cresce, ninguém consome.

**Não reative a thread.** Seria trocar uma falha silenciosa por travamentos aleatórios no encerramento — e travamento intermitente é muito pior de diagnosticar do que um temporizador que não dispara. O mantenedor escolheu o menos pior.

### O contorno

`ExecuteInGameThreadWithDelay` funciona, e no tempo pedido. Um temporizador se faz reagendando:

```lua
local function tick()
    pcall(doWork)
    pcall(function()
        ExecuteInGameThreadWithDelay(intervalMs, tick)
    end)
end
```

O reagendamento vai num `pcall` separado de propósito: se o trabalho falhar, o temporizador precisa sobreviver, ou um erro isolado para o mod pela sessão inteira.

Foi assim que corrigimos quatro mods: AdminCommands, PalLootScaling, HumansWithGender e AutoLootNearbyItems.

### Uma correção possível, para quem for recompilar

Em vez de reativar a thread, dá para processar a fila no game thread — onde o `EngineTick` já roda com segurança.

O `engine_tick_hook` em `LuaMod.cpp` (perto da linha 4024) já faz exatamente esse tipo de trabalho:

```cpp
process_simple_actions(LuaMod::m_engine_tick_actions);
process_delayed_actions<GameThreadExecutionMethod::EngineTick>(LuaMod::m_delayed_game_thread_actions);
```

Acrescentar ali, sob `#ifdef __linux__`, uma passada em `process_delayed_actions()` (a versão sem template, das ações assíncronas) de cada LuaMod ativo faria as três funções voltarem a funcionar, sem thread nenhuma.

Dois pontos exigem cuidado antes de tentar:

O `engine_tick_hook` é estático e `process_delayed_actions()` é método de instância — precisa de acesso à lista de mods carregados.

E `process_delayed_actions()` usa `async_lua()`, um estado Lua separado do principal. Executá-lo no game thread é seguro **porque** a thread está desativada e ninguém mais toca esse estado — mas `make_async_state` continua sendo chamado, então o estado existe. Se a thread for reativada algum dia, essa mudança passa a ser uma corrida.

Não aplicamos: exige recompilar num ambiente Linux e testar o ciclo de vida com cuidado. O contorno em Lua resolve para quem escreve os mods, e é onde está o custo menor.

## Outras diferenças em relação ao Windows

**Sem interface gráfica.** Os dumpers do UE4SS (objetos, headers C++, geração de `.usmap`) dependem da janela e não estão acessíveis num servidor headless. Para obter um `.usmap` deste build, use um dump público ou gere pelo cliente Windows.

**`RegisterKeyBind` carrega e não faz nada.** Não há entrada local. Mods que só se controlam por tecla ficam sem controle — use arquivo de configuração.

**Classes de HUD não existem.** `NotifyOnNewObject("/Script/Pal.PalHUDService")` nunca dispara aqui, o que quebra a inicialização de mods que esperam o HUD. `RegisterHook` em `ServerAcknowledgePossession` é a alternativa que funciona: dispara quando um jogador entra.

**Lua 5.4.7, sem LuaJIT.** Confirmado no binário: a string `Lua 5.4.7`, o símbolo `lua_resetthread` (exclusivo de 5.4) e nenhum marcador de LuaJIT. Isso importa porque mods escritos para LuaJIT podem **não carregar**: reatribuir a variável de controle de um `for` é legal em 5.1 e erro de compilação em 5.4. Foi a primeira barreira do AutoLootNearbyItems, antes mesmo do agendador.

**A reflexão é rasa.** `ForEachProperty` e `ForEachFunction` devolvem zero para tudo, em silêncio — inclusive para classes cujas funções existem e podem ser enganchadas. Consulte por nome com `StaticFindObject`, e sempre inclua um nome que você sabe existir como controle.

---

## Licença e suporte

`LICENSE` é a do UE4SS. Este é um downstream não oficial: **não é afiliado nem suportado pelo projeto UE4SS**, e problemas com ele não devem ser levados aos mantenedores oficiais.
