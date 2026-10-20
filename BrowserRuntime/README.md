# Browser / Браузер

## English

Chrome DevTools MCP 1.10.1 provides the browser executor. Switchboard adds compact
card extraction, readiness checks, verified pagination and private checkpoints.
Install Node.js 22.12 or later, then run from the repository:

```sh
python3 BrowserRuntime/install.py
```

For an app-only installation, open Terminal, type `python3 `, drag `install.py`
from this folder into Terminal and press Return. The installer needs Node on PATH;
alternatively pass `--node /absolute/path/to/node`. It downloads the pinned archive,
verifies its SHA-512 and all extracted files, and runs no npm installation scripts.
It also installs pinned Chrome for Testing (154.0.8037.57) in the app-owned browser
directory, checking the pinned archive SHA-256. ARM64 and Intel Macs are
supported. Chrome for Testing does not auto-update: a new release requires an
updated installer/lock and rerunning installation. Regular Chrome is never a fallback.

In Settings → Browser, enable Use Chrome DevTools and select Apply browser setting
after current tasks finish. The agent opens the separate Chrome for Testing app
on first use, in manual debugging mode, then the adapter attaches.
The Apply button remains disabled during chat or background tasks; wait for them
to finish or stop the relevant chat task before reconnecting. No actions are replayed.
Sign in manually in the new testing-profile, or use Browser → Import cookies only… in the chat. Existing agent profile data is left
in place, but is not migrated; site sign-ins and Google account sync are not guaranteed. Google still decides whether to accept sign-in. Chrome
stays open across adapter reconnects; close its window yourself when finished.
Existing profiles are never adopted. Website cookies are copied only by an explicit native import; Codex authentication files are never copied.
The component is disabled by default. Turning it off also requires Apply or restart.

Browser data lives in `~/Library/Application Support/Switchboard/browser/`.
File uploads also accept files inside the current thread's project directory,
supplied by the host as the MCP process working directory. The adapter forwards
that canonical directory separately from browser storage to Chrome DevTools;
the upstream path and symlink checks remain enabled. Updating this setting in
code requires rebuilding and reconnecting the adapter; an existing process keeps
its original roots. No file copying into browser storage is needed.
`records/` contains private page checkpoints, action IDs and call/byte/time metrics.
Records persist until you delete them; they may contain job or other page data.
No automatic action replay or automatic continuation after reconnect is performed.
Closing an owned tab sends one close action, then briefly polls the page inventory
to confirm disappearance. An unconfirmed close stops the executor for review;
the close action is never automatically repeated.
Each chat has its own persistent profile, Chrome process and executor. Operations
are serialized within one environment and run concurrently across environments.
After Chrome exits, call `browser_open` explicitly to start a new task with the
same profile. Old session tokens are invalidated; actions are never replayed.
An uncertain transport failure still requires reconnecting the adapter.

`browser_screenshot` returns a JPEG of the task tab's viewport (longer side at most
1280 px) without bringing Chrome to front. `browser_input` sends trusted mouse and
keyboard events (click, double/right click, hover, drag, wheel scroll, key, type,
wait) at pixels of the latest screenshot, so custom widgets, canvas and hover menus
work. Clicks, drags, keys and typing require the observed `expectedURL`; every input
is journaled before dispatch and never replayed after an uncertain outcome.
`browser_read` returns an element tree with roles, names, values and stable `ref_N`
handles (or the main page text with `mode=text`), including open shadow DOM and
same-origin iframes; passwords and card fields are redacted. `browser_input` accepts a
`ref` instead of coordinates: the element is scrolled into view, and a stale or covered
element is refused without dispatch. `select` picks a `<select>` option by label or value.
After each input the adapter waits until navigation, network and DOM go quiet
(`settle`, default 3 s) and returns `changes`: added, changed and removed controls
keyed by ref, or the head of a new page. A plain in-page click needs no
`expectedURL`; submitting a form, following a link to another site and answering a
dialog require it and are flagged with `risk`. JavaScript dialogs are reported and
answered with `action=dialog`; tabs opened by an action are listed in `newTabs`.
Cross-origin iframes are read and operated like the page itself: their trees nest
under the iframe line and their refs work with `browser_input`. `action=upload`
attaches files from the chat's project directory to a file field by ref; for a
button that opens the picker from script, it clicks it with Chrome's file chooser
intercepted, so no native dialog appears.
`browser_eval` runs JavaScript once (journaled, expectedURL required) and returns the
last expression's value; `browser_logs` lists the tab's console messages or network
requests collected by Chrome DevTools.
`browser_find` returns refs for a short description ("submit button", "ссылка войти"),
matching words against roles, labels, values and link addresses across the tree and
its frames (lexical, not semantic). Dialogs raised inside frames and coordinate clicks
on a frame's submit buttons follow the same rules as on the page itself.

