# CfWorker

> [!CAUTION] 
>сайты, которые сами стоят на Cloudflare, через Worker не откроются, это уже их приколы

данный туннель был основан на идее tg-ws-proxy, только расширенный под определенные домены. идея была реализована на нервотрепном Gemini.

туннель через Cloudflare Worker для сайтов, которые провайдер блокирует по IP (instagram, facebook, messenger, protonvpn и т.д.), где zapret их не обходит, т.к. до сервера не доходят даже пакеты.

в кратце, это маленький прокси только для выбранных сайтов, где трафик к ним идет через ваш Worker.

через Worker идут только домены из `lists\list-cfworker.txt`, все остальное через zapret.

### 1. создание

1. заходим на [dash.cloudflare.com](https://dash.cloudflare.com/) - ищем слева `Compute`, тыкаем, находим `Workers & Pages`
    * аккаунта нет? регистрируемся, без этого Worker не создать
2. сверху справа **`Create application`** -> `Start with Hello World!` -> `Deploy`
3. сверху справа **`Edit code`**, удаляем весь код и вставляем код [снизу](#worker) -> **`Deploy`**
4. на странице вашего Worker'а открываем `Settings` (сверху) -> `Variables and Secrets` -> `Add variable`
    1. Environment оставляем на `Production`
    2. в `Key` пишем ровно `KEY` (капсом, именно это слово)
    3. в `Value` пишем свой ключ - любая длинная строка, и обязательно ставим галочку на `Secret`
    4. `Add variable and deploy`
    5. копируем `Secret` и заходим обратно в `Edit code` и заменяем заглушку ключа на ваш собственный.
5. копируем домен Worker'а вида `random-name.username.workers.dev`

### 2. настройка

1. открываем `utils\cf-tunnel-settings.txt` и вписываем свои данные (`key` - то, что писали в `Value`):
```
url=wss://random-name.username.workers.dev/
key=ваш ключ
```
обязательно учитываем `wss://`!

2. домен Worker'а добавляем в `lists\list-exclude-user.txt`, чтобы стратегии zapret не ломали соединение до cloudflare
    - если Worker без zapret не открывается, тогда наоборот добавляем его в `lists\list-general-user.txt`
3. нужные домены пишем в `lists\list-cfworker.txt`.

### 3. включение

1. запускаем `service.bat` -> **`13. CF Tunnel`** -> ставим `[enabled]`
2. запускаем любую стратегию `general*.bat` вручную или через **`1. Install Service`**, туннель стартует сам в свернутом окне `zapret: cf-tunnel`

выключить: `service.bat` -> `13. CF Tunnel` (ставим `[disabled]`), либо `2. Remove Services`

### 4. проверка
вводим в PowerShell:

```powershell
curl.exe -I -x http://127.0.0.1:1080 https://www.instagram.com/
```
должно быть `200 Connection Established` и после него ответ instagram.

- если хотите узнать с какого айпи идет Worker, то добавьте `ipinfo.io` в `list-cfworker.txt`, ждем пару секунд и вводим в PowerShell
```powershell
curl.exe -x http://127.0.0.1:1080 https://ipinfo.io/json
```

если что-то не работает, то запускаем `utils\cf-tunnel-debug.bat` (поставьте `verbose=1` в `cf-tunnel-settings.txt`), там видно каждое соединение (`CF` - через Worker, `DIR` - напрямую) и ошибки.

| Ошибка                           | Что делать                                                                                         |
| -------------------------------- | -------------------------------------------------------------------------------------------------- |
| `403 Forbidden`                  | ключ в `cf-tunnel-settings.txt` не совпадает с `Value` переменной `KEY` в Worker'е                          |
| `502` / `Connect failed`         | сайт стоит на Cloudflare или недоступен, уберите домен из `list-cfworker.txt`                        |
| `TLS ...`                        | стратегия zapret ломает соединение до Worker'а  добавить домен Worker'а в `list-exclude-user.txt` |
| `TCP connect failed` / `DNS ...` | Worker недоступен у вашего провайдера, нужно добавить домен Worker'а в `list-general-user.txt`          |
| в окне пусто, сайт не грузится   | браузер не использует PAC, перезапустите его                                                      |

### ограничения

- только TCP
- бесплатный план Workers - 100 000 запросов в сутки
- Meta иногда просит капчу

# worker

```javascript
import { connect } from "cloudflare:sockets";

const KEY = "ваш ключ сюда!";

function toBytes(data) {
  if (data instanceof ArrayBuffer) return new Uint8Array(data);
  if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
  if (typeof data === "string") return new TextEncoder().encode(data);
  if (data && typeof data.arrayBuffer === "function") return data.arrayBuffer().then((ab) => new Uint8Array(ab));
  return new Uint8Array();
}

export default {
  async fetch(request, env) {
    if ((request.headers.get("Upgrade") || "").toLowerCase() !== "websocket") {
      return new Response("Not found", { status: 404 });
    }
    const url = new URL(request.url);
    const key = (env && env.KEY) || KEY;
    if (!key || key.startsWith("CHANGE-ME") || url.searchParams.get("k") !== key) {
      return new Response("Forbidden", { status: 403 });
    }
    const host = (url.searchParams.get("h") || "").toLowerCase();
    const port = parseInt(url.searchParams.get("p") || "443", 10);
    if (!/^[a-z0-9.\-:]{1,253}$/.test(host) || !(port > 0 && port < 65536) || port === 25) {
      return new Response("Bad Request", { status: 400 });
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    server.accept();

    const socket = connect({ hostname: host, port: port });
    const tcpReader = socket.readable.getReader();
    const tcpWriter = socket.writable.getWriter();

    let chain = Promise.resolve();
    server.addEventListener("message", (event) => {
      chain = chain.then(async () => {
        try {
          await tcpWriter.write(await toBytes(event.data));
        } catch (e) {
          try { server.close(1011, "tcp write failed"); } catch (e2) {}
        }
      });
    });

    server.addEventListener("close", async () => {
      try { await tcpWriter.close(); } catch (e) {}
      try { socket.close(); } catch (e) {}
    });

    (async () => {
      try {
        while (true) {
          const { value, done } = await tcpReader.read();
          if (done) break;
          if (value) server.send(value);
        }
      } catch (e) {
      } finally {
        try { server.close(1000, "done"); } catch (e) {}
        try { tcpReader.releaseLock(); } catch (e) {}
        try { socket.close(); } catch (e) {}
      }
    })();

    return new Response(null, { status: 101, webSocket: client });
  },
};
```
