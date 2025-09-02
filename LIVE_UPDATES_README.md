# Live Updates System для PhoenixKit Admin

Реализована система live-актуализации данных для админ-панели PhoenixKit, которая обеспечивает автоматическое обновление данных во всех подключенных административных интерфейсах в режиме реального времени.

## Функциональность

### Поддерживаемые таблицы
- **Users** - пользователи системы
- **Roles** - роли пользователей  
- **Dashboard Stats** - статистика дашборда

### Типы событий

#### События пользователей
- `user_created` - новый пользователь зарегистрирован
- `user_updated` - профиль или статус пользователя обновлен
- `user_role_assigned` - пользователю назначена роль
- `user_role_removed` - у пользователя удалена роль
- `user_roles_synced` - роли пользователя синхронизированы

#### События ролей
- `role_created` - создана новая роль
- `role_updated` - роль обновлена
- `role_deleted` - роль удалена

#### События статистики
- `stats_updated` - обновлена статистика дашборда

## Архитектура

### Компоненты системы

1. **PhoenixKit.Admin.Events** - центральный модуль для работы с событиями
   - Функции broadcasting событий
   - Функции подписки на события
   - Управление топиками PubSub

2. **LiveView компоненты** - обновленные для поддержки live-обновлений:
   - `DashboardLive` - подписывается на статистику
   - `UsersLive` - подписывается на события пользователей и статистику
   - `RolesLive` - подписывается на события ролей и статистику

3. **Контексты** - обновленные для broadcasting событий:
   - `PhoenixKit.Users.Auth` - broadcasting событий пользователей
   - `PhoenixKit.Users.Roles` - broadcasting событий ролей

### Топики PubSub
- `phoenix_kit:admin:users` - события пользователей
- `phoenix_kit:admin:roles` - события ролей
- `phoenix_kit:admin:stats` - события статистики

## Настройка

### Конфигурация PubSub

Добавьте в конфигурацию вашего приложения:

```elixir
# config/config.exs
config :phoenix_kit,
  pubsub_name: :my_app_pubsub  # или используйте PubSub вашего приложения
```

### Автоматическая настройка

PhoenixKit автоматически управляет своим собственным PubSub системой:

- ✅ **Автоматический запуск** - PubSub Manager стартует при первом обращении
- ✅ **Изоляция** - не зависит от PubSub родительского приложения
- ✅ **Zero configuration** - никаких дополнительных настроек не требуется

## Использование

### Подписка на события

```elixir
# В LiveView компоненте
def mount(_params, _session, socket) do
  if connected?(socket) do
    PhoenixKit.Admin.Events.subscribe_to_users()
    PhoenixKit.Admin.Events.subscribe_to_roles()
    PhoenixKit.Admin.Events.subscribe_to_stats()
  end
  
  {:ok, socket}
end
```

### Обработка событий

```elixir
# В LiveView компоненте
def handle_info({:user_created, user}, socket) do
  # Обновить список пользователей
  socket = load_users(socket)
  {:noreply, socket}
end

def handle_info({:stats_updated, stats}, socket) do
  socket = assign(socket, :stats, stats)
  {:noreply, socket}
end
```

### Manual broadcasting (если нужно)

```elixir
# Вручную отправить событие
PhoenixKit.Admin.Events.broadcast_user_created(user)
PhoenixKit.Admin.Events.broadcast_role_updated(role)
PhoenixKit.Admin.Events.broadcast_stats_updated()
```

## Тестирование

Система протестирована с помощью `test_live_updates.exs`. Для запуска теста:

```bash
mix run test_live_updates.exs
```

Тест проверяет:
- Корректность подписки на события
- Передачу всех типов событий через PubSub
- Правильность форматирования событий

## Результат

После реализации системы:

1. ✅ Все администраторы получают обновления в реальном времени
2. ✅ Данные синхронизируются между всеми открытыми админ-панелями
3. ✅ Отсутствует необходимость в ручном обновлении страницы
4. ✅ Высокая производительность благодаря использования Phoenix PubSub
5. ✅ Легкое расширение для новых типов событий

## Расширение системы

Для добавления новых событий:

1. Добавьте новую функцию broadcast в `PhoenixKit.Admin.Events`
2. Добавьте соответствующий топик, если нужен
3. Вызывайте broadcast из соответствующих контекстов
4. Добавьте обработчики `handle_info` в LiveView компоненты

## Performance Considerations

- События отправляются асинхронно и не влияют на производительность основных операций
- PubSub Phoenix оптимизирован для high-throughput сценариев
- Статистика обновляется только при изменениях, а не по таймеру
- LiveView автоматически управляет подключениями и отключениями

## Безопасность

- События содержат только необходимую информацию
- Подписка ограничена только административными интерфейсами
- Все изменения данных проходят через существующие контексты с проверками безопасности