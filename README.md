# Meridian — зеркало дистрибутива для роутеров

Здесь лежат готовые файлы Meridian VPN для установки на
роутеры — без исходного кода

## Ветки

- **`entware`** — для роутеров Keenetic и любых других на Entware (opkg).
- **`openwrt`** — для нативного OpenWrt (apk/opkg) и содержимое пакетных
  фидов (`feeds/apk`, `feeds/opkg`).

## Установка

Обычная команда установки, которую даёт бот/сайт, сама переключается на это
зеркало, если основной путь недоступен — отдельно ничего скачивать не нужно.

Ручной запуск с этого зеркала (если нужно явно):

```sh
wget -O /tmp/install.sh https://raw.githubusercontent.com/JinComputers/meridian-dist/entware/install.sh
sh /tmp/install.sh
```

(для OpenWrt — замените `entware` на `openwrt` в ссылке).

## Целостность

Сумма каждого файла проверяется установщиком автоматически по `SHA256SUMS`.
Подмена файла в этом репозитории не пройдёт незамеченной.

История изменений — в [CHANGELOG.md](CHANGELOG.md).

Поддержка: support@meridianvpn.org