## Русский

Исполнитель браузера — Chrome DevTools MCP 1.10.1. Switchboard добавляет компактное
чтение карточек, проверку загрузки и переходов, а также локальные контрольные точки.
Установи Node.js 22.12 или новее, затем выполни из папки проекта:

```sh
python3 BrowserRuntime/install.py
```

Если есть только приложение: открой Терминал, набери `python3 `, перетащи в него
`install.py` из этой папки и нажми Return. Установщик ищет Node в PATH; можно указать
`--node /полный/путь/к/node`. Он скачивает закреплённый архив, проверяет SHA-512
и извлечённые файлы. Скрипты установки npm не выполняются.
Также устанавливается закреплённый Chrome for Testing (154.0.8037.57) в папку
браузера приложения с проверкой закреплённой SHA-256 архива. Поддерживаются ARM64
и Intel Mac. Автообновления нет: для новой версии нужны обновлённый установщик
и файл версий, затем повторная установка. Обычный Chrome не используется как запасной.

В настройках → Браузер включи «Использовать Chrome DevTools» и нажми «Применить
настройку браузера» после завершения текущих задач. При первом обращении агента
откроется отдельное приложение Chrome for Testing в режиме ручной отладки;
адаптер подключится после запуска. Кнопка применения недоступна во время задач
в чатах и фоновой обработки: дождись завершения или останови нужную задачу
в её чате перед переподключением. Действия не повторяются.
Войди на сайты в testing-profile или импортируй cookies через меню браузера чата. Старый профиль агента остаётся на месте,
но не переносится. Вход на сайты и синхронизация Google не гарантируются.
Решение о разрешении входа принимает Google.
Chrome остаётся открытым при переподключении адаптера; закрой его окно, когда закончишь. Cookies сайтов можно импортировать явно через меню браузера чата. Файлы авторизации Codex не копируются. По умолчанию компонент выключен. Отключение
тоже применяется кнопкой или после перезапуска.

Данные находятся в `~/Library/Application Support/Switchboard/browser/`.
Загрузка файлов также доступна из папки проекта текущего чата, которую приложение
задаёт как рабочий каталог MCP-процесса. Адаптер передаёт её канонический путь
в Chrome DevTools отдельно от служебной папки браузера. Проверки путей и симлинков
остаются включены. После изменения кода нужны сборка и переподключение адаптера:
уже работающий процесс сохраняет прежние разрешённые каталоги. Копировать файлы
в служебную папку браузера не требуется.
В `records/` сохраняются контрольные точки страниц, ID действий и счётчики
вызовов, объёма ответов и времени. Записи хранятся до ручного удаления и могут
содержать данные вакансий или других страниц. Закрытие своей вкладки отправляется
один раз; затем адаптер короткое время перечитывает список вкладок для подтверждения.
Если закрытие не подтверждено, executor останавливается для проверки, без повтора
команды закрытия. Действия не повторяются автоматически;
после переподключения задача не продолжается сама. Рабочей вкладкой владеет одна
задача. У каждого чата свой профиль, процесс Chrome и исполнитель; операции
разных сред выполняются параллельно.
После закрытия Chrome явно вызови `browser_open`, чтобы начать новую задачу
с тем же профилем. Старые session становятся недействительными; действия
не повторяются. При неопределённом сбое связи нужно переподключить адаптер.

