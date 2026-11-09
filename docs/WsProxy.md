# WsProxy

> [!CAUTION] 
>сайты, которые сами стоят на Cloudflare, через Worker идут через публичный NAT64 шлюз и могут открываться через раз (chatgpt.com может не открыться вообще). если нужны такие сайты - используйте [Deno Worker](#deno-worker), у него такого ограничения нет

данный прокси был основан на идее tg-ws-proxy, только расширенный под определенные домены. идея была реализована на нервотрепном Gemini.

Маленький прокси, который возвращает доступ к сайтам заблокированным по IP (instagram, facebook, messenger, threads) или к сервисам с гео-ограничениями (spotify, ИИ и т.д.). zapret такие ограничения обойти не может, поэтому трафик к ним идет через ваш Cloudflare Worker или Deno по WebSocket.

через прокси идут только домены из `lists\list-proxy.txt`, все остальное через zapret.

<a id="cloudflare-worker"></a>
<details>
<summary><img src="https://cdn.simpleicons.org/cloudflare" width="16" height="16" alt=""> <b>Cloudflare Worker</b></summary>

### 1. создание

1. заходим на [dash.cloudflare.com](https://dash.cloudflare.com/) - ищем слева `Compute`, тыкаем, находим `Workers & Pages`
    * аккаунта нет? регистрируемся, без этого Worker не создать
2. сверху справа `Create application` -> `Start with Hello World!` -> `Deploy`
3. сверху справа `Edit code`, удаляем весь код и вставляем код [снизу](#worker) -> `Deploy` -> тыкаем стрелку слева сверху (для того чтобы вернуться на страницу воркера)
4. на странице вашего Worker'а открываем `Settings` (сверху) -> находим `Runtime variables and secrets` -> `+ Add variable` (чуть правее названия)
    1. Environment оставляем на `Production`
    2. в `Key` пишем что хотим, но можно и `KEY` (капсом)
    3. в `Value` пишем свой ключ - любая длинная строка, и обязательно ставим галочку на `Secret` (не забудьте скопировать ключ, если вы решили сделать его длинным)
    4. `Add variable and deploy`
    5. копируем `Secret` и заходим обратно в `Edit code` и заменяем заглушку ключа на ваш собственный. (3-я строка)
5. копируем домен Worker'а вида `random-name.username.workers.dev`

### 2. настройка

1. открываем `utils\ws-proxy-settings.txt` и в секции `[cloudflare]` вписываем свои данные (`key` - то, что писали в `Value`):
```
[cloudflare]
url=wss://random-name.username.workers.dev/
key=ваш ключ
```
обязательно замените в url `https://` на `wss://`!!

2. домен Worker'а добавляем в `lists\list-exclude-user.txt`, чтобы стратегии zapret не ломали соединение до cloudflare
    - если Worker без zapret не открывается, тогда наоборот добавляем его в `lists\list-general-user.txt`
3. нужные домены пишем в `lists\list-proxy.txt`.

</details>

<a id="deno-worker"></a>
<details>
<summary><img src="https://cdn.simpleicons.org/deno/000000/ffffff" width="16" height="16" alt=""> <b>Deno Worker</b></summary>

### UPD: Deno присоединяется к Cloudflare и Deno Deploy закроется примерно в апреле 2027 года https://deno.com/blog/cloudflare

альтернатива Cloudflare, клиент тот же, протокол тот же. плюс - сайты на Cloudflare (dash.cloudflare.com и т.д.) открываются

1. заходим на [console.deno.com](https://console.deno.com/) и создаем новое приложение (`New Playground`)
2. удаляем шаблонный код, вставляем код [снизу](#deno) и деплоим
3. в `Settings` (слева) приложения находим `Environment Variables` - выбираем в `Variable Type` - `Secret` и добавляем `KEY` со своим ключом
4. копируем адрес приложения вида `app-name.username.deno.net`
5. в `utils\ws-proxy-settings.txt` в секции `[deno]` вписываем:
```
[deno]
url=wss://app-name.username.deno.net/
key=ваш ключ
```

6. домен Deno добавляем в `lists\list-exclude-user.txt` (или в `list-general-user.txt`, если без zapret не открывается, но у deno нет ограничений в РФ, так что добавляйте в `list-exclude-user.txt`)
7. нужные домены пишем в `lists\list-proxy.txt`

</details>

### включение

Домены можно найти тут - https://iplist.opencck.org/ru. Выбираете формат - Text, а тип данных - Домены и нажимаете кнопку отправить.

1. запускаем `service.bat` -> `8. WS Proxy`, чтобы стало `[enabled]`. сервер выбирать не надо, ws-proxy сам берет те секции из `utils\ws-proxy-settings.txt`, где заполнены `url` и `key`:
    - заполнена одна секция (cloudflare или deno) - работает только одна
    - заполнены обе - основной тот, что выше в файле, второй запасной. если основной не отвечает 5 секунд, прокси сам переключается на запасной, а основной пробует снова через минуту. чтобы поменять основной, просто переставьте секции местами
    - не заполнено ничего - прокси не включится
2. запускаем любую стратегию `general*.bat` вручную или через `1. Install Service`, прокси стартует сам в свернутом окне `zapret: ws-proxy`
или же откройте папку `utils` и запустите `ws-proxy-debug.bat`

при запуске ws-proxy один раз проверяет каждый сервер и пишет результат, например:
```
checking deno... ok (377 ms)
checking cloudflare... FAIL - Server answered 'HTTP/1.1 403 Forbidden'
```

выключить: `service.bat` -> `8. WS Proxy` еще раз (станет `[disabled]`), либо `2. Remove Services`

### проверка
вводим в PowerShell:

```powershell
curl.exe -I -x http://127.0.0.1:1080 https://www.instagram.com/
```
должно быть `200 Connection Established` и после него ответ instagram.

- если хотите узнать с какого IP идет Worker, то добавьте `ipinfo.io` в `list-proxy.txt`, ждем пару секунд и вводим в PowerShell
```powershell
curl.exe -x http://127.0.0.1:1080 https://ipinfo.io/json
```

если что-то не работает, то запускаем `utils\ws-proxy-debug.bat` (поставьте `verbose=1` в `ws-proxy-settings.txt`), там видно каждое соединение (`PRX` - через прокси) и ошибки.

| Ошибка                           | Что делать                                                                                         |
| -------------------------------- | -------------------------------------------------------------------------------------------------- |
| `403 Forbidden`                  | ключ в `ws-proxy-settings.txt` не совпадает с `Value` переменной `KEY` в Worker'е                          |
| `502` / `Connect failed`         | сайт стоит на Cloudflare или недоступен, уберите домен из `list-proxy.txt`                        |
| `TLS ...`                        | стратегия zapret ломает соединение до Worker'а, нужно добавить домен Worker'а в `list-exclude-user.txt` |
| `TCP connect failed` / `DNS ...` | Worker недоступен у вашего провайдера, нужно добавить домен Worker'а в `list-general-user.txt`          |
| в окне пусто, сайт не грузится   | браузер не использует PAC, перезапустите его                                                      |

### ограничения

- только TCP
- бесплатный план Workers - 100 000 запросов в сутки
- у Deno свои лимиты бесплатного тарифа (смотрите в панели)
- Meta иногда просит капчу

# worker

если в адрес Worker'а (`https://...workers.dev/`, не `wss://`) дописать `?k=ваш ключ&test=example.com` и открыть в браузере, то Worker проверит прямое подключение и все NAT64 шлюзы и покажет, что из них отвечает.

чтобы проверить другие шлюзы не меняя рабочий список, добавьте `&nat64=` и префиксы через запятую, например `&nat64=2a00:1098:2b::,2602:fc59:11:64::` (можно копировать прямо из списков шлюзов, вместе с `/96`). неправильные префиксы Worker покажет в конце ответа в `skipped`.

если в ключе есть `+`, `&`, `#` или `%`, в ссылке замените их на `%2B`, `%26`, `%23`, `%25`, иначе будет `Not found`.

```js
import { connect } from "cloudflare:sockets";

const KEY = "CHANGE-ME"; // замените CHANGE-ME на свой ключ или задайте такую переменную KEY в настройках
const NAT64 = "2a01:4f9:c010:3f02:64::,2602:fc59:b0:64::";
const TIMEOUT = 5000; // самое оптимальное число после множественных проверок, но можете опустить значение
const STAGGER = 150;
const PARALLEL = 5;
const ROUTE_TTL = 600000;

const routes = new Map();
const dns = new Map();
let lastGood = null;

const enc = new TextEncoder();

function save(map, key, value) {
  if (map.size > 2000) map.clear();
  map.set(key, value);
}

function fresh(map, key) {
  const v = map.get(key);
  return v && v.until > Date.now() ? v : null;
}

function quiet(f) {
  try {
    const p = f();
    if (p && p.catch) p.catch(() => {});
  } catch (e) {}
}

function splitList(s) {
  return String(s).split(",").map((x) => x.trim()).filter(Boolean);
}

async function resolve4(host) {
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(host)) return host;
  const hit = fresh(dns, host);
  if (hit) return hit.ip;
  const r = await fetch("https://cloudflare-dns.com/dns-query?type=A&name=" + encodeURIComponent(host), {
    headers: { accept: "application/dns-json" },
  });
  const a = ((await r.json()).Answer || []).find((x) => x.type === 1);
  if (!a) throw new Error("no A record");
  save(dns, host, { ip: a.data, until: Date.now() + Math.min(Math.max(a.TTL || 60, 60), 600) * 1000 });
  return a.data;
}

function toNat64(prefix, ip) {
  const [a, b, c, d] = ip.split(".").map(Number);
  if (prefix.split(":").length > 7) prefix = prefix.replace(/::$/, ":");
  return "[" + prefix + ((a << 8) | b).toString(16) + ":" + ((c << 8) | d).toString(16) + "]";
}

async function probe(target, host) {
  const t0 = Date.now();
  let s, timer;
  try {
    s = connect({ hostname: target, port: 80 });
    const r = s.readable.getReader();
    const w = s.writable.getWriter();
    const res = await Promise.race([
      w.write(enc.encode("HEAD / HTTP/1.1\r\nHost: " + host + "\r\nConnection: close\r\n\r\n")).then(() => r.read()),
      new Promise((_, rej) => { timer = setTimeout(() => rej(new Error("timeout")), TIMEOUT); }),
    ]);
    const line = res.done ? "closed without data" : new TextDecoder().decode(res.value).split("\r\n")[0];
    return { target, ms: Date.now() - t0, result: line };
  } catch (e) {
    return { target, ms: Date.now() - t0, error: String(e) };
  } finally {
    clearTimeout(timer);
    quiet(() => s.close());
  }
}

async function diagnose(host, prefixes) {
  const [direct, ip] = await Promise.all([probe(host, host), resolve4(host).catch((e) => ({ error: String(e) }))]);
  if (typeof ip !== "string") return [direct, { resolve: ip.error }];
  const out = [];
  out.push(direct, { ipv4: ip });
  for (let i = 0; i < prefixes.length; i += 5) {
    out.push(...(await Promise.all(prefixes.slice(i, i + 5).map((p) => probe(toNat64(p, ip), host)))));
  }
  const route = fresh(routes, host);
  out.push({ cache: { route: route ? route.prefix || "direct" : null, lastGood } });
  return out;
}

function relay(ws, host, port, prefixes) {
  const route = fresh(routes, host);
  const pending = [];
  const live = new Set();
  let winner = null, closed = false, firstAt = 0;
  let queue = [], limit = 1, staggerTimer = null, ipP = null;

  const getIp = () => ipP || (ipP = resolve4(host));
  const direct = async () => [{ target: host, prefix: null }];
  const nat64 = async () => {
    if (!prefixes.length) return [];
    const ip = await getIp();
    const order = new Set([route && route.prefix, lastGood, ...prefixes].filter((p) => prefixes.includes(p)));
    return [...order].map((p) => ({ target: toNat64(p, ip), prefix: p }));
  };
  const stages = route && route.prefix ? [nat64, direct] : [direct, nat64];
  if (!route && prefixes.length) getIp().catch(() => {});

  const tick = setInterval(() => {
    for (const a of live) {
      const since = a.opened ? firstAt && Math.max(a.start, firstAt) : a.start;
      if (since && Date.now() - since > TIMEOUT) fail(a, "timeout");
    }
  }, 100);

  const next = () => {
    clearTimeout(staggerTimer);
    if (closed || winner) return;
    if (queue.length && live.size < limit) {
      start(queue.shift());
      if (queue.length && live.size < limit) staggerTimer = setTimeout(next, STAGGER);
    } else if (!live.size && !queue.length) nextStage();
  };

  const nextStage = () => {
    const stage = stages.shift();
    if (!stage) {
      console.log("giveup", host);
      routes.delete(host);
      return finish();
    }
    stage().then(
      (q) => {
        queue = q;
        limit = port === 443 && q.length && q[0].prefix ? PARALLEL : 1;
        next();
      },
      (e) => {
        console.log("fail", host, String(e));
        if (!closed && !winner) nextStage();
      },
    );
  };

  const start = (t) => {
    const a = { target: t.target, prefix: t.prefix, start: Date.now(), opened: false, wq: Promise.resolve() };
    live.add(a);
    try {
      a.sock = connect({ hostname: a.target, port });
      a.reader = a.sock.readable.getReader();
      a.writer = a.sock.writable.getWriter();
      a.sock.opened.then(() => { a.opened = true; }, (e) => fail(a, String(e)));
    } catch (e) {
      return queueMicrotask(() => fail(a, String(e)));
    }
    for (const b of pending) write(a, b);
    read(a);
  };

  const write = (a, bytes) => {
    a.wq = a.wq.then(() => a.writer.write(bytes)).catch((e) => (a === winner ? finish() : fail(a, String(e))));
  };

  const read = async (a) => {
    let why = "closed without data";
    try {
      for (;;) {
        const { value, done } = await a.reader.read();
        if (done) break;
        if (!value || !value.byteLength) continue;
        if (!winner && !closed) win(a);
        if (winner !== a) return;
        ws.send(value);
      }
    } catch (e) {
      why = String(e);
    }
    a === winner ? finish() : fail(a, why);
  };

  const kill = (a) => {
    quiet(() => a.reader.cancel());
    quiet(() => a.writer.abort());
    quiet(() => a.sock.close());
  };

  const win = (a) => {
    winner = a;
    clearInterval(tick);
    clearTimeout(staggerTimer);
    live.delete(a);
    for (const o of live) kill(o);
    live.clear();
    pending.length = 0;
    save(routes, host, { prefix: a.prefix, until: Date.now() + ROUTE_TTL });
    if (a.prefix) lastGood = a.prefix;
    console.log("ok", host, a.target);
  };

  const fail = (a, why) => {
    if (!live.delete(a)) return;
    console.log("fail", a.target, why);
    kill(a);
    next();
  };

  const finish = () => {
    if (closed) return;
    closed = true;
    clearInterval(tick);
    clearTimeout(staggerTimer);
    for (const a of live) kill(a);
    live.clear();
    if (winner) kill(winner);
    pending.length = 0;
    quiet(() => ws.close(1000, "done"));
  };

  ws.binaryType = "arraybuffer";
  ws.addEventListener("message", (e) => {
    if (closed) return;
    const bytes = typeof e.data === "string" ? enc.encode(e.data) : new Uint8Array(e.data);
    if (winner) return write(winner, bytes);
    if (!firstAt) firstAt = Date.now();
    pending.push(bytes);
    for (const a of live) write(a, bytes);
  });
  ws.addEventListener("close", finish);
  ws.addEventListener("error", finish);

  nextStage();
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const arg = (name) => url.searchParams.get(name) || "";
    const key = env.KEY || KEY;
    const authed = !key.toUpperCase().startsWith("CHANGE-ME") && arg("k") === key;
    const prefixes = splitList(env.NAT64 ?? NAT64);

    if ((request.headers.get("Upgrade") || "").toLowerCase() !== "websocket") {
      if (!authed || !arg("test")) return new Response("Not found", { status: 404 });
      const custom = splitList(arg("nat64")).map((p) => p.replace(/^\[|\]$|\/96$/g, ""));
      const valid = custom.filter((p) => /^[0-9a-f:]{2,40}$/i.test(p));
      const report = await diagnose(arg("test").toLowerCase(), arg("nat64") ? valid.slice(0, 20) : prefixes);
      if (valid.length < custom.length) report.push({ skipped: custom.filter((p) => !valid.includes(p)) });
      return new Response(JSON.stringify(report, null, 2), { headers: { "content-type": "application/json" } });
    }

    if (!authed) return new Response("Forbidden", { status: 403 });
    const host = arg("h").toLowerCase();
    const port = parseInt(arg("p") || "443", 10);
    if (!/^[a-z0-9.\-:]{1,253}$/.test(host) || !(port > 0 && port < 65536) || port === 25) {
      return new Response("Bad Request", { status: 400 });
    }
    const [client, server] = Object.values(new WebSocketPair());
    server.accept();
    relay(server, host, port, prefixes);
    return new Response(null, { status: 101, webSocket: client });
  },
};
```

# deno

```js
const KEY = "CHANGE-ME"; // замените CHANGE-ME на свой ключ или задайте такую переменную KEY в настройках

function toBytes(data) {
  if (data instanceof ArrayBuffer) return new Uint8Array(data);
  if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
  if (typeof data === "string") return new TextEncoder().encode(data);
  if (data && typeof data.arrayBuffer === "function") return data.arrayBuffer().then((ab) => new Uint8Array(ab));
  return new Uint8Array();
}

Deno.serve(async (req) => {
  if ((req.headers.get("upgrade") || "").toLowerCase() !== "websocket") {
    return new Response("Not found", { status: 404 });
  }
  const url = new URL(req.url);
  const key = Deno.env.get("KEY") || KEY;
  if (!key || key.startsWith("CHANGE-ME") || url.searchParams.get("k") !== key) {
    return new Response("Forbidden", { status: 403 });
  }
  const host = (url.searchParams.get("h") || "").toLowerCase();
  const port = parseInt(url.searchParams.get("p") || "443", 10);
  if (!/^[a-z0-9.\-:]{1,253}$/.test(host) || !(port > 0 && port < 65536) || port === 25) {
    return new Response("Bad Request", { status: 400 });
  }

  let conn;
  try {
    conn = await Deno.connect({ hostname: host, port: port });
  } catch (e) {
    console.log("fail", host, String(e));
    return new Response("Bad Gateway", { status: 502 });
  }

  const { socket, response } = Deno.upgradeWebSocket(req);
  socket.binaryType = "arraybuffer";
  const writer = conn.writable.getWriter();
  let closed = false;
  let chain = Promise.resolve();

  const finish = () => {
    if (closed) return;
    closed = true;
    try { writer.releaseLock(); } catch (e) {}
    try { conn.close(); } catch (e) {}
    try { socket.close(1000, "done"); } catch (e) {}
  };

  socket.onopen = async () => {
    try {
      for await (const chunk of conn.readable) {
        if (closed) break;
        socket.send(chunk);
      }
    } catch (e) {}
    finish();
  };

  socket.onmessage = (event) => {
    chain = chain.then(async () => {
      if (closed) return;
      await writer.write(await toBytes(event.data));
    }).catch(finish);
  };

  socket.onclose = finish;
  socket.onerror = finish;

  return response;
});
```
