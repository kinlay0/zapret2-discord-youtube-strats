> [!WARNING]
> Если у вас проблемы с использованием DNS Cloudflare/Google, то советую подобрать другой DNS сервер. 
> Не знаете какой DNS выбрать? Посмотрите [dpi-detector](https://github.com/Runnin4ik/dpi-detector)

**Данный проект является продолжением/улучшением первого [zapret-discord-youtube-strats](https://github.com/kinlay0/zapret-discord-youtube-strats)**

Все стратегии собраны в одном месте, чтобы вы могли протестировать их буквально в несколько нажатий. Проект будет обновляться по мере обновлений [zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube) от Flowseal

### Что тут другого

- стратегии написаны под zapret2 (`winws2.exe` + lua), так что стратегии из первого zapret (`winws.exe`) тут не заведутся
- фейки лежат в папке `bin/` и подхватываются через `lua/blobs.lua`. если хотите заменить фейк, то положите файл в `bin/`, пропишите его в `lua/blobs.lua`, а в стратегии используйте имя оттуда (`tls_google`, `quic_google` и т.д.). если какого-то файла из списка нет, winws2 не запустится
- пункт `8. WS Proxy` в `service.bat` - прокси для сайтов, которые zapret не обходит (подробнее ниже)

### ws-proxy

Маленький прокси, который возвращает доступ к сайтам заблокированным по IP (instagram, facebook, messenger, threads) или к сервисам с гео-ограничениями (spotify, ИИ и т.д.). zapret такие ограничения обойти не может, поэтому трафик к ним идет через ваш Cloudflare Worker или Deno по WebSocket

- через прокси идут только домены из `lists\list-proxy.txt`, все остальное как обычно через zapret
- сервер поднимается бесплатно, код и пошаговая инструкция в [docs/WsProxy.md](https://github.com/kinlay0/zapret2-discord-youtube-strats/blob/main/docs/WsProxy.md)
- адрес и ключ пишем в `utils\ws-proxy-settings.txt`, включаем через `service.bat` -> `8. WS Proxy`, дальше прокси сам стартует вместе со стратегией
- можно заполнить и Cloudflare, и Deno - тогда второй будет запасным, если основной не отвечает
- сайты, которые сами стоят на Cloudflare, через Worker идут через публичный NAT64 шлюз и могут открываться через раз, для них лучше Deno (пока он работает, закрывается примерно в апреле 2027)

^ выдержка из самой инструкции