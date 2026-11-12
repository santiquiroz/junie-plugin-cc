# junie-plugin-cc

Delega tareas de código acotadas desde [Claude Code](https://claude.com/claude-code)
a la CLI de JetBrains Junie (`junie`) en modo headless.

Claude Code sigue siendo el orquestador: define el contrato, conserva las
decisiones de dominio y revisa los cambios. Usa este plugin para una spec
acotada, un renombre, boilerplate, una corrección, una investigación enfocada
o una segunda opinión de solo lectura. Junie es lento: una tarea trivial
tardó unos 35 segundos con `junie-lite`.

> Read this in English: [README.md](README.md)

## Cuándo conviene

- **Tareas acotadas:** una spec, un renombre, boilerplate, una corrección o
  una investigación enfocada; trabajo con un contrato claro que no necesita
  el contexto de la conversación.
- **Segundas opiniones de solo lectura:** `--read-only` revisa código pegado
  o un diff en un worktree desechable sin tocar el repositorio original.
- **Corridas largas desacopladas:** los procesos se desacoplan y corren hasta
  45 minutos por defecto mientras sigues trabajando; una espera interrumpida
  puede retomarse después con el id del proceso.
- **Costo honesto:** Junie es lento. Mantén las tareas delegadas autocontenidas
  y no lo uses para respuestas rápidas.
- **Modelo gratuito por defecto:** `junie-lite` es gratis (sin créditos).
  Usa `--model` para otros modelos que aceptan `--effort` y consumen créditos
  de JetBrains.

## Requisitos

- Claude Code; el forwarder se ejecuta mediante su herramienta Bash (Git Bash
  en Windows).
- CLI de JetBrains Junie. Los datos verificados de este plugin corresponden a
  Junie **26.11.1 en Windows 11**.
- Node.js en `PATH`; el forwarder usa `node` para parsear el resultado JSON.
- Autenticación mediante inicio de sesión interactivo con `junie` (crea
  archivos `*.dpapi`) o la variable de entorno `JUNIE_API_KEY`.

En Windows, Junie instala un shim `~/.local/bin/junie.bat`; el binario real
está en `<data>/versions/<v>/junie/junie.exe` donde `<data>` = `$JUNIE_DATA_DIR`
o `~/.local/share/junie` y `<v>` = primera línea de `<data>/current`.
En Linux/macOS, `junie` se espera en `PATH`. `JUNIE_BIN` reemplaza la selección
del launcher (también lo usan las pruebas).

## Instalación

En Claude Code:

```text
/plugin marketplace add santiquiroz/junie-plugin-cc
/plugin install junie@junie-plugin-cc
```

## Configuración inicial

Una vez por máquina:

```text
/junie:setup
```

Si hace falta, ejecuta `junie` una vez en una terminal normal para iniciar
sesión de forma interactiva. El comando setup verifica estas condiciones sin
mostrar credenciales.

## Uso

```text
/junie:rescue --background add unit tests for src/utils/money.ts covering rounding and negative amounts
/junie:rescue --read-only review this pasted diff for race conditions: <diff>
/junie:rescue --model gemini-3.7-flash --effort high diagnose this focused build failure
```

`/junie:rescue` invoca automáticamente el subagente `junie-rescue`, reenvía la
solicitud tal cual como su prompt y devuelve su salida verbatim, incluidas las
líneas `[junie-rescue] WARNING:`. Pon los flags antes de la tarea:

- `--wait` — predeterminado; ejecuta el subagente en foreground. Espera un
  proceso Junie desacoplado mediante tramos de `wait`. Si se interrumpe,
  conserva el id para usar `wait` o `cancel` después: el proceso sigue.
- `--background` — ejecuta el subagente en background y entrega su salida al
  terminar. Estos flags de ejecución se eliminan del prompt antes de
  reenviarlo; las llamadas Bash del forwarder siguen siendo foreground.
- `--model <slug>` — opcional; si se omite, Junie usa `junie-lite` (gratis).
  El slug se valida antes de ejecutar.
- `--effort <tier>` — `low`, `medium` o `high`. Solo aplica a modelos que no
  sean `junie-lite`. `junie-lite` ignora este flag.
- `--read-only` — ejecuta Junie en un worktree desechable; cualquier edición
  que intente se descarta y el repositorio original permanece intacto. Pega
  el código o diff a revisar.
- `-C <dir>` — ejecuta Junie en otro directorio, como un worktree de git,
  en lugar del actual de quien llama. El directorio home, sus ancestros y
  las carpetas de configuración de agentes (`~/.claude`, `~/.codex`,
  `~/.copilot`, `~/.gemini`, `~/.ssh`, `~/.config`, `~/.junie-rescue`,
  `~/.junie`, `~/.dsh`) se rechazan.

### Corridas largas

Las ejecuciones duran hasta `JUNIE_RESCUE_MAX_SECONDS` (predeterminado:
2700 segundos, 45 minutos). `start` desacopla el proceso y `wait <id>` espera
en tramos de 480 segundos (`--slice <segundos>` acepta hasta 540). Cada tramo
es una llamada Bash foreground independiente con timeout 600000 ms; el código
75 indica que sigue corriendo. El presupuesto es
`1 + 1 + ceil(MAX/480) + 1`. Si se interrumpe el subagente, el proceso sigue:
conserva su id para usar `wait <id>` o `cancel <id>` después. Cancelar termina
con código 130; esperar pasada la fecha límite mata el árbol de procesos y
termina con código 124. Las ediciones permanecen en el árbol de trabajo.
`run` conserva el límite corto predeterminado de 540 segundos
(`JUNIE_RESCUE_TIMEOUT` cambia los segundos). El forwarder envía la tarea y
sus restricciones en un archivo temporal leído por stdin, no en los argumentos
del proceso.

### Qué ejecuta el forwarder

El subagente `junie-rescue` llama a `preflight`, luego `start` y repite
`wait <id>` mientras termine con código 75. Cada llamada es foreground. El
script desacopla Junie con `nohup`, background y `disown`; guarda los archivos
del proceso en `${JUNIE_RESCUE_HOME:-$HOME/.junie-rescue}/jobs/<id>/`. Crea un
archivo de tarea con la solicitud y sus restricciones, y ejecuta el equivalente a:

```bash
junie --project <directorio actual nativo> \
  --skip-update-check --output-format json \
  --skill-default-locations=false --command-default-location=false \
  --agent-default-location=false --mcp-default-locations=false \
  --config-default-locations=false --share-anonymous-statistics=false \
  --json-output-file <ruta temporal nativa> \
  --model junie-lite \
  < <archivo de tarea con restricciones>
```

`--model <slug>` reemplaza `junie-lite`. Modelos que no sean `junie-lite` con
`--effort` agregan ese flag. `JUNIE_RESCUE_SKILLS` agrega `--skill-location`
por directorio. El proceso hijo recibe `GIT_TERMINAL_PROMPT=0`,
`GIT_SSH_COMMAND="ssh -o BatchMode=yes"`, sin overrides de conversión de rutas
MSYS y el archivo de tarea en stdin. Cuando existe `cygpath -w`, se usa para
convertir las rutas.

Después de la corrida, el forwarder imprime el campo `result` del JSON de salida,
una línea de uso (modelo, tokens, costo), el `sessionId` y los archivos cambiados.
Los códigos ANSI se eliminan del stdout de Junie.

## Modelo de seguridad

**Junie no tiene sandbox en Windows y aprueba automáticamente todos los comandos en modo headless.**
El flag `--read-only` ejecuta Junie en un worktree desechable y descarta lo
que edite ahí. En corridas normales Junie puede editar cualquier archivo del
workspace y, como sus comandos de shell corren sin restricción con tu usuario,
también puede escribir fuera del workspace, borrar archivos o hacer `git push`
si así lo decide.

Las restricciones de la tarea prohíben hacer commit, push, reset, checkout,
clean, cambiar de rama y borrar archivos, pero las restricciones del prompt no
son un sandbox: el delegado aún puede editar archivos dentro del workspace. Antes
y después, el forwarder compara `HEAD`, rama, stash, git config y hooks, e
imprime `[junie-rescue] WARNING:` si detecta cambios. Revisa cada aviso y el
diff del árbol de trabajo antes del siguiente comando git.

### Riesgos

- **Sin sandbox en Windows:** Junie headless corre en modo "Auto" y aprueba
  cualquier comando. Ignora `allowlist.json` a nivel de usuario y proyecto.
- **Ediciones de archivos:** Junie puede crear, modificar y renombrar archivos
  en el workspace. Revisa `git status` y `git diff` después de cada corrida.
- **Comandos de shell:** Junie puede ejecutar comandos de shell arbitrarios.
  Las restricciones le piden que no lo haga, pero nada lo impide.
- **Worktree de solo lectura:** `--read-only` apunta a Junie a un worktree
  desechable y descarta lo que edite ahí. No es un sandbox: un comando que
  nombre una ruta absoluta fuera del worktree igual se ejecuta.

## Configuración

| Variable | Predeterminado | Propósito |
|---|---|---|
| `JUNIE_BIN` | descubrimiento del launcher | Reemplaza la selección del binario de Junie (también lo usan las pruebas) |
| `JUNIE_API_KEY` | ninguna | Autenticación; tiene prioridad sobre archivos dpapi |
| `JUNIE_HOME` | `~/.junie` | Directorio home de Junie (para búsqueda de dpapi_credentials) |
| `JUNIE_DATA_DIR` | `~/.local/share/junie` | Directorio de datos de Junie (para búsqueda del binario versionado) |
| `JUNIE_RESCUE_HOME` | `$HOME/.junie-rescue` | Los archivos de cada proceso viven bajo `jobs/<id>/` |
| `JUNIE_RESCUE_MAX_SECONDS` | `2700` (45 minutos) | Fecha límite de corridas desacopladas para `start`/`wait` |
| `JUNIE_RESCUE_TIMEOUT` | `540` | Límite corto del comando `run`, en segundos |
| `JUNIE_RESCUE_SKILLS` | ninguna | Directorios de skills separados por `;` → `--skill-location` cada uno |
| `JUNIE_RESCUE_FORCE_WINDOWS` | `0` | Trata el host como Windows (pruebas) |
| `JUNIE_RESCUE_KILL` | `taskkill` | Comando para matar árboles de procesos (pruebas herméticas) |

## Solución de problemas

- **Sin credenciales (código 70):** `JUNIE_API_KEY` tiene prioridad. Si no
  existe, setup comprueba `$JUNIE_HOME/dpapi_credentials/` para cualquier
  archivo `*.dpapi` sin leerlo. Si no encuentra ninguno, ejecuta `junie` una
  vez en una terminal normal para iniciar sesión y luego `/junie:setup`.
- **Falta la CLI (código 127):** instala JetBrains Junie o verifica que
  `junie` esté en `PATH`. `JUNIE_BIN` reemplaza la selección del launcher.
  Ejecuta `/junie:setup` de nuevo.
- **Falta Node (código 127):** instala Node.js y verifica que `node` esté en
  `PATH` para parsear el resultado JSON.
- **Salida 0 sin JSON:** Junie salió correctamente pero no produjo archivo
  de resultado — la tarea puede no haberse completado. Revisa la salida.
- **Cuota o límite de créditos (código 69):** cuando una corrida falla (código
  distinto de 0, sin JSON de resultado o con `errors` en él) y su salida menciona
  `quota`, `credit`, `rate limit`, `429`, `too many requests` o `insufficient`,
  el forwarder lo informa. Una corrida exitosa nunca se clasifica, así que una
  tarea sobre código de cuotas no lo dispara. Nunca reintentes automáticamente.
- **Modelo fuera del plan gratis:** la capa gratuita es "Junie Lite-only
  access"; cualquier otro `--model` falla con ese mensaje y el forwarder sugiere
  `--model junie-lite`.
- **Subagente interrumpido:** un subagente interrumpido deja el proceso
  desacoplado corriendo. Conserva su id para usar `wait <id>` o `cancel <id>`
  después. Cancelar termina con código 130; esperar pasada la fecha límite
  mata el árbol de procesos y termina con código 124. Las ediciones permanecen
  en el árbol de trabajo.

## Con otros delegados

Si usas varios plugins de delegación, decide su orden en tu `CLAUDE.md`;
este plugin no asume ninguno. Ante señales de cuota, rate limit o
autenticación se detiene y lo informa, para que quien llama elija otra vía.

Proyectos relacionados: [deepseek-plugin-cc](https://github.com/santiquiroz/deepseek-plugin-cc), [copilot-plugin-cc](https://github.com/santiquiroz/copilot-plugin-cc), [antigravity-plugin-cc](https://github.com/santiquiroz/antigravity-plugin-cc), [cursor-plugin-cc](https://github.com/santiquiroz/cursor-plugin-cc), [ollama-plugin-cc](https://github.com/santiquiroz/ollama-plugin-cc).

## Archivos y pruebas

| Ruta | Propósito |
|---|---|
| `agents/junie-rescue.md` | Subagente forwarder delgado, solo Bash |
| `scripts/junie-forward.sh` | Launcher, preflight, invocación segura, timeout y avisos git |
| `tests/run.sh` | Suite hermética con una CLI falsa de Junie |
| `tests/fake-junie.sh` | Binario falso de Junie para pruebas |
| `/junie:rescue`, `/junie:setup` | Comandos de delegación y preflight |
| `docs/delegation-guide.md` | Seguridad y fallback de delegación |
| `docs/claude-md-snippet.md` | Guía de delegación lista para pegar |

La suite se ejecuta con `bash tests/run.sh`. CI corre en Ubuntu y Windows.

## Licencia

[MIT](LICENSE)

**No está afiliado con JetBrains ni Anthropic.**