`browser_screenshot` возвращает JPEG видимой части вкладки задачи (длинная сторона
до 1280 px), не выводя Chrome на передний план. `browser_input` отправляет настоящие
события мыши и клавиатуры (клик, двойной и правый клик, наведение, перетаскивание,
прокрутка колесом, клавиши, ввод текста, ожидание) в пикселях последнего скриншота,
поэтому работают нестандартные элементы, canvas и меню по наведению. Для кликов,
перетаскивания, клавиш и ввода нужен наблюдаемый `expectedURL`; каждое действие
записывается в журнал до отправки и не повторяется при неопределённом исходе.
`browser_read` возвращает дерево элементов с ролями, именами, значениями и стабильными
ссылками `ref_N` (или основной текст страницы с `mode=text`), включая открытые shadow DOM
и iframe того же сайта; пароли и данные карт скрыты. `browser_input` принимает `ref`
вместо координат: элемент прокручивается в видимую область, а устаревший или перекрытый
элемент отклоняется без отправки события. `select` выбирает пункт `<select>` по подписи
или значению.
После каждого действия адаптер ждёт окончания навигации, сетевых запросов и изменений
DOM (`settle`, по умолчанию 3 с) и возвращает `changes`: добавленные, изменённые
и удалённые элементы управления по ref или начало новой страницы. Обычному клику
внутри страницы `expectedURL` не нужен; отправка формы, переход по ссылке на другой
сайт и ответ на диалог требуют его и помечаются `risk`. Диалоги JavaScript
сообщаются в ответе и закрываются через `action=dialog`; вкладки, открытые действием,
перечислены в `newTabs`.
iframe с других сайтов читаются и управляются как сама страница: их дерево вложено
под строку iframe, а их ref работают в `browser_input`. `action=upload` прикрепляет
к полю файла по ref файлы из папки проекта чата; кнопку, которая открывает выбор
файла скриптом, оно нажимает с перехватом выбора файла в Chrome, и системное окно не
появляется. `browser_eval` один раз выполняет
JavaScript (с записью в журнал и обязательным expectedURL) и возвращает значение
последнего выражения; `browser_logs` показывает сообщения консоли или сетевые запросы
вкладки, собранные Chrome DevTools.
`browser_find` возвращает ref по короткому описанию («кнопка отправки», «login link»),
сопоставляя слова с ролями, подписями, значениями и адресами ссылок во всём дереве
и фреймах (по словам, не по смыслу). Диалоги внутри фреймов и клики по координатам
на кнопках отправки во фреймах подчиняются тем же правилам, что и на самой странице.

## Development contract

- `browser_open` returns an opaque session token. Every subsequent call needs it.
- `browser_cards` accepts CSS selectors as data; at most 500 cards, bounded fields,
  explicit `truncated`, `complete`, `reason` and `next`. An empty/loading shell is
  partial without an explicit `empty` selector. Completion describes one page.
- `browser_next` needs a completed checkpoint and either an observed snapshot UID
  or nextToken. It dispatches once and verifies changed IDs; no-op returns partial.
- `browser_action` supports scoped native form/navigation actions. Supply an
  exact observed `expectedURL` and globally unique `actionID`. Its result is not
  a submission receipt. Use `browser_verify` for a visible text/URL postcondition.
- `browser_screenshot`/`browser_input` use a direct CDP connection (`cdp.py`) to the
  owned page target recorded at `browser_open` only. Input coordinates are pixels of
  the latest screenshot; scrolling or a URL change invalidates that mapping.
  `input_smoke.py` checks them live on a local fixture.
- `browser_read` runs `page_tree.js` in the page's main world; refs live in a page-side
  registry (`Symbol.for('context-desk.refs')`, WeakRef) and survive reads until the
  element is removed. A hostile page can tamper with that registry like with any DOM
  data, so refs are a convenience, not an authority. `read_smoke.py` checks refs live.
- One persistent CDP session per owned tab keeps Page events enabled across calls:
  Chrome only lets a session that saw a dialog open answer it, and a new connection
  hangs while a dialog is showing. A dialog the session missed is answered through
  Chrome DevTools MCP's `handle_dialog`. Risk classes are heuristics (form submit
  controls, cross-origin links, Enter in a form field); script-only buttons are not
  classified. Ref numbers continue across documents, so an old ref is stale rather
  than pointing at a new element. `settle_smoke.py` checks settling, changes, risk,
  dialogs and new tabs live.
- Cross-origin iframes attach as flattened child sessions (`Target.setAutoAttach`) of
  the persistent tab session, nested up to 3 levels. The tree of each frame is read in
  its own context and spliced under its iframe (found via `DOM.getFrameOwner` and the
  page's ref registry); refs share one numbering across all documents of the tab.
  Frame refs resolve to top-viewport points by adding the iframe's content-box
  position. A detached or reloaded frame makes its refs stale. Uploads accept only
  canonical files inside the project directory (symlinks out are refused), at most 10
  files of 200 MB each. `frame_smoke.py` checks frames, uploads, eval and logs live.
- `browser_snapshot` defaults to a bounded DOM read. Set `mode=interactive`
  explicitly for upstream action UIDs. `browser_status`
  reports RPC latency, bytes and counts; these exclude model processing and do
  not claim model tokens, physical memory or an end-to-end performance gain.
- Checkpoints are private evidence, not an automatic resume queue. Project
  approval/sandbox settings remain at the Codex boundary and are not overridden.
- Upstream MCP is pinned to 2025-11-25; client protocols 2025-06-18 and 2025-11-25
  are explicitly supported. Unknown requests fail closed. Transport
  uncertainty or cancellation stops the executor; reconnect is manual.
- No interception of normal Chrome, automatic login inheritance, remote debugging
  attachment to arbitrary browsers, or browsing of other tasks' tabs is exposed.

Run `python3 -m unittest discover -s BrowserRuntime -p 'test_*.py'` for offline
checks. Run `python3 BrowserRuntime/smoke.py` after installing for the real Chrome
fixture checks. App build and Swift checks use the repository's usual scripts.
See `BrowserRuntime/PLAN.md` in the repository for the delivery sequence.

The host records the dedicated Chrome PID, process birth, exact launch command and
browser endpoint ID. Attachment requires a matching process and an exclusively
loopback listener owned by that PID. It never uses autoConnect or launches with
`--enable-automation`, `--disable-sync` or a mock keychain.
Reference: https://github.com/ChromeDevTools/chrome-devtools-mcp/blob/main/docs/advanced-usage.md#connecting-to-a-running-chrome-instance

## Compact workflow / Компактный поиск

English: `browser_cards` accepts `date` and `excerpt` selectors. A complete page may
return `nextToken` for a visible same-origin Next target. Pass that token
instead of `uid` to `browser_next`; the adapter checks the link again and navigates
once. Use the snapshot/UID path for buttons or JavaScript click behavior. Full URLs
remain in private checkpoints and card data. `expectedCards` opts into a previously
audited static per-page count with stable, hydrated, unique cards; never use a
site-wide total or guess this from a lazy list. Mismatches use ordinary scrolling.
This does not change scheduled jobs or establish model-token savings.

Русский: `browser_cards` принимает селекторы `date` и `excerpt`. Полностью прочитанная
страница может вернуть `nextToken` для однозначной видимой ссылки «Далее» на том же
сайте. Передай его вместо `uid` в `browser_next`: адаптер повторно проверит ссылку и
выполнит один переход. Для кнопок и JavaScript-обработчиков используй снимок и UID.
Полные URL сохраняются в локальных контрольных точках и данных карточек.
`expectedCards` включает режим заранее проверенного статического списка с известным
числом карточек на странице; карточки должны быть уникальны, загружены и стабильны.
Не используй общее число вакансий сайта и не угадывай число по ленивому списку.
При несовпадении выполняется обычная прокрутка. Расписания не меняются; экономия
модельных токенов пока не измерена.

Development: `python3 -B BrowserRuntime/workflow_smoke.py` compares generic and
static traversal against an isolated two-page local fixture. See
`BrowserRuntime/WORKFLOW_PLAN.md` in the repository for staged rollout and measurement limits.

## Parallel chat browsers / Параллельные браузеры чатов

English: each Switchboard Codex chat receives a host-generated environment UUID
through its thread-specific MCP configuration. The saved native thread binding
survives reconnects and app restarts. Browser files are under
`environments/<UUID>/`; installation files remain shared. The old `testing-profile`
is left untouched and is not copied into new profiles. Sign in manually or use
the explicit Chrome cookie import in each new chat. Turning the browser setting off explicitly disables the saved MCP
configuration when a thread is resumed.

Each environment has its own Chrome process, debugging port, MCP executor, queue,
records, action IDs and uncertainty fence. A pending operation or unknown result
in one environment does not block another. There is no automatic action replay.
Individual clients within an environment retain separate tokens and project file
permissions. Subagents that inherit the parent's MCP configuration still share
that environment; automatic per-subagent profile allocation is not implemented.
The independent unit in this release is a Switchboard chat.

Settings → Browser controls the maximum number of open managed environment
browsers (default 2, range 1–8). Apply after current tasks finish. Admission is
serialized only during startup. At the limit, a new open is rejected before any
page action; it is not queued or replayed. Existing browsers are never evicted.
Quit an unused browser with Cmd+Q or use the chat's Browser → Close browser menu.
Closing only a tab/window may leave Chrome running. Previously opened legacy
browsers are not included in this environment limit.

The chat Browser menu checks status, shows the exact owned Chrome process or
explicitly closes it while the chat is idle. Process identity is verified before
control. An unfinished operation blocks programmatic close; review it and quit
that Chrome manually. A durable close intent prevents resending an uncertain
close command. Profiles remain after close. The next explicit `browser_open`
starts a new session; old tokens are not transferred. Native OS dialogs and
system mouse/keyboard input still share the macOS desktop.

Русский: каждому чату Codex в Switchboard приложение назначает собственную
браузерную среду. Привязка к сессии сохраняется после переподключения и перезапуска.
У каждого чата отдельные профиль, процесс Chrome, исполнитель, очередь и журнал
действий. Зависание или неопределённый результат в одной среде не блокируют другую.
Действия автоматически не повторяются. Старый профиль остаётся на месте и не
копируется; войди на сайты вручную или явно импортируй cookies из Chrome в меню браузера чата. Отключение браузера
явно отключает сохранённую конфигурацию при возобновлении чата.

В настройках браузера выбери лимит открытых браузеров: по умолчанию 2, допустимо
от 1 до 8. Примени настройку после завершения задач. При достижении лимита новый
запуск отклоняется до действия со страницей, без очереди и автоматического повтора.
Чужие браузеры не закрываются. Заверши неиспользуемый Chrome через Cmd+Q или меню
«Браузер → Закрыть браузер» в его чате. Закрытие только вкладки или окна может
оставить процесс работающим. Прежний общий браузер в этот лимит не входит.

Меню браузера в чате позволяет проверить состояние, показать нужный процесс и
явно закрыть его, когда чат не выполняет задачу. Принадлежность процесса проверяется.
При незавершённой операции проверь результат и закрой этот Chrome вручную. Команда
закрытия с неопределённым результатом не отправляется повторно. Профиль сохраняется;
следующий явный `browser_open` создаёт новый сеанс. Старые токены не переносятся.
Субагенты с унаследованной конфигурацией пока разделяют среду родителя; отдельные
профили для них автоматически не создаются. Системные диалоги, мышь и клавиатура
macOS остаются общими.

Activation: finish active tasks, quit Switchboard with Cmd+Q and reopen the rebuilt
app. No running adapter or browser is killed automatically.
Активация: заверши текущие задачи, выйди из Switchboard через Cmd+Q и открой новую
сборку. Работающие адаптеры и браузеры автоматически не завершаются.

Development: `parallel_smoke.py` verifies two real Chrome processes with separate
profiles, concurrent native form input, independent progress during a blocked
navigation, cookie isolation, disconnect fencing, reconnect persistence and
explicit close isolation. Use `BROWSER_RUNTIME_UNDER_TEST` to check bundled
resources. `multi_client_smoke.py` remains a within-environment ownership check.
Live Swift compatibility tests use temporary unauthenticated Codex homes and no
model turns to verify distinct per-thread MCP launches and resume routing.

## Bounded page reading / Ограниченное чтение страницы

English: `browser_snapshot` defaults to `mode=read`: one DOM evaluation with no
DOM-stability wait, iframe traversal or accessibility-tree construction. Use
`selector` to read a profile section. It visits at most 4,000 nodes and emits at
most 24,000 text characters and 100 control descriptions, with a cooperative
100 ms traversal budget. Visible open shadow roots are included; iframe contents,
closed shadow roots and form values are omitted. `complete=false` always states
that this is partial page evidence; `truncated`/`reason` explain additional limits.
This read does not create UIDs. For actions requiring native UIDs, explicitly call
`browser_snapshot` with `mode=interactive` and no selector. That mode retains the
full upstream accessibility snapshot, including frames, and may still be slow.
There is no automatic fallback or retry between the modes. The transport deadline,
session ownership, serialization and unknown-outcome fence remain in force.

Unknown outcomes and recovery (2026-10-20). A lost CDP reply for one `browser_eval`
or `browser_input` call (for example an awaited promise that outlives the eval
`timeout`; Chrome awaits REPL-mode promises regardless of the CDP timeout) marks
only that action `outcome_unknown` and reports `outcomeUnknown: true`. The tab stays
usable: the agent must observe it with `browser_read` or `browser_screenshot` before
acting again; the action ID is never replayed. A lost upstream MCP reply, an
unconfirmed close or an uncertain import still put the executor browser into the
failed state and leave the durable fence. The MCP front end no longer refuses every
later call: `browser_status` reports the state, and `browser_close` on the failed
session quits this chat's Chrome (one graceful close, confirmed by process exit) and
returns `browserQuit: quit, outcomeUnknown: true`, which retires the fence and makes
`browser_open` available again. While another task of the chat still has a tab, that
task closes its own tab first. Only a confirmed Chrome exit clears the failed state;
an unconfirmed quit keeps it. No app restart is needed. The failed state belongs to
the client, not to a tab: when `browser_open` itself failed, or the owned tab was
already invalidated, the client owns no session and `browser_close` accepts any
`session` value (an owned tab still requires its own token). Without a recorded
Chrome there is nothing to quit and the call returns `browserQuit: none`.

Русский: `browser_snapshot` по умолчанию использует `mode=read`: один DOM-запрос без
ожидания стабильности DOM, обхода iframe и построения дерева доступности. `selector`
позволяет прочитать отдельную часть профиля. Ограничения: 4 000 узлов, 24 000 символов
текста, 100 описаний элементов управления и проверяемый в цикле бюджет 100 мс.
Видимые открытые shadow roots читаются; содержимое iframe, закрытых shadow roots и
значения форм пропускаются. `complete=false` всегда обозначает неполный охват;
`truncated` и `reason` поясняют дополнительные ограничения. UID не создаются.
Для действий с нативными UID явно вызови `browser_snapshot` с `mode=interactive`,
без selector. Этот режим сохраняет полное дерево доступности, включая iframe,
и может работать медленно. Автоматического переключения режимов и повторов нет.
Срок ожидания транспорта, владение сессиями, последовательное выполнение и
блокировка неизвестного исхода сохраняются.

Development: `snapshot_smoke.py` uses an isolated Chrome and local profile with a
busy cross-site iframe, continuously changing DOM, large text and shadow DOM.
`--reproduce-legacy` compares the bounded read with the original 25-second AX
snapshot timeout. Set `BROWSER_RUNTIME_UNDER_TEST` to test bundled resources.

An old untyped unknown-outcome fence is never guessed to be a read. An explicitly
approved one-shot read-recovery receipt can identify its exact SHA-256 and mtime.
The executor consumes it only on startup after acquiring the existing lock,
archives the fence and approval, and dispatches no operation. Changed fences and
known mutating tool names cannot consume it. Action-ID records remain unchanged.

Старую запись неизвестного исхода без имени операции нельзя автоматически считать
чтением. Разовое явное разрешение на восстановление чтения привязывается к точным
SHA-256 и времени изменения записи. Исполнитель применяет его только при запуске
после получения прежней блокировки, сохраняет запись и разрешение в архив и не
отправляет никаких операций. Изменившаяся запись или известное изменяющее действие
не подходят под разрешение. Записи actionID остаются неизменными.


## Explicit Chrome cookie import

Browser → Import cookies only… opens a native profile picker. Quit regular
Google Chrome with Cmd+Q and close this chat's managed browser before importing.
Select a source profile and click Import; macOS may ask for Chrome Safe Storage
access in Keychain. Supported website cookies become available to this chat's
browser and agent. Matching destination cookies are replaced. No passwords,
Codex/Claude Code authentication files, bookmarks or other profile data are copied.

The importer reads an encrypted snapshot of the selected standard Chrome profile
and decrypts supported macOS v10 cookies in memory. Only reviewed database schemas
23/24 are accepted. Domain hashes in schema 24 are verified. Partitioned, expired
or unsupported cookies are skipped. A running source, pending WAL or symlinked
source profile blocks import. The source database is never opened by SQLite or
modified. Imported cookies retain domain/host scope, path, Secure, HttpOnly,
SameSite and session/expiry semantics. The profile choice, not the secret values,
is remembered in app preferences.

The native host holds the environment operation lock while preparing the owned
Chrome, issuing a single CDP Storage.setCookies and verifying Storage.getCookies.
A durable fence blocks agent operations after an uncertain write; no automatic
retry occurs. Review Chrome and quit it with Cmd+Q before a fresh attempt. The
helper receives no cookies. Decrypted values are never written to logs, temporary
files or agent messages. Chrome owns persistence in the destination profile.

The result counts verified cookies, not authenticated websites. Some sites need
localStorage, device-bound sessions or a new login. Session cookies retain their
session lifetime. A new separate profile needs its own explicit import; a saved
profile can instead be reused as described below. There is no shared login vault,
background sync or automatic seeding.

Русский: в чате открой «Браузер → Импортировать только cookies…». Заверши обычный
Chrome через Cmd+Q и закрой браузер чата. Выбери профиль и нажми «Импортировать»;
macOS может запросить доступ к Chrome Safe Storage в Связке ключей. Cookies сайтов
станут доступны браузеру и агенту этого чата; совпадающие cookies будут заменены.
Пароли, файлы авторизации Codex / Claude Code и остальные данные профиля не
переносятся. Исходный профиль не изменяется.

Просроченные, разделённые по сайтам (partitioned) и неподдерживаемые cookies
пропускаются. Результат показывает количество проверенных cookies, а не число
выполненных входов: некоторым сайтам нужен повторный вход или другие данные.
Cookies сеанса сохраняют свой срок жизни. Новому отдельному профилю нужен явный
импорт; сохранённый профиль можно использовать повторно, как описано ниже.
При неопределённом результате автоматического повтора нет; проверь браузер и
заверши его через Cmd+Q перед новой попыткой. Расшифрованные значения cookies не попадают в
журналы, сообщения агента или временные файлы.

Development: ChromeCookieTests uses synthetic encrypted SQLite fixtures and
known OpenSSL vectors. ChromeCookieLiveTests is opt-in with
`SWITCHBOARD_COOKIE_SMOKE=1 zsh scripts/test.sh`; it uses isolated Chrome for
Testing profiles and a loopback HTTP fixture only, never the user's Chrome data
or Keychain. It checks cookie transmission, HttpOnly, restart persistence and
chat isolation.


## Reusable profiles and native control

Browser → Profiles and control… saves a name for the current profile. Close its
Chrome with Browser → Close browser, then Release profile. Before sending the
first message in a new chat in the same project, select that saved profile from
the browser menu. A separate new profile remains the default. Existing idle chats
can also select a saved profile or a new separate profile from the profile sheet.
Selection is explicit and cannot take a profile away from another chat.

The first release requires confirmed Chrome exit before switching or releasing a
profile; it does not transfer live tabs. Persistent cookies, localStorage and
IndexedDB stay in the same directory. Session cookies, tab sessionStorage,
JavaScript memory and server expiry can still require another login. This feature
does not copy localStorage/IndexedDB from ordinary Chrome, clone profiles for
parallel work or migrate Chrome Sync/account avatars. The cookie import receipt
retains only date/counts and explicitly leaves website authentication unverified.

Take manual control pauses browser dispatch for that profile; Return control to
chat requires a newly acknowledged provider configuration. These actions require
an idle chat. Use Show browser to bring its window forward. Independent profiles
remain usable. A saved profile can only be selected within its canonical project
path and provider connection. Claude and scheduled jobs do not gain profile
selection through this release.

Implementation: `profiles.json` schema 1 stores the catalog and bindings hashed
from full provider/connection/native-session identity. Existing original-Codex
bindings migrate without relocating their profile. `profiles-required` prevents
a missing catalog from restoring legacy access. Catalog changes use an OS lock,
atomic replacement/fsync and the same per-environment operation lock as dispatch.
Every queued operation rechecks the captured lease generation and project under
that lock; model arguments cannot choose a profile or transfer ownership.
A pending/configuring/human/released profile denies agent dispatch. Lost native
configuration acknowledgement stays configuring until explicit recovery. There
is no automatic takeover, replay, background synchronization or profile deletion.

Native close records intent once, sends the fixed CDP `Browser.close` command to
the verified owned endpoint and separately confirms process exit. It does not
escalate to SIGTERM or resend an uncertain close. Graceful shutdown is required
for prompt persistence of browser state. The bounded loopback handshake/command
uses [CDP Browser.close](https://chromedevtools.github.io/devtools-protocol/tot/Browser/#method-close)
and [RFC 6455](https://datatracker.ietf.org/doc/html/rfc6455); it is not a general
WebSocket transport or an agent scripting tool.

Русский: открой «Браузер → Профили и управление…» и сохрани название профиля.
Закрой его через «Браузер → Закрыть браузер», затем нажми «Освободить профиль».
В новом чате того же проекта выбери сохранённый профиль до первого сообщения.
По умолчанию создаётся отдельный профиль. Занятый профиль нельзя забрать у другого
чата; переключение в существующем чате доступно, когда он не выполняет задачу.

Данные сайтов сохраняются в прежнем каталоге. Вкладки не передаются, поэтому вход,
зависящий от вкладки или срока действия серверной сессии, может потребовать
повторения. Расширенный импорт из обычного Chrome, параллельные копии и Chrome
Sync сюда не входят. «Взять управление вручную» останавливает действия агента в
этом профиле; «Вернуть управление чату» подключает его заново с подтверждением.
Окно открывается на передний план через «Показать браузер». Другие отдельные
профили продолжают работать. Возможность доступна для Codex, без изменения задач
по расписанию и поддержки Claude. При неподтверждённом закрытии или подключении
автоматического повтора нет.

Development: `SWITCHBOARD_PROFILE_SMOKE=1 zsh scripts/test.sh` exercises real
Chrome against a loopback site, verifies cookies/localStorage/IndexedDB after
closed-profile handoff, and checks that a different profile remains signed out.
Unit/process fixtures cover migration, provider/project scope, exclusive control,
stale and queued clients, human control and lost configuration acknowledgement.
No private website account or model inference is part of these checks.
